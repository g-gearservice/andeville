// pay.andeville.app: the payment plate. The page comes from public/; only /api/* reaches this script.
//   POST /api/checkout       Turnstile token in, Paddle checkout settings out (bots never get them)
//   POST /api/paddle         Paddle webhook: transaction.completed issues a key, an approved refund revokes it
//   GET  /api/verify?key=    { valid } for the app
// The buyer gets the key on their account page (api/worker.js claims the txn); it is not handed out by txn here.
// KV (LICENCES): "txn:<txn_id>" -> key, "key:<key>" -> { txn, customer, status }; api/worker.js adds "owner:<key>" -> sub

const ABC = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"; // Crockford base32, no I/L/O/U

export function newKey() {
  const b = crypto.getRandomValues(new Uint8Array(12));
  const s = [...b].map(x => ABC[x & 31]).join("");
  return `ANDV-${s.slice(0, 4)}-${s.slice(4, 8)}-${s.slice(8, 12)}`;
}

// Paddle-Signature: "ts=1700000000;h1=<hex hmac-sha256 of `${ts}:${body}`>"
export async function verifySignature(header, body, secret, now = Date.now() / 1000) {
  const p = Object.fromEntries((header || "").split(";").map(kv => kv.split("=")));
  if (!p.ts || !p.h1 || Math.abs(now - Number(p.ts)) > 300) return false;
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  const sig = new Uint8Array((p.h1.match(/../g) || []).map(h => parseInt(h, 16)));
  return crypto.subtle.verify("HMAC", k, sig, new TextEncoder().encode(`${p.ts}:${body}`)); // constant-time
}

const json = (o, status = 200) => Response.json(o, { status, headers: { "cache-control": "no-store" } });

export default {
  async fetch(req, env) {
    const url = new URL(req.url);
    const kv = env.LICENCES;

    if (url.pathname === "/api/checkout" && req.method === "POST") {
      // ponytail: gates the page, not Paddle itself; a bot holding the public token+price can still open checkout.
      // Upgrade: create the transaction here with a Paddle API key and hand out only its txn id.
      if (!env.PADDLE_CLIENT_TOKEN) return json({ error: "closed" }, 503); // live not set up yet
      const { token } = await req.json().catch(() => ({}));
      const form = new FormData();
      form.append("secret", env.TURNSTILE_SECRET);
      form.append("response", token || "");
      form.append("remoteip", req.headers.get("cf-connecting-ip") || "");
      const v = await (await fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", { method: "POST", body: form })).json();
      if (!v.success) return json({ error: "bot check failed" }, 403);
      return json({ env: env.PADDLE_ENV, token: env.PADDLE_CLIENT_TOKEN, price: env.PADDLE_PRICE_ID });
    }

    if (url.pathname === "/api/paddle" && req.method === "POST") {
      const body = await req.text();
      if (!(await verifySignature(req.headers.get("paddle-signature"), body, env.PADDLE_WEBHOOK_SECRET)))
        return json({ error: "bad signature" }, 401);
      const { event_type, data } = JSON.parse(body);

      // Only a sale of Andeville issues a key: another product, or a simulated demo payload, completes without one.
      if (event_type === "transaction.completed" && data.items?.some(i => i.price?.id === env.PADDLE_PRICE_ID)) {
        if (!(await kv.get(`txn:${data.id}`))) { // Paddle retries; issue once
          const key = newKey();
          await kv.put(`key:${key}`, JSON.stringify({ txn: data.id, customer: data.customer_id, status: "active" }));
          await kv.put(`txn:${data.id}`, key);
        }
      } else if (event_type === "adjustment.updated" && data.status === "approved" && ["refund", "chargeback"].includes(data.action)) {
        // ponytail: any approved refund revokes, partial ones too; check data.type === "full" if partial refunds ever happen
        const key = await kv.get(`txn:${data.transaction_id}`);
        const rec = key && JSON.parse(await kv.get(`key:${key}`));
        if (rec) await kv.put(`key:${key}`, JSON.stringify({ ...rec, status: "revoked" }));
      }
      return json({ ok: true });
    }

    if (url.pathname === "/api/verify" && req.method === "GET") {
      const key = (url.searchParams.get("key") || "").trim().toUpperCase();
      const rec = /^ANDV(-[0-9A-Z]{4}){3}$/.test(key) && JSON.parse(await kv.get(`key:${key}`));
      return json({ valid: rec?.status === "active" });
    }

    return json({ error: "not found" }, 404);
  },
};
