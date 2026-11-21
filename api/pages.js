// Pages: every request outside /api/ that the Worker is given (wrangler.jsonc, run_worker_first). It picks the visitor's
// language and serves site/'s English HTML rewritten into it from api/i18n/<locale>.json.
//   /about      negotiated: the device's languages (Accept-Language) in their order, then the country Cloudflare saw
//               (request.cf.country). English is served right here; any other language is a 302 to its own address.
//   /ko/about   that language, always: shareable and indexable, tied together with hreflang.
//   /en/about   English, always: where the language menu sends someone whose device asks for another language.
// The English text lives in the HTML itself (data-i18n marks what is translated); `node api/i18n/sync.mjs` keeps
// en.json in step with it.
import ko from "./i18n/ko.json" with { type: "json" };
import ja from "./i18n/ja.json" with { type: "json" };
import zhHans from "./i18n/zh-hans.json" with { type: "json" };
import zhHant from "./i18n/zh-hant.json" with { type: "json" };
import ru from "./i18n/ru.json" with { type: "json" };
import es from "./i18n/es.json" with { type: "json" };
import ptBr from "./i18n/pt-br.json" with { type: "json" };
import ar from "./i18n/ar.json" with { type: "json" };
import he from "./i18n/he.json" with { type: "json" };
import tr from "./i18n/tr.json" with { type: "json" };

// slug (the address) -> tag (html lang, hreflang), own name (the menu), dictionary. A new language is one line here,
// one in match() and its JSON file.
export const LOCALES = {
  en: { tag: "en", name: "English" },
  ko: { tag: "ko", name: "한국어", dict: ko },
  ja: { tag: "ja", name: "日本語", dict: ja },
  "zh-hans": { tag: "zh-Hans", name: "简体中文", dict: zhHans },
  "zh-hant": { tag: "zh-Hant", name: "繁體中文", dict: zhHant },
  ru: { tag: "ru", name: "Русский", dict: ru },
  es: { tag: "es", name: "Español", dict: es },
  "pt-br": { tag: "pt-BR", name: "Português", dict: ptBr },
  ar: { tag: "ar", name: "العربية", dict: ar, rtl: true },
  he: { tag: "he", name: "עברית", dict: he, rtl: true },
  tr: { tag: "tr", name: "Türkçe", dict: tr },
};

// Where a visitor is only decides when their device doesn't: no Accept-Language, or none of its languages is ours.
const COUNTRY = { KR: "ko", JP: "ja", CN: "zh-hans", TW: "zh-hant", HK: "zh-hant", MO: "zh-hant", BR: "pt-br", PT: "pt-br", IL: "he", TR: "tr" };
for (const c of "RU BY KZ KG".split(" ")) COUNTRY[c] = "ru";
for (const c of "MX AR CO CL PE VE EC GT CU BO DO HN PY SV NI CR PA UY PR ES".split(" ")) COUNTRY[c] = "es";
for (const c of "SA AE QA KW BH OM EG JO LB IQ SY YE PS".split(" ")) COUNTRY[c] = "ar";

// One language tag -> our slug, or null. Chinese goes by script, then region, then (a bare "zh") the country.
function match(tag, country) {
  const [lang, ...sub] = tag.toLowerCase().split("-");
  if (lang === "zh") {
    const region = ["tw", "hk", "mo"].some(r => sub.includes(r)) || (!sub.length && COUNTRY[country] === "zh-hant");
    return sub.includes("hant") || (!sub.includes("hans") && region) ? "zh-hant" : "zh-hans";
  }
  return { en: "en", ko: "ko", ja: "ja", ru: "ru", es: "es", pt: "pt-br", ar: "ar", he: "he", iw: "he", tr: "tr" }[lang] ?? null;
}

// Accept-Language + country -> slug. The device's own order wins (q values, then position); the country fills the gap.
export function negotiate(header, country) {
  const tags = String(header || "").split(",").map((part, i) => {
    const [t, ...params] = part.split(";");
    const q = params.map(p => /^\s*q\s*=\s*([\d.]+)\s*$/i.exec(p)?.[1]).find(v => v !== undefined);
    return { t: t.trim(), q: q === undefined ? 1 : Number(q), i };
  }).filter(x => /^[a-z]{2,3}(-[a-z0-9]+)*$/i.test(x.t) && x.q > 0).sort((a, b) => b.q - a.q || a.i - b.i);
  for (const { t } of tags) { const m = match(t, country); if (m) return m; }
  return COUNTRY[country] || "en";
}

const esc = s => String(s).replace(/[&<>"]/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]);
const isPage = p => p.endsWith("/") || p.endsWith(".html") || !/\.[a-z0-9]+$/i.test(p);
// "/index.html" -> "/", "/about.html" -> "/about": the address a page is known by
export const pretty = p => p.replace(/(\/index)?(\.html)?$/, "") || "/";
const at = (slug, pp) => (slug ? `/${slug}` : "") + (slug && pp === "/" ? "/" : pp);

export async function page(req, env, url) {
  if (req.method !== "GET" && req.method !== "HEAD") return env.ASSETS.fetch(req);
  const first = url.pathname.split("/")[1];
  const slug = Object.hasOwn(LOCALES, first) ? first : "";
  if (slug && url.pathname === `/${slug}`) return Response.redirect(`${url.origin}/${slug}/${url.search}`, 302); // relative links need the slash
  const path = slug ? url.pathname.slice(slug.length + 1) : url.pathname;
  const asset = new URL(url); // same origin whatever the path looks like ("//host" would otherwise resolve to another one)
  asset.pathname = path;
  if (!isPage(path)) return env.ASSETS.fetch(new Request(asset, { method: req.method }));

  const vary = slug ? {} : { vary: "Accept-Language" };
  if (!slug) {
    const want = negotiate(req.headers.get("accept-language"), req.cf?.country);
    if (want !== "en") return new Response(null, { status: 302, headers: { location: at(want, pretty(path)) + url.search, "cache-control": "no-store", ...vary } });
  }

  // No conditional headers go along: the asset's ETag knows nothing of the translation, so a 304 could keep an old one alive.
  const res = await env.ASSETS.fetch(new Request(asset, { method: req.method }));
  const loc = res.headers.get("location");
  if (res.status >= 300 && res.status < 400 && loc?.startsWith("/") && !loc.startsWith("//")) { // "/about.html" -> "/about": kept inside the language
    const h = new Headers(res.headers);
    h.set("location", (slug ? `/${slug}` : "") + loc);
    return new Response(null, { status: res.status, headers: h });
  }
  if (!res.ok || !(res.headers.get("content-type") || "").includes("text/html")) return res;

  const L = LOCALES[slug || "en"], dict = L.dict, pp = pretty(path);
  const href = s => esc(url.origin + at(s, pp));
  const head = `<link rel="canonical" href="${href(slug === "en" ? "" : slug)}">`
    + Object.entries(LOCALES).map(([s, l]) => `<link rel="alternate" hreflang="${l.tag}" href="${href(s === "en" ? "" : s)}">`).join("")
    + `<link rel="alternate" hreflang="x-default" href="${href("")}">`
    // The strings the page's scripts say (js.*), for T() in common.js. "<" is escaped so no value can close the script.
    + (dict ? `<script>window.I18N=${JSON.stringify(Object.fromEntries(Object.entries(dict).filter(([k]) => k.startsWith("js.")))).replace(/</g, "\\u003c")}</script>` : "");
  const menu = Object.entries(LOCALES).map(([s, l]) =>
    `<option value="${esc(at(s, pp) + url.search)}" lang="${l.tag}"${s === (slug || "en") ? " selected" : ""}>${l.name}</option>`).join("");

  const rw = new HTMLRewriter()
    .on("html", { element(e) { e.setAttribute("lang", L.tag); if (L.rtl) e.setAttribute("dir", "rtl"); } })
    .on("head", { element(e) { e.append(head, { html: true }); } })
    .on("select.foot-lang", { element(e) { e.removeAttribute("hidden"); e.setInnerContent(menu, { html: true }); } });
  // Under a language's address the page's own files (style.css, common.js, the font) still live at the root.
  if (slug) for (const [sel, a] of [["link[href]", "href"], ["script[src]", "src"]])
    rw.on(sel, { element(e) { const v = e.getAttribute(a); if (!/^([a-z][a-z0-9+.-]*:|\/|#)/i.test(v)) e.setAttribute(a, "/" + v); } });
  if (dict) rw
    .on("[data-i18n]", { element(e) { const v = dict[e.getAttribute("data-i18n")]; if (v) e.setInnerContent(v, { html: true }); } })
    .on("[data-i18n-attr]", { element(e) {
      for (const pair of e.getAttribute("data-i18n-attr").split(";")) {
        const [a, k] = pair.split(":").map(s => s.trim());
        if (dict[k]) e.setAttribute(a, dict[k]);
      }
    } });

  const h = new Headers(res.headers);
  h.delete("etag"); h.delete("last-modified"); h.delete("content-length");
  h.set("content-language", L.tag);
  h.set("cache-control", "no-cache");
  if (vary.vary) h.set("vary", vary.vary);
  return rw.transform(new Response(res.body, { status: res.status, headers: h }));
}
