# Andeville accounts API (`api/worker.js`)

Runs on the marketing site's own Worker (root `wrangler.jsonc`), same origin as the pages, so the session is a plain
first-party cookie. Payments stay on the pay plate (`pay/`); both Workers share the `LICENCES` KV.

Flow: buy on the pay plate → Paddle webhook issues an `ANDV-…` key under `txn:<id>` → the pay page sends the buyer to
`/account.html?txn=<id>` → they sign in with Google → the page claims the transaction into their account → Download.

## Bindings (all optional: a missing one makes the routes that need it answer 503 `{error:"unavailable"}`)

- `ACCOUNTS` KV: `user:<sub>` → `{sub,email,name,picture,created,keys:[key…]}`, `sess:<id>` → `{sub,created,app?}` (30-day TTL, a year for the app's; dead once the user's `created` differs), `link:<code>` → `{sub,created,challenge}` (5 minutes, one use)
- `LICENCES` KV: `txn:<txn>` → key and `key:<key>` → `{txn,customer,status}` are written by `pay/worker.js` and only read here; this Worker adds `owner:<key>` → sub
- `DOWNLOADS` R2: the DMG, object name in var `DMG_KEY`
- vars: `GOOGLE_CLIENT_ID`, `PAY_URL`, `DMG_KEY`, `DEV_LOGIN_TOKEN` (test site only)

## Routes (JSON in and out, `cache-control: no-store`)

| Route | In | Out |
|---|---|---|
| `GET /api/config` | – | `{googleClientId, payUrl, devLogin: bool}` |
| `GET /api/me` | cookie | `200 {user:{email,name,picture}, licences:[{key,status,txn}], download:{available,name,version}}` (`version` read off `DMG_KEY`, `Andeville-<version>.dmg`) · `401 {error:"signed out"}` |
| `POST /api/auth/google` | `{credential}` (Google Identity Services ID token) | `200 {ok:true}` + session cookie · `401 {error}` |
| `POST /api/auth/dev` | `{token,email,name?}` | same as above; `404` unless `DEV_LOGIN_TOKEN` is set and matches |
| `POST /api/auth/signout` | cookie | `200 {ok:true}`, cookie cleared |
| `POST /api/claim` | `{txn}` | `200 {key}` · `404 {pending:true}` (webhook not landed yet) · `409 {error:"claimed"}` (another account has it) · `400` bad txn |
| `POST /api/app/link` | cookie, `{challenge}` (base64url SHA-256 of the app's verifier) | `200 {code}` · `400` bad challenge · `403 {error:"no licence"}` (no active licence on the account: the app signs in only after a purchase) |
| `POST /api/app/token` | `{code,verifier}`, no cookie or Origin | `200 {token}` (the app's session) · `401 {error:"bad code"}` |
| `GET /api/download` | cookie or bearer | the DMG (`content-disposition: attachment`) · `401` signed out · `403 {error:"no licence"}` |
| `POST /api/account/delete` | cookie | `200 {ok:true}`: user and session removed, their keys keep working but lose their `owner:` entry |

Session cookie: `andv_s=<id>; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=2592000`.
Every POST must carry `content-type: application/json` and an `Origin` equal to the request's own origin (CSRF), else 403.
The app signs in through the site, so every sign-in the site offers works in the app: it opens
`/account.html?app=<challenge>`, the signed-in page posts `/api/app/link` and sends the browser to
`andeville://signin?code=<code>`, and the app trades code and verifier at `/api/app/token` for a token it sends as
`Authorization: Bearer <token>` (PKCE: a code alone is worth nothing). Bearer calls skip the Origin check; the app's
session reads `/api/me`, downloads and signs out, and gets 403 on anything that changes the account.
A licence counts for download only while its `key:` record has `status: "active"`.

## Languages (`api/pages.js`)

Every page request goes through the Worker too. The English lives in `site/*.html` itself; the Worker rewrites it into
the visitor's language from `api/i18n/<slug>.json` (HTMLRewriter), sets `<html lang dir>`, adds `canonical` and
`hreflang` links and fills the footer's language menu.

- `/about` is negotiated: the device's languages (`Accept-Language`, by q then order) first; the country Cloudflare saw
  (`request.cf.country`) only when the device names none of ours, and to tell a bare `zh` apart. English is served
  there; any other language is a 302 to its own address.
- `/ko/about`, `/ja/…`, `/zh-hans/`, `/zh-hant/`, `/ru/`, `/es/`, `/pt-br/`, `/ar/`, `/he/`, `/tr/`: that language, always.
  `/en/about`: English, always (the language menu's English; canonical is `/about`).
- Marks: `data-i18n="key"` (inner HTML), `data-i18n-attr="attr:key;attr:key"`, and in scripts
  `T("js.key", "English", { name })`; only `js.*` keys are sent to the browser. Keys ending `.list` are comma lists.
- Price and dates are formatted in the browser for the device's own region when it speaks the page's language
  (`common.js`), so `en-CA` reads `US$11.11`.
- The pay plate has no Worker for pages: `pay/public/i18n.js` (generated) carries its strings and `pay.js` picks the
  language from `?lang=` (the site's buy link sends it) or the device.

After changing any English text: `node api/i18n/sync.mjs` (rewrites `en.json` and `pay/public/i18n.js`), update the
translations, then `node api/pages.test.mjs` (fails while a translation misses a key or changes a string's markup).
A new language: its JSON, one line in `LOCALES` and in `match()` in `pages.js`.

Local: `npx wrangler dev --env=""` serves pages and API together; `python3 -m http.server -d site` still shows the
English pages without the Worker.
