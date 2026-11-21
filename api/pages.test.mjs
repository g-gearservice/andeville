// node pages.test.mjs — which language a visitor gets, page addresses, and that every translation is in step with the pages.
import assert from "node:assert";
import { negotiate, pretty, LOCALES } from "./pages.js";
import { problems } from "./i18n/sync.mjs";

// the device's languages win, in their own order
assert.equal(negotiate("ko-KR,ko;q=0.9,en-US;q=0.8,en;q=0.7", "US"), "ko");
assert.equal(negotiate("en-US,en;q=0.9,ko;q=0.8", "KR"), "en"); // an English device in Korea reads English
assert.equal(negotiate("ko;q=0.5, ja;q=0.9", "KR"), "ja"); // q before position
assert.equal(negotiate("de-DE,de;q=0.9,en;q=0.8", "JP"), "en"); // not ours first, English listed: English, not the country's
assert.equal(negotiate("ja;q=0, en", "JP"), "en"); // q=0 is a refusal
// region and script variants
assert.equal(negotiate("zh-TW", "US"), "zh-hant");
assert.equal(negotiate("zh-HK", "US"), "zh-hant");
assert.equal(negotiate("zh-Hant-CN", "CN"), "zh-hant");
assert.equal(negotiate("zh-Hans-TW", "TW"), "zh-hans"); // script beats region
assert.equal(negotiate("zh-CN", "TW"), "zh-hans");
assert.equal(negotiate("zh", "TW"), "zh-hant"); // a bare zh goes by where they are
assert.equal(negotiate("zh", "CN"), "zh-hans");
assert.equal(negotiate("zh", undefined), "zh-hans");
assert.equal(negotiate("pt-PT", "PT"), "pt-br");
assert.equal(negotiate("es-MX", "MX"), "es");
assert.equal(negotiate("iw-IL", "IL"), "he"); // the old code for Hebrew
// the country only fills the gap
assert.equal(negotiate("", "KR"), "ko");
assert.equal(negotiate(null, "BR"), "pt-br");
assert.equal(negotiate("fr-FR,fr;q=0.9", "AE"), "ar");
assert.equal(negotiate("uk-UA,uk", "UA"), "en"); // never Russian by guess
assert.equal(negotiate("*", "DE"), "en");
assert.equal(negotiate("x; q=abc, <script>, ko", undefined), "ko"); // junk is skipped
assert.equal(negotiate(undefined, undefined), "en");
for (const s of ["ko", "ja", "zh-hans", "zh-hant", "ru", "es", "pt-br", "ar", "he", "tr"]) assert.equal(negotiate(LOCALES[s].tag, "US"), s);

assert.equal(pretty("/"), "/");
assert.equal(pretty("/index.html"), "/");
assert.equal(pretty("/about.html"), "/about");
assert.equal(pretty("/about"), "/about");

// en.json and the pay page's strings match the pages; every language has every key and keeps the markup
assert.deepEqual(problems(), []);
console.log("ok");
