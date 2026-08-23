# App Accounts, Public Serving & Login (App API v2 origins)

Everything in this file exists **only when the deployment serves apps from
per-app origins** (`app.appsBaseUrl` configured). On a per-app origin your
app is a first-class website: it can serve pages to the public, run its own
sign-up/login, and receive users from Informer, an external IdP, or other
apps — all as ONE unified principal shape.

Path-mode serving (`/api/apps/{id}/view` on the Informer origin) never
serves anonymously and has none of the `/_auth` surface.

## The one-sentence model

> Apps have **accounts**; accounts have **issuers** (`informer`, `local`,
> `oidc:<name>`, `app:<callerId>`); sessions bind an account to the app's
> origin as an HttpOnly cookie; role authority is per-issuer.

Whatever the door, your handlers see the same thing:

```js
request.user = {
    id,        // stable account uuid — key your data on this
    issuer,    // 'informer' | 'local' | 'oidc:<name>' | 'app:<callerAppId>'
    subject,   // identity at the issuer (username / email / oidc sub / caller account id)
    email, name, claims
}
// Informer viewers ADDITIONALLY keep the legacy fields:
// username, displayName, timezone — old code never breaks.
request.roles  // resolved per-issuer; see Roles below
```

## Tier 0 — public serving (no session at all)

```yaml
# informer.yaml
public: true          # host page + compiled assets serve ANONYMOUSLY
```

- Handlers under **`server/public/**`** dispatch without authentication at
  `/api/public/...` — the `/public` segment stays in the URL so anonymity is
  auditable at a glance. `request.user` is `null` there; the handler still
  runs owner-backed (workspace `query()` works).
- Assets are all-or-nothing: `public: true` exposes the whole compiled
  bundle. Protect DATA in your routes, not by hiding JS.
- Anonymous visitors can never reach `access.apis` platform APIs (401).
- Webhooks (`webhooks/`, token-gated) remain the machine-to-machine surface;
  public routes are the human surface.

Being a real origin, a public app can also ship a web-app manifest, a
service worker (offline), notifications, Web Share, localStorage — the
normal web platform.

## Local accounts — the app's own sign-up/login

```yaml
accounts:
  issuers:
    local:
      signup: open            # or 'invite' (403s /_auth/signup)
      defaultRole: member
      email:                  # password-reset mail branding (optional)
        fromName: Backstage   # display name over the TENANT's sender (SPF-safe)
        replyTo: fans@example.com
        subject: Reset your Backstage password
```

Declaring this makes these routes live **on the app's origin** (they 404
everywhere else). Your app renders its own branded pages and calls them
with ordinary same-origin `fetch` (`credentials: 'same-origin'`):

| Route | Notes |
|---|---|
| `POST /_auth/signup` `{ email, password, name? }` | 201 + session cookie; 409 duplicate; 403 when `signup: invite` |
| `POST /_auth/login` `{ email, password }` | 200 + session cookie; ONE generic 401 for every failure (no enumeration); rate-limited + lockout |
| `POST /_auth/logout` | 204, clears the cookie |
| `POST /_auth/reset` `{ email }` | ALWAYS 200; a live local account gets a platform email with `/?reset=<token>` (single-use, 30 min) — your page renders the reset form |
| `POST /_auth/reset/confirm` `{ token, password }` | burns the token, sets the password; no session — log in again |

The platform holds the credentials (bcrypt, lockout, rate limits); your app
never touches password material. Sessions are HttpOnly origin cookies with
sliding renewal — never store tokens in JS.

**Session probe pattern**: call any ordinary route (e.g. a `server/me.js`
returning `request.user`) — 401 means signed out.

## OIDC — sign in with the customer's IdP

```yaml
accounts:
  issuers:
    oidc:
      college:
        discovery: https://idp.college.edu/.well-known/openid-configuration
        clientId: my-client-id
        defaultRole: member
        roleClaim: groups              # optional claim -> role mapping
        roleMap: { staff: reviewer }   # unmapped IdP groups grant NOTHING
        # clientSecretEnv: MY_SECRET   # default: OIDC_COLLEGE_CLIENT_SECRET
```

Link to **`GET /_auth/oidc/college`** (optionally `?to=/path`). The platform
runs the full authorization-code flow (state/nonce CSRF, JWKS-verified
id_token) and JIT-creates the account on first login. The client secret
lives in the app's **encrypted environment** (Environment tab / CLI), never
the manifest.

## Sign in with Informer

Link to **`GET /_auth/informer`** (optionally `?to=/path`). Ambient — no
manifest opt-in. It bounces through the Informer origin: a live Informer
session returns immediately with the user's identity and share-resolved
roles; otherwise Informer's login runs first. The user arrives with
`issuer: 'informer'` plus the legacy `username`/`displayName` fields.

## Federation — accept other apps' users

```yaml
accounts:
  accept:
    'app:*':                  # any app in this tenant may send its users
      defaultRole: collaborator
```

Default DENY without this. A caller app's account-viewer `fetch()` to your
routes arrives as `issuer: 'app:<callerAppId>'` with
`claims.viaApp/viaIssuer/viaSubject` for attribution. Federated principals
can call your routes only — never platform APIs — and you can disable one
person in your Users tab independently of the caller app.

## Roles

`request.roles` = the issuer's `defaultRole` (+ OIDC `roleMap` matches)
**plus** grants made in the app console's **Users tab** (each grant is an
ordinary share row on the account's principal). Gate a route with:

```js
export const config = { roles: ['vip'] };   // platform 403s before dispatch
```

Informer viewers' roles come from Sharing (shares/teams), so the Users tab
refuses edits on `informer`-issuer rows — manage those under Sharing.

## Hard limits to design around

- Account (`local`/`oidc`/`app:*`) sessions can NEVER call `access.apis`
  platform APIs — there is no Informer user to proxy as. Your own routes
  (running owner-backed) are their entire API surface.
- `/_auth` and public serving are origin-mode only.
- POSTs to `/_auth/*` are CSRF-gated by the Origin header — same-origin
  `fetch` from your own pages passes automatically; naked server-to-server
  calls are rejected by design (use webhooks for machines).
