// Bot check first; only then does the Worker hand out the checkout settings and Paddle loads.
const SITEKEY = location.hostname === "pay.andeville.app"
  ? "0x4AAAAAAGId2gR0Yc8ZqY9_" // live Turnstile site key
  : "1x00000000000000000000AA"; // Cloudflare's always-pass test key

// Language: the one the site sent the buyer in (?lang=), else the device's own; English when it is neither's.
// i18n.js holds the strings (PAY_I18N, generated from api/i18n/*.json); the English is the page itself.
const LANG = (() => {
  const has = s => s === "en" || Object.hasOwn(PAY_I18N, s);
  const asked = (new URLSearchParams(location.search).get("lang") || "").toLowerCase();
  if (has(asked)) return asked;
  for (const l of navigator.languages || []) {
    try {
      const m = new Intl.Locale(l).maximize(); // zh-TW -> zh-Hant-TW, pt-PT -> pt-Latn-PT
      const hit = [`${m.language}-${m.script}`.toLowerCase(), m.language, Object.keys(PAY_I18N).find(s => s.startsWith(m.language + "-") && m.language !== "zh")].find(s => s && has(s));
      if (hit) return hit;
    } catch {}
  }
  return "en";
})();
const DICT = PAY_I18N[LANG] || {};
const T = (k, en) => DICT[k] || en;
document.documentElement.lang = LANG.replace(/-(\w)(\w+)$/, (_, a, b) => "-" + (b.length > 2 ? a.toUpperCase() + b : (a + b).toUpperCase())); // zh-hans -> zh-Hans, pt-br -> pt-BR
if (LANG === "ar" || LANG === "he") document.documentElement.dir = "rtl";
document.querySelectorAll("[data-i18n]").forEach(e => { if (DICT[e.dataset.i18n]) e.innerHTML = DICT[e.dataset.i18n]; }); // our own strings, shipped with the page
document.querySelectorAll("[data-i18n-attr]").forEach(e => e.dataset.i18nAttr.split(";").forEach(p => { const [a, k] = p.split(":"); if (DICT[k]) e.setAttribute(a, DICT[k]); }));
// The price in the device's own format when it speaks the page's language (en-CA: US$11.11), as on the site.
const REGION = (navigator.languages || []).find(l => { try { const a = new Intl.Locale(l).maximize(), b = new Intl.Locale(document.documentElement.lang).maximize(); return a.language === b.language && a.script === b.script; } catch { return false; } }) || document.documentElement.lang;
document.querySelectorAll("[data-price]").forEach(e => e.textContent = new Intl.NumberFormat(REGION, { style: "currency", currency: "USD", numberingSystem: "latn" }).format(11.11));
// Paddle's checkout speaks these; for anything else (Hebrew) it is left to follow the browser.
const PADDLE_LOCALE = { en: "en", ko: "ko", ja: "ja", "zh-hans": "zh-Hans", "zh-hant": "zh-TW", ru: "ru", es: "es", "pt-br": "pt-BR", ar: "ar", tr: "tr" }[LANG];

const btn = document.getElementById("pay");
const msg = document.getElementById("msg");
let tsToken = "", widget;

window.onTurnstile = () => {
  widget = turnstile.render("#ts", {
    sitekey: SITEKEY,
    theme: "dark",
    callback: t => { tsToken = t; btn.disabled = false; },
    "expired-callback": () => { tsToken = ""; btn.disabled = true; },
    "error-callback": () => { msg.textContent = T("pay.bot_failed", "The bot check could not load. Reload the page to try again."); },
  });
};

btn.addEventListener("click", async () => {
  btn.disabled = true;
  msg.textContent = T("pay.opening", "Opening checkout…");
  const r = await fetch("/api/checkout", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ token: tsToken }) }).catch(() => null);
  turnstile.reset(widget); tsToken = ""; // tokens are single use
  if (!r?.ok) {
    msg.textContent = r?.status === 503 ? T("pay.soon", "Checkout opens soon.") : T("pay.bot_no", "The bot check did not pass. Try again.");
    return;
  }
  const cfg = await r.json();
  await loadPaddle(cfg);
  msg.textContent = "";
  // pay.andeville.app/?code=XXXX opens the checkout with that Paddle discount code already applied.
  const code = new URLSearchParams(location.search).get("code") || "";
  Paddle.Checkout.open({ items: [{ priceId: cfg.price, quantity: 1 }], ...(PADDLE_LOCALE ? { settings: { locale: PADDLE_LOCALE } } : {}), ...(/^[A-Za-z0-9]{1,32}$/.test(code) ? { discountCode: code } : {}) });
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
  msg.textContent = T("pay.received", "Payment received. Taking you to your account…");
  setTimeout(() => { location.href = `${SITE}/${LANG}/account.html?txn=${encodeURIComponent(txn)}`; }, 2500); // let Paddle's tick show first
}
