// Account page: talks to /api/* (see api/README.md). Text from the API only ever goes in via textContent.
(() => {
  const $ = id => document.getElementById(id), say = document.querySelector(".say");
  const MAIL = "g@gearservicevanguard.com", NET = T("js.account.net", "Couldn’t reach Andeville. Check your connection and try again.");
  const show = (...ids) => ["ac-load", "ac-off", "ac-out", "ac-app"].forEach(i => $(i).hidden = !ids.includes(i));
  const claimNote = t => { $("ac-claim").textContent = t; $("ac-claim").hidden = !t; };
  const post = (url, body) => fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body || {}) });
  const txn = () => { const t = new URLSearchParams(location.search).get("txn"); return /^txn_\w+$/.test(t || "") ? t : ""; };
  const app = () => { const c = new URLSearchParams(location.search).get("app"); return /^[\w-]{43}$/.test(c || "") ? c : ""; };
  let me = null, gisLoaded = false, claiming = false;

  async function load() {
    let r;
    try { r = await fetch("/api/me"); } catch { show("ac-load"); $("ac-load").textContent = NET; return; }
    if (r.status === 503) { $("ac-h").textContent = T("js.account.your_account", "Your account"); return show("ac-off"); }
    if (r.status === 401) return signedOut();
    if (!r.ok) { show("ac-load"); $("ac-load").textContent = T("js.account.server_error", "Something went wrong on our side. Try again in a moment."); return; }
    me = await r.json(); signedIn();
    if (txn()) claim(); else claimNote("");
  }

  function signedIn() {
    $("ac-h").textContent = T("js.account.your_account", "Your account");
    $("ac-who").textContent = (me.user.name ? me.user.name + " · " : "") + me.user.email; $("ac-who").hidden = false;
    $("ac-pn").textContent = me.user.name || T("js.account.not_given", "Not given"); $("ac-pe").textContent = me.user.email;
    const L = me.licences || [], ok = L.some(l => l.status === "active"), box = $("ac-lics");
    box.replaceChildren(...L.map(l => {
      const dl = document.createElement("dl"); dl.className = "ac-dl";
      [[T("js.account.lic.product", "Product"), T("js.account.lic.personal", "Andeville, personal licence")], [T("js.account.lic.status", "Status"), l.status === "active" ? T("js.account.lic.active", "Active") : T("js.account.lic.revoked", "Revoked")], [T("js.account.lic.key", "Key"), l.key]].forEach(([k, v]) => {
        const dt = document.createElement("dt"), dd = document.createElement("dd"); dt.textContent = k; dd.textContent = v; dl.append(dt, dd);
      });
      return dl;
    }));
    $("ac-nolic").hidden = L.length > 0; $("ac-buy").hidden = L.length > 0;
    $("ac-dl").hidden = !(me.download && me.download.available); $("ac-copy").hidden = !L.length;
    $("ac-revoked").hidden = !(L.length && !ok);
    $("ac-link").hidden = !app();
    show("ac-app");
  }

  async function claim() {
    if (claiming) return; claiming = true;
    const t = txn(), end = Date.now() + 90000;
    claimNote(T("js.account.claim.getting", "Getting your licence…"));
    while (true) {
      let r;
      try { r = await post("/api/claim", { txn: t }); } catch { claimNote(""); say.textContent = NET; break; }
      if (r.ok) { claimNote(T("js.account.claim.done", "Your licence is on your account.")); say.textContent = T("js.account.claim.added", "Licence added to your account."); history.replaceState(null, "", location.pathname); claiming = false; return load(); }
      if (r.status === 409) { history.replaceState(null, "", location.pathname); claimNote(T("js.account.claim.taken", "This purchase is already on another account. Write to {mail} with order {txn} and we will sort it out.", { mail: MAIL, txn: t })); break; }
      if (r.status === 404 && Date.now() < end) { await new Promise(f => setTimeout(f, 1500)); continue; }
      history.replaceState(null, "", location.pathname);
      claimNote(r.status === 404 ? T("js.account.claim.late", "Your key is still on its way. Write to {mail} with order {txn} if it does not show up here soon.", { mail: MAIL, txn: t }) : T("js.account.claim.failed", "We couldn’t add that purchase. Write to {mail} with order {txn}.", { mail: MAIL, txn: t }));
      break;
    }
    claiming = false;
  }

  async function signedOut(msg) {
    me = null; $("ac-who").hidden = true; $("ac-h").textContent = T("js.account.sign_in", "Sign in");
    claimNote(txn() ? T("js.account.signin.paid", "Payment received. Sign in to add the licence to your account.") : app() ? T("js.account.signin.app", "Sign in to connect the Andeville app on your Mac.") : "");
    show("ac-out"); if (msg) say.textContent = msg;
    let cfg;
    try { cfg = await (await fetch("/api/config")).json(); } catch { return; }
    $("ac-dev").hidden = !cfg.devLogin;
    if (!cfg.googleClientId) { $("ac-g").hidden = true; $("ac-gsetup").hidden = false; return; }
    $("ac-g").hidden = false; $("ac-gsetup").hidden = true;
    const go = () => {
      if (!window.google) return;
      $("ac-gfb").hidden = true;
      google.accounts.id.initialize({ client_id: cfg.googleClientId, callback: async resp => {
        try { const r = await post("/api/auth/google", { credential: resp.credential }); if (r.ok) return load(); say.textContent = T("js.account.google_failed", "Google sign-in didn’t go through. Try again."); }
        catch { say.textContent = NET; }
      } });
      google.accounts.id.renderButton($("ac-g"), { theme: "filled_black", size: "large", shape: "rectangular", text: "continue_with", locale: { "zh-Hans": "zh_CN", "zh-Hant": "zh_TW" }[LANG] || LANG }); // the button in the page's language, not the browser's
    };
    if (window.google) return go();
    if (gisLoaded) return; gisLoaded = true;
    const s = document.createElement("script"); s.src = "https://accounts.google.com/gsi/client"; s.async = true; s.onload = go; document.head.append(s);
  }

  $("ac-dev").addEventListener("submit", async e => {
    e.preventDefault();
    try { const r = await post("/api/auth/dev", { token: $("ac-dt").value, email: $("ac-de").value }); if (r.ok) return load(); say.textContent = T("js.account.dev_refused", "Test sign-in was refused."); }
    catch { say.textContent = NET; }
  });
  $("ac-link-b").addEventListener("click", async () => {
    try {
      const r = await post("/api/app/link", { challenge: app() });
      if (!r.ok) { say.textContent = T("js.account.link.failed", "Couldn’t connect the app. Start again from Sign in inside Andeville."); return; }
      const { code } = await r.json();
      history.replaceState(null, "", location.pathname);
      $("ac-link-b").hidden = true; $("ac-link-p").textContent = T("js.account.link.done", "Connected. You can go back to Andeville.");
      location.href = "andeville://signin?code=" + code;
    } catch { say.textContent = NET; }
  });
  $("ac-copy").addEventListener("click", async () => {
    const k = (me.licences.find(l => l.status === "active") || me.licences[0]).key;
    try { await navigator.clipboard.writeText(k); say.textContent = T("js.account.copy.done", "Key copied."); } catch { say.textContent = T("js.account.copy.failed", "Couldn’t copy. Select the key above and copy it by hand."); }
  });
  $("ac-out-b").addEventListener("click", async () => {
    try { await post("/api/auth/signout"); signedOut(T("js.account.signed_out", "You’re signed out.")); } catch { say.textContent = NET; }
  });
  $("ac-del").addEventListener("click", async () => {
    if (!confirm(T("js.account.delete.confirm", "Delete your Andeville account? This removes your profile from our side and can’t be undone. Your licence key keeps working, and your face data never reached us."))) return;
    try { const r = await post("/api/account/delete"); if (r.ok) signedOut(T("js.account.delete.done", "Your account is deleted. Your licence key still works.")); else say.textContent = T("js.account.delete.failed", "Couldn’t delete the account. Try again."); }
    catch { say.textContent = NET; }
  });
  load();
})();
