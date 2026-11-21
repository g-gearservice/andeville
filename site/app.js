// Landing page only (needs common.js first): headline, hero notch, highlights carousel.
// Hero headline: one line that rewrites itself.
// "We are not Original." -> "We are not Pro." -> "But, we are just one." -> "And..." -> "Andeville."
// The last step: "eville." drifts in from the right and snaps onto "And" like a magnet.
// Each slot holds its word variants stacked in one grid cell; the active one is
// sharp, the rest blurred out, and the slot's width slides to fit the active one.
{
  const h1 = document.querySelector(".hero h1");
  // Each word carries its own trailing space, and every word but the last can turn into "" (nothing), so at "And..." the
  // rest of the line blurs away and its width closes up: "Andeville." ends alone in the middle of the centred headline.
  const SLOTS = [["", "But,\u00a0", ""], ["We\u00a0", "we\u00a0", ""], ["are\u00a0", ""], ["not\u00a0", "just\u00a0", ""], ["Original.", "Pro.", "one.", "Andeville."]];
  const STATES = [[0, 0, 0, 0, 0], [0, 0, 0, 0, 1], [1, 1, 0, 1, 2], [2, 2, 1, 2, 3]]; // variant per slot, in order
  h1.setAttribute("aria-label", "We are not Original. We are not Pro. But, we are just one. Andeville.");
  h1.textContent = "";
  const slots = SLOTS.map(v => {
    if (typeof v === "string") { h1.append(v); return null; }
    const sl = document.createElement("span");
    sl.className = "sl"; sl.setAttribute("aria-hidden", "true");
    v.forEach(w => {
      const e = document.createElement("span");
      if (w === "Andeville.") { e.className = "acc andev"; e.innerHTML = '<b>And</b><i>...</i><u>eville.</u>'; } // "And..." first; snap() brings "eville." on
      else { e.textContent = w; if (w === "one.") e.className = "acc"; }
      sl.append(e);
    });
    h1.append(sl);
    return sl;
  }).filter(Boolean);
  const show = k => slots.forEach((sl, j) => {
    const vs = [...sl.children];
    vs.forEach((e, n) => e.classList.toggle("on", n === STATES[k][j]));
    sl.style.width = vs[STATES[k][j]].offsetWidth + "px";
  });
  const hero = document.querySelector(".hero");
  const andev = h1.querySelector(".andev");
  // once "eville." has landed, the word is highlighted the way a selection is: brand orange behind, ink letters
  const snap = () => { andev.classList.add("snapped"); const sl = andev.parentElement; sl.style.width = andev.offsetWidth + "px"; setTimeout(() => andev.classList.add("lit"), reduce ? 0 : 1300); };
  if (reduce) { slots.forEach(sl => sl.style.transition = "none"); show(3); snap(); hero.classList.add("go"); }
  else {
    // start once the font is in and the tab is actually visible, so the intro isn't missed
    const play = () => {
      // the headline arrives already reading "We are not Original." (no width slide),
      // rising out of a blur last in the domino; then the words start swapping
      slots.forEach(sl => sl.style.transition = "none");
      [...h1.querySelectorAll(".sl>span")].forEach(e => e.style.transition = "none");
      show(0);
      h1.offsetWidth;
      slots.forEach(sl => sl.style.transition = "");
      h1.querySelectorAll(".sl>span").forEach(e => e.style.transition = "");
      hero.classList.add("go");
      setTimeout(() => show(1), 3200);
      setTimeout(() => show(2), 5600);
      setTimeout(() => show(3), 8400); // "one." gives way to "And..."
      setTimeout(snap, 10400); // and "eville." snaps on
    };
    document.fonts.ready.then(() => {
      if (!document.hidden) return play();
      document.addEventListener("visibilitychange", play, { once: true });
    });
  }
  // keep widths right if the font size changes with the window
  addEventListener("resize", () => slots.forEach(sl => {
    const on = sl.querySelector(".on"); if (on) sl.style.width = on.offsetWidth + "px";
  }));
}

// Hero: point at the notch -> scan -> welcome back -> idle
const screen = document.querySelector(".screen");
const heroText = screen.querySelector(".h-text"), heroHint = screen.querySelector(".h-hint");
function heroScan() {
  if (screen.dataset.hero !== "idle") return;
  const set = (s, text, hint, label) => {
    screen.dataset.hero = s; heroText.textContent = text; heroHint.textContent = hint;
    screen.setAttribute("aria-label", label);
  };
  set("scan", T("js.ui.checking", "Checking it’s you…"), T("js.index.fill_light_on", "Fill light on"), T("js.index.notch_scan", "Notch: checking it’s you"));
  setTimeout(() => set("ok", T("js.ui.welcome", "Welcome back"), T("js.ui.unlocked", "Unlocked"), T("js.index.notch_ok", "Notch: unlocked, welcome back")), 1600);
  setTimeout(() => set("idle", T("js.ui.checking", "Checking it’s you…"), T("js.ui.point", "Point at the notch"), T("js.index.notch_idle", "Notch: locked. Point here to unlock")), 5200);
}
screen.addEventListener("click", heroScan);
screen.addEventListener("mouseenter", heroScan);

// Highlights: endless carousel. Three copies of the slides; after each move we
// jump back into the middle copy with transitions off, so it never runs out.
const DUR = 6200;
const car = document.querySelector(".car"), track = car.querySelector(".track");
const src = [...track.children], n = src.length;
const clone = () => src.map(s => { const c = s.cloneNode(true); c.setAttribute("aria-hidden", "true"); return c; });
track.prepend(...clone());
track.append(...clone());
const all = [...track.children];
all.forEach((s, j) => {
  s.dataset.i = j % n;
  const b = document.createElement("button");
  b.className = "peek";
  b.setAttribute("aria-label", T("js.index.show", "Show {name}", { name: s.getAttribute("aria-label") }));
  if (s.hasAttribute("aria-hidden")) b.tabIndex = -1; // clones stay clickable, not tabbable
  b.addEventListener("click", () => moveTo(j));
  s.prepend(b);
});

const dotsEl = car.querySelector(".dots");
const dots = src.map((s, i) => {
  const d = document.createElement("button");
  d.className = "dot"; d.setAttribute("role", "tab");
  d.setAttribute("aria-label", s.getAttribute("aria-label"));
  d.innerHTML = "<i></i>";
  d.addEventListener("click", () => go(i));
  dotsEl.append(d);
  return d;
});

let pos = n, el = 0, playing = !reduce, nz;
const idx = () => ((pos % n) + n) % n;

function render() {
  const i = idx();
  track.style.setProperty("--pos", -pos);
  all.forEach((s, j) => {
    // restart the scene only when a slide becomes active
    const on = j % n === i;
    if (on !== s.classList.contains("on")) s.classList.toggle("on", on);
  });
  dots.forEach((d, k) => {
    d.setAttribute("aria-selected", k === i);
    d.firstChild.style.width = k === i ? Math.min(100, el / DUR * 100) + "%" : "0%";
  });
  car.classList.toggle("paused", !playing);
  pp.setAttribute("aria-label", playing ? T("js.index.pause", "Pause highlights") : T("js.index.play", "Play highlights"));
}

function moveTo(p) {
  clearTimeout(nz);
  track.classList.remove("snap");
  pos = p; el = 0; render();
  nz = setTimeout(() => {
    if (pos >= n && pos < 2 * n) return;
    track.classList.add("snap");
    pos = idx() + n; render();
    track.offsetWidth; // flush the jump before transitions come back
    track.classList.remove("snap");
  }, 850);
}

function go(i) {
  let d = i - idx();
  if (!d) return;
  if (d > n / 2) d -= n;
  if (d < -n / 2) d += n;
  moveTo(pos + d);
}

const pp = car.querySelector(".pp");
pp.addEventListener("click", () => { playing = !playing; render(); });

setInterval(() => {
  if (!playing || document.hidden) return;
  el += 100;
  if (el >= DUR) moveTo(pos + 1); else render();
}, 100);

render();
