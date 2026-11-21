// andeville.app accounts API, same origin as the site (see api/README.md). Everything outside /api/ is a page: pages.js.
//   GET  /api/config  /api/me  /api/download
//   POST /api/auth/google  /api/auth/dev  /api/auth/signout  /api/claim  /api/account/delete  /api/app/link  /api/app/token
// KV (ACCOUNTS): "user:<sub>" -> { sub, email, name, picture, created, keys }, "sess:<id>" -> { sub, created, app? },
// "link:<code>" -> { sub, created, challenge } (5 minutes, one use: the app's sign-in on its way back from the browser)
// KV (LICENCES): "txn:<txn>" -> key and "key:<key>" -> { txn, customer, status } are pay/worker.js's and only read here
// (rewriting a record could undo a refund's revoke landing in between); this Worker's own is "owner:<key>" -> sub.

import { page } from "./pages.js";

const JWKS_URL = "https://www.googleapis.com/oauth2/v3/certs";
const COOKIE = "andv_s";
const TTL = 2592000; // 30 days
const APP_TTL = 31536000; // a year: the app's session, renewed by signing in again
let jwks = { keys: [], exp: 0 }; // module-level: survives across requests in one isolate

const json = (o, status = 200, headers = {}) => Response.json(o, { status, headers: { "cache-control": "no-store", ...headers } });
const cookie = (v, age) => `${COOKIE}=${v}; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=${age}`;
const unavailable = () => json({ error: "unavailable" }, 503);
const read = async (kv, k) => { const v = await kv.get(k); return v ? JSON.parse(v) : null; };
const hex = n => [...crypto.getRandomValues(new Uint8Array(n))].map(b => b.toString(16).padStart(2, "0")).join("");
const b64 = s => Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), c => c.charCodeAt(0));

async function fetchJwks() {
  if (Date.now() < jwks.exp) return jwks.keys;
  const res = await fetch(JWKS_URL);
  const keys = res.ok && (await res.json()).keys;
  if (!Array.isArray(keys)) throw new Error("jwks"); // not cached: the next sign-in asks again
  const age = Number(/max-age=(\d+)/.exec(res.headers.get("cache-control") || "")?.[1] ?? 3600);
  jwks = { keys, exp: Date.now() + age * 1000 };
  return keys;
}

// Google ID token (RS256 JWT) -> claims, or null. getKeys is injectable so tests skip the network.
export async function verifyGoogleToken(token, clientId, getKeys = fetchJwks, now = Date.now() / 1000) {
  try {
    const [h, p, s] = String(token).split(".");
    const dec = x => JSON.parse(new TextDecoder().decode(b64(x)));
    const head = dec(h), c = dec(p);
    if (head.alg !== "RS256" || !clientId || c.aud !== clientId) return null;
    // ponytail: a kid missing from the cached set is a plain failure; refetch-on-miss if Google rotates mid-cache
    const jwk = (await getKeys()).find(k => k.kid === head.kid);
    if (!jwk) return null;
    const key = await crypto.subtle.importKey("jwk", jwk, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["verify"]);
    if (!(await crypto.subtle.verify("RSASSA-PKCS1-v1_5", key, b64(s), new TextEncoder().encode(`${h}.${p}`)))) return null;
    const ok = ["accounts.google.com", "https://accounts.google.com"].includes(c.iss) && c.exp > now - 60 && c.email_verified === true && c.sub;
    return ok ? c : null;
  } catch { return null; }
}

// constant-time: compare digests so length and content leak nothing
async function same(a, b) {
  const d = async x => new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(x)));
  const [x, y] = [await d(a), await d(b)];
  return x.reduce((acc, v, i) => acc | (v ^ y[i]), 0) === 0;
}

async function signIn(env, sub, { email, name, picture }) {
  const old = await read(env.ACCOUNTS, `user:${sub}`);
  const user = { sub, email, name, picture, created: old?.created ?? new Date().toISOString(), keys: old?.keys ?? [] };
  await env.ACCOUNTS.put(`user:${sub}`, JSON.stringify(user));
  const id = hex(32);
  await env.ACCOUNTS.put(`sess:${id}`, JSON.stringify({ sub, created: user.created }), { expirationTtl: TTL });
  return json({ ok: true }, 200, { "set-cookie": cookie(id, TTL) });
}

async function session(req, env) {
  // The app sends its session as a bearer token; the browser's is the cookie.
  const id = /^Bearer ([0-9a-f]{64})$/.exec(req.headers.get("authorization") || "")?.[1]
    ?? /(?:^|;\s*)andv_s=([0-9a-f]{64})/.exec(req.headers.get("cookie") || "")?.[1];
  const s = id && (await read(env.ACCOUNTS, `sess:${id}`));
  const user = s && (await read(env.ACCOUNTS, `user:${s.sub}`));
  // An account deleted and made again has a new `created`: sessions from before the delete stay dead.
  return user && user.created === s.created ? { id, user, app: !!s.app } : null;
}

// the user's licences as { key, status, txn }; records that vanished are skipped
async function licences(env, user) {
  const out = [];
  for (const key of user.keys) {
    const rec = await read(env.LICENCES, `key:${key}`);
    if (rec) out.push({ key, status: rec.status, txn: rec.txn });
  }
  return out;
}

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    if (!url.pathname.startsWith("/api/")) return page(req, env, url);
    const route = `${req.method} ${url.pathname}`;
    const need = {
      "GET /api/me": [env.ACCOUNTS, env.LICENCES], "GET /api/download": [env.ACCOUNTS, env.LICENCES, env.DOWNLOADS, env.DMG_KEY],
      "POST /api/auth/google": [env.ACCOUNTS], "POST /api/auth/dev": [env.ACCOUNTS], "POST /api/auth/signout": [env.ACCOUNTS],
      "POST /api/claim": [env.ACCOUNTS, env.LICENCES], "POST /api/account/delete": [env.ACCOUNTS, env.LICENCES],
      "POST /api/app/link": [env.ACCOUNTS, env.LICENCES], "POST /api/app/token": [env.ACCOUNTS],
    }[route];

    if (route === "GET /api/config")
      return json({ googleClientId: env.GOOGLE_CLIENT_ID || "", payUrl: env.PAY_URL || "", devLogin: !!env.DEV_LOGIN_TOKEN });
    if (!need) return json({ error: "not found" }, 404);

    let body;
    if (req.method === "POST") { // CSRF: JSON content-type forces a preflight, Origin pins the caller to this site
      // The app has no Origin: its calls carry a bearer token or a one-time code, never the cookie a forged page would ride on.
      const fromApp = route === "POST /api/app/token" || (req.headers.has("authorization") && !req.headers.has("cookie"));
      if (!(req.headers.get("content-type") || "").startsWith("application/json") || !(fromApp || req.headers.get("origin") === url.origin))
        return json({ error: "forbidden" }, 403);
      body = await req.json().catch(() => null);
      if (!body || typeof body !== "object") body = {};
    }
    const dev = route === "POST /api/auth/dev";
    if (dev && !(env.DEV_LOGIN_TOKEN && (await same(String(body.token ?? ""), env.DEV_LOGIN_TOKEN)))) return json({ error: "not found" }, 404);
    if (need.some(b => !b)) return unavailable();

    if (route === "POST /api/auth/google") {
      const c = await verifyGoogleToken(body.credential, env.GOOGLE_CLIENT_ID);
      return c ? signIn(env, c.sub, c) : json({ error: "invalid credential" }, 401);
    }
    if (dev) {
      const email = String(body.email ?? "").trim().toLowerCase();
      if (email.length > 254 || email.split("@").length !== 2) return json({ error: "bad email" }, 400);
      return signIn(env, `dev:${email}`, { email, name: String(body.name || email.split("@")[0]).slice(0, 100), picture: "" });
    }

    if (route === "POST /api/app/token") { // the app trades the code for its session; the verifier proves it began the sign-in
      const code = /^[0-9a-f]{64}$/.test(body.code) ? body.code : "";
      const link = code && (await read(env.ACCOUNTS, `link:${code}`));
      if (!link) return json({ error: "bad code" }, 401);
      await env.ACCOUNTS.delete(`link:${code}`);
      const digest = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(String(body.verifier ?? ""))));
      const challenge = btoa(String.fromCharCode(...digest)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
      if (!(await same(challenge, link.challenge))) return json({ error: "bad code" }, 401);
      const token = hex(32);
      await env.ACCOUNTS.put(`sess:${token}`, JSON.stringify({ sub: link.sub, created: link.created, app: true }), { expirationTtl: APP_TTL });
      return json({ token });
    }

    const s = await session(req, env);
    if (!s) return route === "POST /api/auth/signout" ? json({ ok: true }, 200, { "set-cookie": cookie("", 0) }) : json({ error: "signed out" }, 401);
    const { user } = s;

    if (route === "POST /api/auth/signout") {
      await env.ACCOUNTS.delete(`sess:${s.id}`);
      return json({ ok: true }, 200, { "set-cookie": cookie("", 0) });
    }

    if (route === "GET /api/me") {
      const ls = await licences(env, user);
      const { email, name, picture } = user;
      return json({
        user: { email, name, picture },
        licences: ls.map(({ key, status, txn }) => ({ key, status, txn })),
        download: { available: ls.some(l => l.status === "active") && !!env.DOWNLOADS && !!env.DMG_KEY, name: env.DMG_KEY || "",
          version: /-(\d+(?:\.\d+)*)\.dmg$/.exec(env.DMG_KEY || "")?.[1] ?? "" }, // "Andeville-0.4.dmg" -> "0.4": the app's update check
      });
    }

    if (route === "GET /api/download") {
      if (!(await licences(env, user)).some(l => l.status === "active")) return json({ error: "no licence" }, 403);
      const obj = await env.DOWNLOADS.get(env.DMG_KEY);
      if (!obj) return unavailable();
      return new Response(obj.body, { headers: {
        "content-type": "application/x-apple-diskimage", "content-disposition": `attachment; filename="${env.DMG_KEY}"`,
        "content-length": String(obj.size), "cache-control": "private, no-store",
      } });
    }

    // The app's session reads the account and downloads; changing the account stays with the browser.
    if (s.app) return json({ error: "forbidden" }, 403);

    if (route === "POST /api/app/link") { // the signed-in page vouches for the app that sent the user here
      if (!/^[A-Za-z0-9_-]{43}$/.test(body.challenge ?? "")) return json({ error: "bad challenge" }, 400);
      // Signing in inside the app is for accounts that paid; the site itself stays open, since buying needs an account.
      if (!(await licences(env, user)).some(l => l.status === "active")) return json({ error: "no licence" }, 403);
      const code = hex(32);
      await env.ACCOUNTS.put(`link:${code}`, JSON.stringify({ sub: user.sub, created: user.created, challenge: body.challenge }), { expirationTtl: 300 });
      return json({ code });
    }

    if (route === "POST /api/claim") {
      const txn = String(body.txn ?? "");
      if (!/^txn_[a-z0-9]{26}$/.test(txn)) return json({ error: "bad txn" }, 400);
      const key = await env.LICENCES.get(`txn:${txn}`);
      const rec = key && (await read(env.LICENCES, `key:${key}`));
      if (!rec) return json({ pending: true }, 404); // webhook may land a moment after checkout
      const owner = await env.LICENCES.get(`owner:${key}`);
      if (owner && owner !== user.sub) return json({ error: "claimed" }, 409);
      // ponytail: KV has no compare-and-set, so two accounts claiming in the same instant could both win;
      // upgrade to a Durable Object per key if that ever happens.
      await env.LICENCES.put(`owner:${key}`, user.sub);
      if (!user.keys.includes(key)) await env.ACCOUNTS.put(`user:${user.sub}`, JSON.stringify({ ...user, keys: [...user.keys, key] }));
      return json({ key });
    }

    // POST /api/account/delete
    for (const key of user.keys) if ((await env.LICENCES.get(`owner:${key}`)) === user.sub) await env.LICENCES.delete(`owner:${key}`);
    // ponytail: sessions on the user's other devices linger in KV until their 30-day TTL, but read as signed out (see session)
    await env.ACCOUNTS.delete(`user:${user.sub}`);
    await env.ACCOUNTS.delete(`sess:${s.id}`);
    return json({ ok: true }, 200, { "set-cookie": cookie("", 0) });
  },
};
