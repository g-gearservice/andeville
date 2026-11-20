// Bot check first; only then does the Worker hand out the checkout settings and Paddle loads.
const SITEKEY = location.hostname === "pay.andeville.app"
  ? "0x4AAAAAAGId2gR0Yc8ZqY9_" // live Turnstile site key
  : "1x00000000000000000000AA"; // Cloudflare's always-pass test key

const btn = document.getElementById("pay");
const msg = document.getElementById("msg");
let tsToken = "", widget;

window.onTurnstile = () => {
  widget = turnstile.render("#ts", {
    sitekey: SITEKEY,
    theme: "dark",
    callback: t => { tsToken = t; btn.disabled = false; },
    "expired-callback": () => { tsToken = ""; btn.disabled = true; },
    "error-callback": () => { msg.textContent = "The bot check could not load. Reload the page to try again."; },
  });
};

btn.addEventListener("click", async () => {
  btn.disabled = true;
  msg.textContent = "Opening checkout…";
  const r = await fetch("/api/checkout", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token: tsToken }) }).catch(() => null);
  turnstile.reset(widget); tsToken = ""; // tokens are single use
  if (!r?.ok) {
    msg.textContent = r?.status === 503 ? "Checkout opens soon." : "The bot check did not pass. Try again.";
    return;
  }
  const cfg = await r.json();
  await loadPaddle(cfg);
  msg.textContent = "";
  // pay.andeville.app/?code=XXXX opens the checkout with that Paddle discount code already applied.
  const code = new URLSearchParams(location.search).get("code") || "";
  Paddle.Checkout.open({ items: [{ priceId: cfg.price, quantity: 1 }], ...(/^[A-Za-z0-9]{1,32}$/.test(code) ? { discountCode: code } : {}) });
});

function loadPaddle(cfg) {
  if (window.Paddle) return Promise.resolve();
  return new Promise((ok, fail) => {
    const s = document.createElement("script");
    s.src = "https://cdn.paddle.com/paddle/v2/paddle.js";
    s.onerror = fail;
    s.onload = () => {
      if (cfg.env === "sandbox") Paddle.Environment.set("sandbox");
      Paddle.Initialize({ token: cfg.token, eventCallback: e => { if (e.name === "checkout.completed") showKey(e.data.transaction_id); } });
      ok();
    };
    document.head.append(s);
  });
}

// Paid: on to the buyer's account on the main site, which signs them in, claims this order's licence (the webhook
// issues it a moment after payment; the account page waits for it) and offers the download.
const SITE = location.hostname === "pay.andeville.app" ? "https://andeville.app" : "https://andeville.gearservice.workers.dev";
function showKey(txn) {
  msg.textContent = "Payment received. Taking you to your account…";
  setTimeout(() => { location.href = `${SITE}/account.html?txn=${encodeURIComponent(txn)}`; }, 2500); // let Paddle's tick show first
}
