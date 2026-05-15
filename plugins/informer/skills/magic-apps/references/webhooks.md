# Webhooks (Token-Gated External Endpoints)

> **Load this reference when:** receiving callbacks from external services (Stripe, GitHub, Shopify, Slack, Gmail push, etc.) — anything that doesn't come with an Informer user session. Covers the `webhooks/` directory, the signed `?token=` URL gate, HMAC body-signature verification with `crypto.hmac()`, and the capability subset compared to `server/` routes.
>
> **Not in this file:** authenticated app-internal routes — see `server-routes.md`. Agents triggered by webhooks via `emit()` — see `agents.md`.

Apps can expose **webhook endpoints** that receive requests from external services (Gmail push notifications, Slack commands, Stripe events, etc.) without requiring a logged-in Informer user. Each webhook URL embeds a signed `token` query parameter that the handler verifies — the endpoint is unguessable and tamper-proof, not anonymous. Webhook handlers run as the app owner and have access to `query()`, `fetch()`, and `emit()`. **`notify()` and `email()` are NOT available in webhook handlers** — only in server routes and agent tools.

## How It Works

1. Create a `webhooks/` directory in your project root
2. Add `.js` handler files using the same file-convention routing as `server/`
3. Run `npm run deploy` — Informer scans, bundles, and registers webhook routes as public
4. External services POST to `/api/apps/{naturalId}/_hook/{path}`

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
    // crypto.hmac() — compute HMAC digests
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
| **URL prefix** | `/api/apps/{id}/view/api/_server/` | `/api/apps/{id}/_hook/` |
| **Authentication** | Session or app-token (viewer's identity) | Signed `?token=…` query parameter (tenant-scoped, no user session) |
| **`request.user`** | Current viewer's identity | `null` |
| **`request.roles`** | Viewer's assigned roles | `[]` |
| **`fetch()` runs as** | The viewer | The app owner (team admin) |
| **`notify()` / `email()`** | Available | **Not available** |
| **Use case** | App-internal CRUD, user-specific logic | External service callbacks |

The signed `token` is issued at deploy time via `GET /api/apps/{id}/webhooks`. External callers must include the token in the URL — the handler runs only if the token verifies against the app's webhook secret.

## Sandbox Capabilities

Webhook handlers have a subset of server-route capabilities. `notify()` and `email()` are **not** wired into the webhook dispatcher — calling either throws `TypeError: notify is not a function`.

| Callback | Description |
|----------|-------------|
| `query(sql, params?)` | Execute SQL against the app's workspace |
| `fetch(path, options?)` | Make authenticated API calls (runs as app owner) |
| `emit(event, payload?)` | Fire app events (trigger agents) |
| `respond(response)` | Send early response while handler continues in background. Same shape as handler return: plain value (wrapped as 200 JSON), `{ status, body }`, or `{ status, headers, body, encoding: 'base64' }` for binary. |
| `crypto.hmac(algorithm, key, data, encoding?)` | Compute HMAC digest (delegates to Node.js `crypto` on the host). Default encoding: `'hex'`. |
| `markdown(text)` | Convert markdown text to HTML (async). Uses `marked`. |
| `log(message, data?)` | Structured logging. Also `log.info()`/`log.warn()`/`log.error()`/`log.debug()`. Writes to `app_log`. See "Using `log()`" in `server-routes.md`. |
| `base64Decode(encoded)` | Decode base64 to UTF-8 string (async). Handles multi-byte characters correctly. |
| `base64Encode(string)` | Encode UTF-8 string to base64 (async). |
| `base64UrlDecode(encoded)` | Decode base64url to UTF-8 string (async). Ideal for Gmail API payloads. |
| `base64UrlEncode(string)` | Encode UTF-8 string to base64url (async). |
| `env` | App environment variables from `app.defn.env` |

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

The signed `token` query parameter proves the URL came from Informer (i.e. the *caller knows the URL*), but not that the URL was used by the right service. For end-to-end authenticity, **also verify the upstream's signature on the request body** — most webhook providers (GitHub, Stripe, Shopify, Slack) sign with HMAC-SHA256. The sandbox provides `crypto.hmac()` and `env` for storing secrets.

**HMAC signature verification** (GitHub, Stripe, Shopify):

```javascript
// webhooks/github.js
export async function POST({ crypto, request, env }) {
    const signature = request.headers['x-hub-signature-256'];
    if (!signature) return { status: 401, body: { error: 'Missing signature' } };

    // Compute HMAC over the raw body bytes (not parsed JSON)
    const expected = await crypto.hmac('sha256', env.GITHUB_WEBHOOK_SECRET, request.rawBody);
    if (signature !== `sha256=${expected}`) {
        return { status: 401, body: { error: 'Invalid signature' } };
    }

    // Signature valid — process the event
    const event = request.body;
    await query('INSERT INTO webhook_log (source, event, payload) VALUES ($1, $2, $3)',
        ['github', request.headers['x-github-event'], JSON.stringify(event)]);

    return { ok: true };
}
```

**Shared secret** (custom integrations):

```javascript
// webhooks/my-callback.js
export async function POST({ request, env }) {
    if (request.headers['x-webhook-secret'] !== env.CALLBACK_SECRET) {
        return { status: 401, body: { error: 'Unauthorized' } };
    }

    // Secret matches — process the payload
    return { received: true };
}
```

**Setting environment variables:** Store secrets in `app.defn.env` via the app update endpoint:

```javascript
await fetch(`/api/apps/${appId}`, {
    method: 'PUT',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        defn: { env: { GITHUB_WEBHOOK_SECRET: 'your-secret-here' } }
    })
});
```

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
