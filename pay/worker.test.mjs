// node worker.test.mjs — webhook signature, only our price issues, once; verify, refund revokes.
import assert from "node:assert";
import w, { newKey, verifySignature } from "./worker.js";

const secret = "pdl_ntfset_test";
const store = new Map();
const env = { PADDLE_WEBHOOK_SECRET: secret, PADDLE_PRICE_ID: "pri_andv", LICENCES: { get: async k => store.get(k) ?? null, put: async (k, v) => void store.set(k, v) } };

async function sign(body, ts = Math.floor(Date.now() / 1000)) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const h = Buffer.from(await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(`${ts}:${body}`))).toString("hex");
  return `ts=${ts};h1=${h}`;
}
const hook = async (o, sig) => { const body = JSON.stringify(o); return w.fetch(new Request("https://x/api/paddle", { method: "POST", body, headers: { "paddle-signature": sig ?? await sign(body) } }), env); };
const get = async path => (await w.fetch(new Request("https://x" + path), env)).json();

assert.match(newKey(), /^ANDV(-[0-9A-HJKMNP-TV-Z]{4}){3}$/);
assert.equal(await verifySignature("ts=1;h1=00", "x", secret), false); // stale

const txn = "txn_01m7sb1fpge1paqp4a3cx5026q";
const done = { event_type: "transaction.completed", data: { id: txn, customer_id: "ctm_1", items: [{ price: { id: "pri_andv" } }] } };
assert.equal((await hook(done, "ts=1;h1=bad")).status, 401);
await hook({ ...done, data: { ...done.data, items: [{ price: { id: "pri_other" } }] } }); // another product: no key
assert.equal(store.has(`txn:${txn}`), false);
assert.equal((await hook(done)).status, 200);
const key = store.get(`txn:${txn}`);
await hook(done); // Paddle retry
assert.equal(store.get(`txn:${txn}`), key);
assert.equal((await get(`/api/verify?key=${key.toLowerCase()}`)).valid, true);
assert.equal((await get(`/api/verify?key=ANDV-0000-0000-0000`)).valid, false);
await hook({ event_type: "adjustment.updated", data: { action: "refund", status: "approved", transaction_id: txn } });
assert.equal((await get(`/api/verify?key=${key}`)).valid, false);
console.log("ok", key);
