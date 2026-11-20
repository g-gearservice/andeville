# Andeville accounts API (`api/worker.js`)

Runs on the marketing site's own Worker (root `wrangler.jsonc`), same origin as the pages, so the session is a plain
first-party cookie. Payments stay on the pay plate (`pay/`); both Workers share the `LICENCES` KV.

Flow: buy on the pay plate → Paddle webhook issues an `ANDV-…` key under `txn:<id>` → the pay page sends the buyer to
`/account.html?txn=<id>` → they sign in with Google → the page claims the transaction into their account → Download.

## Bindings (all optional: a missing one makes the routes that need it answer 503 `{error:"unavailable"}`)

- `ACCOUNTS` KV: `user:<sub>` → `{sub,email,name,picture,created,keys:[key…]}`, `sess:<id>` → `{sub,created}` (30-day TTL; dead once the user's `created` differs)
- `LICENCES` KV: `txn:<txn>` → key and `key:<key>` → `{txn,customer,status}` are written by `pay/worker.js` and only read here; this Worker adds `owner:<key>` → sub
- `DOWNLOADS` R2: the DMG, object name in var `DMG_KEY`
- vars: `GOOGLE_CLIENT_ID`, `PAY_URL`, `DMG_KEY`, `DEV_LOGIN_TOKEN` (test site only)

## Routes (JSON in and out, `cache-control: no-store`)

| Route | In | Out |
|---|---|---|
| `GET /api/config` | – | `{googleClientId, payUrl, devLogin: bool}` |
| `GET /api/me` | cookie | `200 {user:{email,name,picture}, licences:[{key,status,txn}], download:{available,name}}` · `401 {error:"signed out"}` |
| `POST /api/auth/google` | `{credential}` (Google Identity Services ID token) | `200 {ok:true}` + session cookie · `401 {error}` |
| `POST /api/auth/dev` | `{token,email,name?}` | same as above; `404` unless `DEV_LOGIN_TOKEN` is set and matches |
| `POST /api/auth/signout` | cookie | `200 {ok:true}`, cookie cleared |
| `POST /api/claim` | `{txn}` | `200 {key}` · `404 {pending:true}` (webhook not landed yet) · `409 {error:"claimed"}` (another account has it) · `400` bad txn |
| `GET /api/download` | cookie | the DMG (`content-disposition: attachment`) · `401` signed out · `403 {error:"no licence"}` |
| `POST /api/account/delete` | cookie | `200 {ok:true}`: user and session removed, their keys keep working but lose their `owner:` entry |

Session cookie: `andv_s=<id>; HttpOnly; Secure; SameSite=Lax; Path=/; Max-Age=2592000`.
Every POST must carry `content-type: application/json` and an `Origin` equal to the request's own origin (CSRF), else 403.
A licence counts for download only while its `key:` record has `status: "active"`.
