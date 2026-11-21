// node worker.test.mjs — config, CSRF, dev login, Google token checks, claim, download gate, delete, sign-out.
import assert from "node:assert";
import w, { verifyGoogleToken } from "./worker.js";

const kv = () => { const m = new Map(); return { m, get: async k => m.get(k) ?? null, put: async (k, v) => void m.set(k, v), delete: async k => void m.delete(k) }; };
const env = {
  ACCOUNTS: kv(), LICENCES: kv(), GOOGLE_CLIENT_ID: "cid.apps.googleusercontent.com", PAY_URL: "https://pay.example", DMG_KEY: "Andeville.dmg", DEV_LOGIN_TOKEN: "devtok",
  DOWNLOADS: { get: async k => k === "Andeville.dmg" ? { body: new Response("dmgbytes").body, size: 8 } : null },
};
const O = "https://x";
const call = (path, { method = "GET", body, cookie, headers = {}, e = env } = {}) => w.fetch(new Request(O + path, {
  method, body: body && JSON.stringify(body), headers: { ...(body && { "content-type": "application/json", origin: O }), ...(cookie && { cookie }), ...headers },
}), e);
const login = async (email, token = "devtok") => {
  const r = await call("/api/auth/dev", { method: "POST", body: { token, email } });
  return { r, cookie: r.headers.get("set-cookie")?.split(";")[0] };
};

// config works with nothing bound; unknown routes 404; bound routes 503 when their binding is gone
let r = await call("/api/config", { e: {} });
assert.deepEqual(await r.json(), { googleClientId: "", payUrl: "", devLogin: false });
assert.equal((await call("/api/nope")).status, 404);
assert.equal((await call("/api/me", { e: {} })).status, 503);

// signed out, CSRF
assert.equal((await call("/api/me")).status, 401);
r = await call("/api/auth/dev", { method: "POST", body: { token: "devtok", email: "a@b.c" }, headers: { origin: "https://evil" } });
assert.equal(r.status, 403);
r = await w.fetch(new Request(O + "/api/auth/dev", { method: "POST", body: "{}", headers: { "content-type": "application/json" } }), env); // no Origin
assert.equal(r.status, 403);

// dev login
assert.equal((await login("a@b.c", "wrong")).r.status, 404);
assert.equal((await login("a@b.c", "")).r.status, 404);
assert.equal((await call("/api/auth/dev", { method: "POST", body: { token: "x", email: "a@b.c" }, e: { ...env, DEV_LOGIN_TOKEN: "" } })).status, 404);
assert.equal((await login("not-an-email")).r.status, 400);
const A = await login("A@B.c");
assert.equal(A.r.status, 200);
assert.match(A.r.headers.get("set-cookie"), /^andv_s=[0-9a-f]{64}; HttpOnly; Secure; SameSite=Lax; Path=\/; Max-Age=2592000$/);
let me = await (await call("/api/me", { cookie: A.cookie })).json();
assert.equal(me.user.email, "a@b.c");
assert.deepEqual(me.licences, []);
assert.equal(me.download.available, false);

// Google token: locally generated RSA key stands in for Google's
const pair = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
const jwk = { ...(await crypto.subtle.exportKey("jwk", pair.publicKey)), kid: "k1" };
const keys = async () => [jwk];
const u = o => Buffer.from(typeof o === "string" ? o : JSON.stringify(o)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const mint = async (over = {}, signer = pair.privateKey) => {
  const h = u({ alg: "RS256", kid: "k1" }), p = u({ iss: "https://accounts.google.com", aud: env.GOOGLE_CLIENT_ID, sub: "g1", email: "g@x.y", email_verified: true, exp: now + 3600, ...over });
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", signer, new TextEncoder().encode(`${h}.${p}`));
  return `${h}.${p}.${Buffer.from(sig).toString("base64url")}`;
};
const cid = env.GOOGLE_CLIENT_ID;
assert.equal((await verifyGoogleToken(await mint(), cid, keys)).sub, "g1");
assert.equal((await verifyGoogleToken(await mint({ iss: "accounts.google.com" }), cid, keys)).sub, "g1");
assert.equal(await verifyGoogleToken(await mint({ aud: "other" }), cid, keys), null);
assert.equal(await verifyGoogleToken(await mint(), "", keys), null); // empty client id rejects everything
assert.equal(await verifyGoogleToken(await mint({ aud: "" }), "", keys), null);
assert.equal(await verifyGoogleToken(await mint({ exp: now - 120 }), cid, keys), null);
assert.equal((await verifyGoogleToken(await mint({ exp: now - 30 }), cid, keys)).sub, "g1"); // inside the 60 s skew
assert.equal(await verifyGoogleToken(await mint({ email_verified: false }), cid, keys), null);
assert.equal(await verifyGoogleToken(await mint({ iss: "https://evil.example" }), cid, keys), null);
const other = await crypto.subtle.generateKey({ name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" }, true, ["sign", "verify"]);
assert.equal(await verifyGoogleToken(await mint({}, other.privateKey), cid, keys), null); // bad signature
assert.equal(await verifyGoogleToken("garbage", cid, keys), null);
r = await call("/api/auth/google", { method: "POST", body: { credential: "garbage" } });
assert.equal(r.status, 401);

// claim: pending, success, other account 409, same account again 200
const txn = "txn_01m7sb1fpge1paqp4a3cx5026q", key = "ANDV-AAAA-BBBB-CCCC";
const claim = (c, t = txn) => call("/api/claim", { method: "POST", body: { txn: t }, cookie: c });
assert.equal((await call("/api/claim", { method: "POST", body: { txn } })).status, 401);
assert.equal((await claim(A.cookie, "bad")).status, 400);
r = await claim(A.cookie);
assert.equal(r.status, 404);
assert.deepEqual(await r.json(), { pending: true });
env.LICENCES.m.set(`txn:${txn}`, key);
env.LICENCES.m.set(`key:${key}`, JSON.stringify({ txn, customer: "ctm_1", status: "active" }));
assert.deepEqual(await (await claim(A.cookie)).json(), { key });
assert.equal(JSON.parse(env.LICENCES.m.get(`key:${key}`)).customer, "ctm_1"); // other fields kept
const B = await login("b@b.c");
assert.equal((await claim(B.cookie)).status, 409);
assert.equal((await claim(A.cookie)).status, 200);
assert.deepEqual(JSON.parse(env.ACCOUNTS.m.get("user:dev:a@b.c")).keys, [key]); // no duplicate

me = await (await call("/api/me", { cookie: A.cookie })).json();
assert.deepEqual(me.licences, [{ key, status: "active", txn }]);
assert.deepEqual(me.download, { available: true, name: "Andeville.dmg", version: "" });
assert.equal((await (await call("/api/me", { cookie: A.cookie, e: { ...env, DMG_KEY: "Andeville-0.4.1.dmg" } })).json()).download.version, "0.4.1");

// app sign-in: the page links a challenge, the app trades code + verifier for a bearer session (no Origin, no cookie)
const verifier = "v".repeat(43), challenge = Buffer.from(await crypto.subtle.digest("SHA-256", Buffer.from(verifier))).toString("base64url");
const link = async c => (await (await call("/api/app/link", { method: "POST", body: { challenge }, cookie: c })).json()).code;
const trade = b => w.fetch(new Request(O + "/api/app/token", { method: "POST", body: JSON.stringify(b), headers: { "content-type": "application/json" } }), env);
assert.equal((await call("/api/app/link", { method: "POST", body: { challenge } })).status, 401);
assert.equal((await call("/api/app/link", { method: "POST", body: { challenge: "short" }, cookie: A.cookie })).status, 400);
r = await call("/api/app/link", { method: "POST", body: { challenge }, cookie: B.cookie }); // signed in on the site, but nothing bought: the app stays out
assert.equal(r.status, 403);
assert.deepEqual(await r.json(), { error: "no licence" });
let code = await link(A.cookie);
assert.equal((await trade({ code, verifier: "w".repeat(43) })).status, 401); // wrong verifier, and the code is spent
assert.equal((await trade({ code, verifier })).status, 401);
code = await link(A.cookie);
const { token } = await (await trade({ code, verifier })).json();
assert.match(token, /^[0-9a-f]{64}$/);
assert.equal((await trade({ code, verifier })).status, 401); // one use
const bearer = { authorization: `Bearer ${token}` };
assert.equal((await (await call("/api/me", { headers: bearer })).json()).user.email, "a@b.c");
assert.equal(await (await call("/api/download", { headers: bearer })).text(), "dmgbytes");
const appPost = path => w.fetch(new Request(O + path, { method: "POST", body: "{}", headers: { "content-type": "application/json", ...bearer } }), env);
assert.equal((await appPost("/api/account/delete")).status, 403); // the app's session cannot change the account
assert.equal((await appPost("/api/app/link")).status, 403);
assert.equal(env.ACCOUNTS.m.has("user:dev:a@b.c"), true);
const { token: t2 } = await (await trade({ code: await link(A.cookie), verifier })).json();
r = await w.fetch(new Request(O + "/api/auth/signout", { method: "POST", body: "{}", headers: { "content-type": "application/json", authorization: `Bearer ${t2}` } }), env);
assert.equal(r.status, 200);
assert.equal((await call("/api/me", { headers: { authorization: `Bearer ${t2}` } })).status, 401);

// download gate
assert.equal((await call("/api/download")).status, 401);
assert.equal((await call("/api/download", { cookie: B.cookie })).status, 403);
r = await call("/api/download", { cookie: A.cookie });
assert.equal(r.status, 200);
assert.equal(await r.text(), "dmgbytes");
assert.equal(r.headers.get("content-disposition"), 'attachment; filename="Andeville.dmg"');
assert.equal(r.headers.get("content-length"), "8");
env.LICENCES.m.set(`key:${key}`, JSON.stringify({ txn, status: "revoked" })); // the pay Worker's refund; the owner entry is apart
assert.equal((await call("/api/download", { cookie: A.cookie })).status, 403);
env.LICENCES.m.set(`key:${key}`, JSON.stringify({ txn, status: "active" }));
assert.equal(env.LICENCES.m.get(`owner:${key}`), "dev:a@b.c");

// delete: user and session gone, key keeps working without an owner
r = await call("/api/account/delete", { method: "POST", body: {}, cookie: A.cookie });
assert.equal(r.status, 200);
assert.match(r.headers.get("set-cookie"), /Max-Age=0/);
assert.equal(env.ACCOUNTS.m.has("user:dev:a@b.c"), false);
assert.deepEqual(JSON.parse(env.LICENCES.m.get(`key:${key}`)), { txn, status: "active" });
assert.equal(env.LICENCES.m.has(`owner:${key}`), false);
assert.equal((await call("/api/me", { cookie: A.cookie })).status, 401);
assert.equal((await call("/api/me", { headers: bearer })).status, 401); // the app's session dies with the account
assert.equal((await claim(B.cookie)).status, 200); // free to claim again
// the same person signing in again gets a new account: the cookie from before the delete stays dead
await new Promise(r => setTimeout(r, 5));
const A2 = await login("a@b.c");
assert.equal((await call("/api/me", { cookie: A2.cookie })).status, 200);
assert.equal((await call("/api/me", { cookie: A.cookie })).status, 401);

// sign-out invalidates the session
r = await call("/api/auth/signout", { method: "POST", body: {}, cookie: B.cookie });
assert.equal(r.status, 200);
assert.match(r.headers.get("set-cookie"), /Max-Age=0/);
assert.equal((await call("/api/me", { cookie: B.cookie })).status, 401);

console.log("ok");
