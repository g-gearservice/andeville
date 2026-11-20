// Shared by every page: the price and checkout placeholders, and the live logo.
const PRICE = "$11.11";
document.querySelectorAll("[data-price]").forEach(e => e.textContent = PRICE);

// Payments happen on their own plate: pay.andeville.app (sandbox twin on workers.dev for every other host).
const PAY_URL = /(^|\.)andeville\.app$/.test(location.hostname) ? "https://pay.andeville.app/" : "https://andeville-pay.gearservice.workers.dev/";
document.querySelectorAll("[data-buy]").forEach(e => e.href = PAY_URL);

const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;

// Live mark: logo frames 1-4 flow 1 -> 4 and loop, like an analog dial.
// Each frame is 4 shards; shorter shards repeat their last point so every frame
// has the same point count and can be tweened.
{
  const F = [[[190.1,340.5,33.3,328.9,27.6,550.1,77.7,347.8,31.6,369.4,186.3,328.3,190.1,340.5],[190.1,340.5,200.8,308.7,220.2,281.2,286.8,320.9,186.3,328.3,190.1,340.5],[479.2,428.0,230.1,208.3,286.8,320.9,220.2,281.2,398.8,390.4,479.2,428.0],[454.2,405.6,525.1,102.6,643.4,250.0,545.6,272.4,564.1,193.3,454.8,404.4,454.2,405.6]],[[205.9,305.2,33.2,421.1,10.6,472.3,208.1,344.7,205.9,305.2],[205.9,305.2,338.8,390.8,355.8,366.9,323.1,320.1,208.1,244.4,205.9,305.2],[481.5,411.3,350.6,283.2,323.4,420.8,358.7,372.3,445.7,457.9,481.5,411.3],[440.1,371.2,576.9,309.4,657.5,466.8,605.1,390.8,563.4,321.7,481.5,411.3,440.1,371.2]],[[205.9,280.9,33.2,297.7,10.6,348.9,208.1,221.3,205.9,280.9],[323.1,295.7,208.1,220.1,205.9,280.9,301.5,329.2],[481.5,525.8,350.6,258.9,286.1,359.1,327.9,301.6,445.7,572.3,481.5,525.8],[440.1,406.4,576.9,315.1,657.5,502.0,605.1,396.6,542.5,337.9,481.5,525.8,440.1,406.4]],[[221.6,456.9,38.3,243.4,-0.0,243.4,-0.0,464.6,225.4,296.7,221.6,456.9],[221.6,456.9,337.9,243.4,377.6,243.4,405.9,203.5,352.2,428.6,225.4,296.7,221.6,456.9],[536.8,206.6,393.6,310.1,352.2,428.6,405.9,203.5,448.1,243.4,481.8,243.4,536.8,206.6],[472.6,446.5,598.1,223.5,668.1,441.9,668.1,243.4,620.9,243.4,577.2,456.5,536.8,206.6,472.6,446.5]]];
  const len = F[0].map((_, k) => Math.max(...F.map(f => f[k].length)));
  F.forEach(f => f.forEach((p, k) => { while (p.length < len[k]) p.push(p[p.length - 2], p[p.length - 1]); }));
  const marks = [...document.querySelectorAll(".live-mk")].map(m => m.querySelectorAll("polygon")); // the top bar
  // Analog: no holds. A Catmull-Rom curve runs through the four frames, so the
  // shards never stop at a frame; hover eases the speed up rather than jumping.
  const cr = (p0, p1, p2, p3, t) => {
    const t2 = t * t, t3 = t2 * t;
    return .5 * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3);
  };
  // Footer: the same mark drawn as a grid of 0/1 characters. Cells inside the shards hold a
  // bit, cells outside are blank; a few bits flip each pass so the fill reads as live data.
  const pre = document.querySelector(".foot-bits");
  let grid = null, cur = null, lastBits = 0;
  const measure = () => {
    if (!pre) return;
    const probe = document.createElement("span");
    probe.textContent = "0".repeat(50);
    pre.textContent = "";
    pre.append(probe);
    const cw = probe.getBoundingClientRect().width / 50, lh = parseFloat(getComputedStyle(pre).lineHeight);
    probe.remove();
    const W = pre.clientWidth, H = pre.clientHeight;
    const cols = Math.floor(W / cw), rows = Math.ceil(H / lh);
    // where the mark sits in the footer: capped width, centred, about 60% of it above the bottom edge
    const mw = Math.min(W, 1130), mh = mw * 488 / 668;
    grid = { cols, rows, cw, lh, mw, mh, x0: (W - mw) / 2, y0: H - mh * .615,
             seed: Array.from({ length: cols * rows }, () => Math.random() < .5 ? "0" : "1") };
  };
  const inside = (p, x, y) => {
    let hit = false;
    for (let i = 0, j = p.length - 2; i < p.length; j = i, i += 2)
      if ((p[i + 1] > y) !== (p[j + 1] > y) && x < (p[j] - p[i]) * (y - p[i + 1]) / (p[j + 1] - p[i + 1]) + p[i]) hit = !hit;
    return hit;
  };
  const bits = () => {
    const g = grid;
    for (let n = 0; n < 8; n++) { const k = Math.random() * g.seed.length | 0; g.seed[k] = g.seed[k] === "0" ? "1" : "0"; }
    const box = cur.map(p => {
      let x1 = 1e9, x2 = -1e9, y1 = 1e9, y2 = -1e9;
      for (let i = 0; i < p.length; i += 2) { x1 = Math.min(x1, p[i]); x2 = Math.max(x2, p[i]); y1 = Math.min(y1, p[i + 1]); y2 = Math.max(y2, p[i + 1]); }
      return [x1, x2, y1, y2];
    });
    let out = "";
    for (let r = 0; r < g.rows; r++) {
      const y = 96 + ((r + .5) * g.lh - g.y0) / g.mh * 488;
      for (let c = 0; c < g.cols; c++) {
        const x = ((c + .5) * g.cw - g.x0) / g.mw * 668;
        let hit = false;
        for (let k = 0; k < 4 && !hit; k++) { const b = box[k]; if (x >= b[0] && x <= b[1] && y >= b[2] && y <= b[3]) hit = inside(cur[k], x, y); }
        out += hit ? g.seed[r * g.cols + c] : " ";
      }
      out += "\n";
    }
    pre.textContent = out;
  };
  const draw = (u, now = 0) => {
    const i = Math.floor(u), t = u - i, f = k => F[((i + k) % 4 + 4) % 4];
    const a = f(-1), b = f(0), c = f(1), d = f(2);
    cur = b.map((p, k) => p.map((_, j) => cr(a[k][j], b[k][j], c[k][j], d[k][j], t)));
    marks.forEach(ps => ps.forEach((el, k) => el.setAttribute("points", cur[k].map(v => v.toFixed(1)).join(" "))));
    if (pre && grid && (!now || now - lastBits > 50)) { bits(); lastBits = now; } // ~20 passes a second
  };
  measure();
  addEventListener("resize", () => { measure(); if (reduce) draw(3); });
  const brand = document.querySelector(".brand");
  let u = 0, speed = 1, target = 1, last = performance.now();
  // Only the home page has the bar's logo; the footer's moving mark runs everywhere.
  brand?.addEventListener("mouseenter", () => target = 3.5);
  brand?.addEventListener("mouseleave", () => target = 1);
  draw(reduce ? 3 : 0);
  if (!reduce) requestAnimationFrame(function tick(now) {
    const dt = Math.min(now - last, 50); last = now;
    speed += (target - speed) * Math.min(1, dt / 250);
    u = (u + dt * speed / 1100) % 4; // ~1.1 s per frame at rest
    draw(u, now);
    requestAnimationFrame(tick);
  });
}

// Feature scenes (Products): each plays while it is on screen and loops; off screen, or with
// reduced motion, it rests on its end state.
{
  const scenes = document.querySelectorAll(".scene");
  if (scenes.length && !reduce) {
    const io = new IntersectionObserver(es => es.forEach(e => {
      const s = e.target;
      clearInterval(s._loop);
      s.classList.toggle("on", e.isIntersecting);
      if (e.isIntersecting) s._loop = setInterval(() => { s.classList.remove("on"); s.offsetWidth; s.classList.add("on"); }, 6600);
    }), { threshold: .35 });
    scenes.forEach(s => io.observe(s));
  }
}

// Sticky index: mark the section you are reading.
{
  const rail = document.querySelector(".rail");
  if (rail) {
    const links = [...rail.querySelectorAll('a[href^="#"]')];
    const byTarget = new Map(links.map(a => [document.getElementById(a.hash.slice(1)), a]));
    const io = new IntersectionObserver(es => es.forEach(e => {
      if (!e.isIntersecting) return;
      links.forEach(l => l.removeAttribute("aria-current"));
      byTarget.get(e.target).setAttribute("aria-current", "true");
    }), { rootMargin: "-15% 0px -75% 0px" });
    byTarget.forEach((_, t) => t && io.observe(t));
  }
}




// Questions open and close with a height ease instead of a jump (<details> has none of its own).
// Clicked again mid-way, it turns back from where it is.
{
  const still = matchMedia("(prefers-reduced-motion: reduce)");
  document.querySelectorAll("details").forEach(d => {
    const s = d.querySelector("summary");
    s.addEventListener("click", e => {
      if (still.matches) return;
      e.preventDefault();
      const closing = d._a ? !d._closing : d.open;
      // Measured clipped, as it moves: unclipped, the last paragraph's margin falls outside and the end jumped 18px.
      d.style.overflow = "hidden";
      const from = d.offsetHeight;
      d._a?.cancel();
      d.open = true;
      const to = closing ? s.offsetHeight + (d.offsetHeight - d.clientHeight) : d.offsetHeight; // Borders kept.
      d._closing = closing;
      const a = d._a = d.animate({ height: [from + "px", to + "px"] }, { duration: closing ? 240 : 320, easing: "cubic-bezier(.2,.8,.2,1)" });
      a.onfinish = () => { d._a = null; d.style.overflow = ""; if (closing) d.open = false; };
    });
  });
}

// Teams: the word in "We are … and more." changes every two seconds, out of and back into a blur.
for (const el of document.querySelectorAll("[data-rot]")) {
  if (matchMedia("(prefers-reduced-motion: reduce)").matches) break;
  const words = el.dataset.rot.split(",");
  let i = 0;
  setInterval(() => {
    el.classList.add("is-out");
    setTimeout(() => { el.textContent = words[i = (i + 1) % words.length]; el.classList.remove("is-out"); }, 300);
  }, 2000);
}

// About: while its section is held on screen, the scroll picks the value word (a third each) and moves the pieces around
// it at their own speeds.
for (const sec of document.querySelectorAll(".ab-values")) {
  const words = [...sec.querySelectorAll("[data-word]")], tiles = [...sec.querySelectorAll("[data-speed]")];
  const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
  const tick = () => {
    const run = sec.offsetHeight - innerHeight, y = -sec.getBoundingClientRect().top;
    const q = run > 0 ? Math.min(Math.max(y / run, 0), 1) : 0;
    const n = Math.min(Math.floor(q * words.length), words.length - 1);
    words.forEach((w, i) => w.classList.toggle("on", i === n));
    if (!still) for (const t of tiles) t.style.transform = `translateY(${(-y * t.dataset.speed).toFixed(1)}px)`;
  };
  addEventListener("scroll", tick, { passive: true });
  addEventListener("resize", tick);
  tick();
}


// Products: "What it does" takes one screen and holds the page there. Each scroll (a wheel or trackpad move, a swipe,
// an arrow key) moves one step, with a short cooldown so a hard flick never blurs several away at once: the next
// one rises out of its blur on a spring, the one before blurs and flies up. Past the first or last step the page scrolls
// on as usual. While held, Lenis is paused through gg.js's own "scrolllock" event.
for (const pin of document.querySelectorAll(".pd-pin")) {
  const steps = [...pin.querySelectorAll(".pd-step")], last = steps.length - 1;
  pin.classList.add("is-live");
  let n = 0, held = false, lastY = scrollY, quietUntil = 0;
  const show = i => { n = i; steps.forEach((s, k) => { s.dataset.state = k < i ? "after" : k > i ? "before" : "current"; s.inert = k !== i; }); };
  const top = () => Math.round(pin.getBoundingClientRect().top + scrollY);
  const hold = on => { held = on; dispatchEvent(new CustomEvent("scrolllock", { detail: on })); };
  const step = dir => {
    const now = performance.now();
    if (now < quietUntil) return;
    const to = n + dir;
    if (to < 0 || to > last) { hold(false); return; } // off either end: let the page go
    show(to);
    quietUntil = now + 700; // one step at a time: the next waits until the spring has landed
  };
  show(0);
  // Taken hold of as its top reaches the top of the screen, from above or from below.
  addEventListener("scroll", () => {
    const y = scrollY, t = top(), down = y > lastY;
    lastY = y;
    if (held) return;
    if ((down && n === 0 && y >= t && y < t + innerHeight * .6) || (!down && n === last && y <= t && y > t - innerHeight * .6)) {
      hold(true);
      scrollTo(0, t);
      quietUntil = performance.now() + 450; // the scroll that brought it here doesn't also skip the first step
    }
  }, { passive: true });
  // Wheel and trackpad: any scroll moves a step; the cooldown in step() keeps a long flick from skipping several.
  document.addEventListener("wheel", e => {
    if (!held) return;
    e.preventDefault();
    e.stopPropagation();
    if (Math.abs(e.deltaY) > 2) step(Math.sign(e.deltaY));
  }, { capture: true, passive: false });
  let y0 = null;
  document.addEventListener("touchstart", e => { y0 = held ? e.touches[0].clientY : null; }, { passive: true });
  document.addEventListener("touchmove", e => { if (held) e.preventDefault(); }, { passive: false });
  document.addEventListener("touchend", e => {
    if (y0 === null) return;
    const dy = y0 - e.changedTouches[0].clientY;
    y0 = null;
    if (Math.abs(dy) > 40) step(Math.sign(dy));
  }, { passive: true });
  addEventListener("keydown", e => {
    if (!held) return;
    const dir = { ArrowDown: 1, PageDown: 1, " ": 1, ArrowUp: -1, PageUp: -1 }[e.key];
    if (!dir) return;
    e.preventDefault();
    step(e.shiftKey && e.key === " " ? -1 : dir);
  });
}
