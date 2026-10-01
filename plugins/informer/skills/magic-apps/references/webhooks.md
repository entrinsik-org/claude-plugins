# Webhooks (Token-Gated External Endpoints)

> **Load this reference when:** receiving callbacks from external services (Stripe, GitHub, Shopify, Slack, Gmail push, etc.) — anything that doesn't come with an Informer user session. Covers the `webhooks/` directory, the signed `?token=` URL gate, HMAC body-signature verification with `crypto.verifyHmac()`, and how webhooks differ from `server/` routes (inbound identity only).
>
> **Not in this file:** authenticated app-internal routes — see `server-routes.md`. Agents triggered by webhooks via `emit()` — see `agents.md`. Pushing a webhook's result live to open pages via `broadcast()` — see `channels.md`.
>
> **Availability:** `webhooks/` routes on every App-capable release. The URL's token is a **revocable webhook token** since **2026.1.0** (I5-12605): minted with `POST /api/apps/{id}/webhook-tokens`, never issued at deploy and never returned by `GET /api/apps/{id}/webhooks` (that endpoint lists routes and invocation stats only). Pre-release builds before I5-12605 returned each route's URL from `GET /webhooks` with a never-expiring token built in; those tokens do not verify on any released server.

Apps can expose **webhook endpoints** that receive requests from external services (Gmail push notifications, Slack commands, Stripe events, etc.) without requiring a logged-in Informer user. Each webhook URL embeds a signed `token` query parameter that the handler verifies — the endpoint is unguessable and tamper-proof, not anonymous. Webhook handlers run as the app owner and receive the **same handler bag as server routes** — including `query()`, `transaction()`, `fetch()`, `emit()`, `broadcast()`, `notify()`, `email()`, `crypto`, and the typed `context`. The only differences are inbound identity (no user session — see the table below).

## How It Works

1. Create a `webhooks/` directory in your project root
2. Add `.js` handler files using the same file-convention routing as `server/`
3. Run `npm run deploy` — Informer scans, bundles, and registers webhook routes as public
4. Mint a webhook token (see [Getting a Webhook URL](#getting-a-webhook-url)) and give the external service `/api/apps/{naturalId}/_hook/{path}?token=<key>`

## File-Convention Routing

File paths under `webhooks/` map to URL routes, same pattern as `server/`:

| File | Route | Public URL |
|------|-------|------------|
| `webhooks/gmail/push.js` | `/gmail/push` | `/api/apps/{id}/_hook/gmail/push` |
| `webhooks/stripe/payment.js` | `/stripe/payment` | `/api/apps/{id}/_hook/stripe/payment` |
| `webhooks/slack/commands.js` | `/slack/commands` | `/api/apps/{id}/_hook/slack/commands` |

## Handler Structure

Webhook handlers use the same export pattern as server routes. The handler context includes `crypto` for HMAC verification and `request.rawBody` for the original request bytes:

```javascript
// webhooks/gmail/push.js

export const config = { timeout: 15000 };

export async function POST({ query, request, fetch, emit, log, crypto, env }) {
    // request.body — parsed JSON payload
    // request.rawBody — original body string (for HMAC verification)
    // request.headers — incoming headers with `cookie` and `proxy-authorization` stripped;
    //                   `authorization` and signature headers (x-hub-signature-*, stripe-signature, etc.) are preserved
    // request.query — incoming query params with the URL-gate `token` and `app_token` stripped
    // crypto — hmac/verifyHmac/hash/randomUUID/encrypt/decrypt/verify (see server-routes.md)
    // env — app environment variables (secrets, config)

    const payload = request.body;

    // Process the webhook
    await query('INSERT INTO webhook_log (source, payload) VALUES ($1, $2)',
        ['gmail', JSON.stringify(payload)]);

    // Trigger an agent via event
    await emit('gmail_notification', { historyId: payload.historyId });

    return { status: 200, body: { ok: true } };
}
```

## Key Differences from Server Routes

| | Server Routes (`server/`) | Webhook Routes (`webhooks/`) |
|---|---|---|
| **URL prefix** | `/api/{path}` from app code (externally `/api/apps/{id}/view/api/…`) | `/api/apps/{id}/_hook/` |
| **Authentication** | Session or app-token (viewer's identity) | Signed `?token=…` query parameter (tenant-scoped, no user session) |
| **`request.user`** | Current viewer's identity | `null` |
| **`request.roles`** | Viewer's assigned roles | `[]` |
| **`fetch()` runs as** | The viewer | The app owner (team admin) |
| **`notify()` / `email()`** | Available | Available (run as the app owner) |
| **Use case** | App-internal CRUD, user-specific logic | External service callbacks |

External callers must include a webhook token in the URL — the handler runs only if the token verifies against the app's webhook secret **and** its token row still exists. See below for how to get one.

## Getting a Webhook URL

A webhook URL is the route's `_hook` path plus a **webhook token**: a JWT signed with the app's webhook secret and backed by a persisted row, so each one can be revoked on its own. Nothing issues one automatically — not deploy, not `GET /api/apps/{id}/webhooks`. Someone with write access to the App mints it:

| Method | Endpoint | Purpose |
|--------|----------|---------|
| `POST` | `/api/apps/{id}/webhook-tokens` | Mint a token. Optional body `{ "notes": "<label>" }` — name it after the service that will call it. The signed JWT is the response's **`key`** field. |
| `GET` | `/api/apps/{id}/webhook-tokens` | List the app's tokens (embedded under `_embedded["inf:token"]`, newest first), each with its current `key`. |
| `DELETE` | `/api/apps/{id}/webhook-tokens/{tokenId}` | Revoke one token. URLs carrying it then fail with `401 Webhook token revoked`; other tokens keep working. |
| `POST` | `/api/apps/{id}/_rotate-webhook-secret` | Re-sign everything at once: token rows survive but every `key` changes, so **every URL already handed out stops working**. Use for a leak you can't scope; to cut off one service, revoke its token instead. |

```bash
# Mint a token for one service, then build its URL
KEY=$(curl -s -u admin:pass -X POST -H 'content-type: application/json' \
  -d '{"notes":"Stripe"}' "$INFORMER_URL/api/apps/admin:my-app/webhook-tokens" | jq -r .key)
echo "$INFORMER_URL/api/apps/admin:my-app/_hook/stripe/payment?token=$KEY"
```

- `{id}` in the hook URL is the App's naturalId (`owner:slug`) or its UUID. On a server with per-app origins, the same route is also served at `https://<app-origin>/hooks/<path>?token=<key>`.
- The host must be one the external service can reach. A local dev server needs a public tunnel; the HAL `_links` on any API response show the base URL the server believes is public.
- **One token per external service**, labeled with `notes`. Revoking it cuts off exactly that service.
- The token only proves the caller has the URL. Still verify the provider's own body signature (next section).

**Debugging a rejected call** — the server answers before your handler runs:

| Response | Cause |
|---|---|
| `401 Webhook token required` | No `?token=` on the URL (a bare `_hook` path is always rejected). |
| `401 Invalid webhook token` | Wrong app, a mangled token, or a token signed before the secret was rotated. |
| `401 Webhook token revoked` | The token's row was deleted. |
| `404 Webhook route not found` | No deployed `webhooks/` route matches that method + path. |

A `401` with your **own** error body (for example `{"error":"Invalid signature"}`) means the token passed and your handler rejected the request — check the provider's signing secret in `env`.

## Sandbox Capabilities

Webhook handlers receive the **same bag as server routes** (see `server-routes.md` for full details on each). `notify()` and `email()` **are** available — webhook handlers run as the app owner, so message attribution is well-defined.

| Callback | Description |
|----------|-------------|
| `query(sql, params?)` | Execute SQL against the app's workspace |
| `fetch(path, options?)` | Make authenticated API calls (runs as app owner) |
| `context.<slot>.<method>()` | Typed bound dependencies (see `informer-yaml.md`) |
| `emit(event, payload?)` | Fire app events (trigger agents) |
| `broadcast(channel, event, payload?, options?)` | Push a fire-and-forget frame to every open page subscribed to `channel` — the natural way to tell dashboards a webhook landed (origin-mode servers only). Resolves `{ ok: true, seq }`; pass `{ replay: false }` for frames not worth replaying to a reconnecting page. See `channels.md`. |
| `notify(user, message)` / `email(to, message)` | Enqueue a push notification / email |
| `respond(response)` | Send early response while handler continues in background. Same shape as handler return: plain value (wrapped as 200 JSON), `{ status, body }`, or `{ status, headers, body, encoding: 'base64' }` for binary. **2026.1.4+** the work after it is billed, capped by `app.routes.maxBackgroundPerApp`, and logged to the Logs tab when it fails — see `server-routes.md`. |
| `crypto` | `hmac`, `hash`, `randomUUID`, `randomBytes`, `timingSafeEqual`, `verifyHmac`, `encrypt`/`decrypt` (AES-256-GCM), `verify` — all async. Use `verifyHmac` for signature checks. See `server-routes.md`. |
| `markdown(text)` | Convert markdown text to HTML (async). Uses `marked`. |
| `extractText(data, contentType)` | Extract plain text from a base64 file (PDF, Excel, Word, text/*), async. Throws on unsupported types. See `server-routes.md`. |
| `log(message, data?)` | Structured logging. Also `log.info()`/`log.warn()`/`log.error()`/`log.debug()`. Writes to `app_log`. See "Using `log()`" in `server-routes.md`. |
| `base64Decode(encoded)` *(global — call by name, not on the handler argument)* | Decode base64 to UTF-8 string (async). Handles multi-byte characters correctly. |
| `base64Encode(string)` *(global — call by name, not on the handler argument)* | Encode UTF-8 string to base64 (async). |
| `base64UrlDecode(encoded)` *(global — call by name, not on the handler argument)* | Decode base64url to UTF-8 string (async). Ideal for Gmail API payloads. |
| `base64UrlEncode(string)` *(global — call by name, not on the handler argument)* | Encode UTF-8 string to base64url (async). |
| `env` | App environment variables — decrypted values from the app's Environment (set in the **Admin → Environment** tab, or declared as keys in `informer.yaml` `env:`). Encrypted at rest; never returned by any API. |

Webhook routes also provide `request.rawBody` — the original request body as a string, preserving the exact bytes sent by the caller. Use this for HMAC signature verification (not `request.body`, which is parsed JSON).

## Sanitized Request Inputs

Webhook handlers receive `request.headers` and `request.query` with Informer's auth-bearing values removed before the handler runs. The deny-lists are narrower than for server routes because webhook contracts genuinely depend on incoming headers (signatures, shared-secret Bearer tokens).

**`request.headers` — stripped:**
- `cookie` — a misrouted browser request could carry the visitor's app-token cookie; webhooks have no business reading it
- `proxy-authorization` — never part of a documented webhook contract

**`request.headers` — preserved:**
- `authorization` — kept so shared-secret patterns like `Authorization: Bearer <secret>` work
- All signature headers (`x-hub-signature-256`, `stripe-signature`, `x-shopify-hmac-sha256`, etc.)
- Service-specific event headers (`x-github-event`, `user-agent`, etc.)

**`request.query` — stripped:**
- `token` — the URL-gate signed token consumed by the webhook proxy; the handler doesn't need it (verification already happened)
- `app_token` — defense in depth; never expected on a webhook URL, but stripped in case a misrouted request carries it

Your own custom query parameters pass through untouched. If your handler reads `request.query.id` or similar, nothing changes.

## Imports

Webhook files are bundled by the same esbuild plugin as server routes — imports resolve only against the app's library, no `node_modules`, no host filesystem. See the [Imports](server-routes.md#imports) section in `server-routes.md` for the full allow/deny list and error messages. Shared helpers across `server/`, `webhooks/`, and `tools/` are supported via relative paths (e.g. `import { verifySig } from '../lib/sig.js'`).

## Webhook Verification

The signed `token` query parameter proves the URL came from Informer (i.e. the *caller knows the URL*), but not that the URL was used by the right service. For end-to-end authenticity, **also verify the upstream's signature on the request body** — most webhook providers (GitHub, Stripe, Shopify, Slack) sign with HMAC-SHA256. The sandbox provides `crypto.verifyHmac()` (constant-time) and `env` for storing secrets.

**HMAC signature verification** (GitHub, Stripe, Shopify) — use `crypto.verifyHmac()`, which computes the digest and compares in constant time (avoid a plain `===`/`!==`, which leaks timing):

```javascript
// webhooks/github.js
export async function POST({ crypto, query, request, env }) {
    // GitHub sends `x-hub-signature-256: sha256=<hex>`
    const signature = (request.headers['x-hub-signature-256'] || '').replace(/^sha256=/, '');
    if (!signature) return { status: 401, body: { error: 'Missing signature' } };

    // verifyHmac computes the HMAC over the raw body bytes and constant-time-compares
    const ok = await crypto.verifyHmac('sha256', env.GITHUB_WEBHOOK_SECRET, request.rawBody, signature);
    if (!ok) {
        return { status: 401, body: { error: 'Invalid signature' } };
    }

    // Signature valid — process the event
    const event = request.body;
    await query('INSERT INTO webhook_log (source, event, payload) VALUES ($1, $2, $3)',
        ['github', request.headers['x-github-event'], JSON.stringify(event)]);

    return { ok: true };
}
```

**Shared secret** (custom integrations) — compare with `crypto.timingSafeEqual()` rather than `!==`:

```javascript
// webhooks/my-callback.js
export async function POST({ crypto, request, env }) {
    const presented = request.headers['x-webhook-secret'] || '';
    if (!(await crypto.timingSafeEqual(presented, env.CALLBACK_SECRET))) {
        return { status: 401, body: { error: 'Unauthorized' } };
    }

    // Secret matches — process the payload
    return { received: true };
}
```

**Setting environment variables:** Open the app's **Admin → Environment** tab and add `GITHUB_WEBHOOK_SECRET` (and any other keys your handler reads). Values are encrypted at rest and injected into the handler's `env` bag — they're never echoed back to the UI after you save.

If you want the key to appear pre-listed (as "Not set") for the installer rather than expecting them to remember its name, declare it in `informer.yaml`:

```yaml
env:
  GITHUB_WEBHOOK_SECRET:
    description: HMAC secret GitHub signs webhook payloads with
```

On deploy, that seeds an unset placeholder row — the installer fills the value per tenant. See `informer-yaml.md` for the full `env:` schema. (The old `PUT /api/apps/{id}` with `defn.env` workflow is gone — that path leaked secrets in plaintext through GET responses.)

## Project Structure with Webhooks

```
my-app/
  webhooks/
    gmail/
      push.js               → POST /gmail/push
    stripe/
      payment.js            → POST /stripe/payment
    slack/
      commands.js            → POST /slack/commands
  server/
    orders/
      index.js              → GET,POST /orders (authenticated)
  tools/
    send_email.js
  migrations/
    001-create-tables.sql
  informer.yaml
  index.html
  package.json
```
