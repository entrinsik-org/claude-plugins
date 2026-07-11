# Server-Side Routes

> **Load this reference when:** writing handler files under `server/`, working with the V8 sandbox helpers (`query`, `fetch`, `respond`, `notify`, `email`, `log`, `crypto`, the base64/markdown/extractText globals), configuring per-handler `timeout` or `roles`, or wiring frontend calls to `/api/_server/...`.
>
> **Not in this file:** public token-gated webhook endpoints — see `webhooks.md`. Agent tool handlers — see `agents.md` (they share the same sandbox, so this file is the authoritative sandbox reference). The typed dep proxy (`context.<slot>.<method>()`) — see SKILL.md "Accessing Your Dependencies".

Apps can include **server-side JavaScript handlers** that run on the Informer server in sandboxed V8 isolates. These handlers have direct access to the app's Postgres workspace and can make authenticated API calls — ideal for business logic, data transformations, webhooks, or anything that shouldn't run in the browser.

## How It Works

1. Create a `server/` directory in your project root
2. Add `.js` handler files using file-convention routing (like Next.js)
3. Run `npm run deploy` — Informer scans, bundles, and registers routes automatically
4. Your app calls server routes via `fetch('/api/_server/...')`

Handler code runs in an **isolated-vm V8 isolate** — a separate V8 heap with no access to Node.js APIs, the filesystem, or the network. All I/O goes through injected callbacks (`query` and `fetch`).

## File-Convention Routing

File paths under `server/` map to URL routes:

| File | Route | Example URL |
|------|-------|-------------|
| `server/index.js` | `/` | `/api/_server/` |
| `server/orders/index.js` | `/orders` | `/api/_server/orders` |
| `server/orders/[id].js` | `/orders/:id` | `/api/_server/orders/abc123` |
| `server/orders/[id]/approve.js` | `/orders/:id/approve` | `/api/_server/orders/abc123/approve` |

- `[param]` segments become dynamic route parameters (available as `request.params.param`)
- `index.js` files map to the parent directory path

## Handler Structure

Each handler file exports **named functions** for each HTTP method it supports:

```javascript
// server/orders/index.js

export async function GET({ query, request }) {
    const rows = await query('SELECT * FROM orders ORDER BY created_at DESC LIMIT 50');
    return rows;
}

export async function POST({ query, request }) {
    const { customer, total } = request.body;
    const rows = await query(
        'INSERT INTO orders (customer, total) VALUES ($1, $2) RETURNING *',
        [customer, total]
    );
    return { status: 201, body: rows[0] };
}
```

**Supported methods:** `GET`, `POST`, `PUT`, `PATCH`, `DELETE`

Each handler function receives a single context object with these properties:

| Property | Type | Description |
|----------|------|-------------|
| `query` | `async (sql, params?) => rows` | Execute SQL against the app's workspace. Returns an array of row objects. |
| `fetch` | `async (path, options?) => { status, body }` | Make an authenticated API call through Informer (subject to the app's whitelist). |
| `context` | `object` | Typed dep proxies keyed by slot name. Call deps as `context.<slotName>.<method>(args)`. Methods per `target`: `dataset` → `search(esQuery)` / `fields()`; `query` → `execute(params)`; `datasource` → `query(payload)`; `integration` → `request(opts)`. Throws boom 422 with `errorCode: 'dependency_unbound'` if the installer hasn't bound the slot yet, or `'dependency_broken'` if the bound target was deleted. Prefer this over raw `fetch()` — slots survive bundle export/import and resource renames; raw paths don't. |
| `respond` | `async (response) => void` | Send an early HTTP response while the handler continues running in the background. Accepts the same shape as a synchronous return — a response object (`{ status, headers?, body?, encoding? }`) or any plain value (wrapped as 200 JSON). See [Using `respond()`](#using-respond). |
| `emit` | `async (event, payload) => void` | Emit an app event to trigger agents. Creates an `AppEvent` record and notifies the event dispatcher. |
| `notify` | `async (username, message) => { id }` | Enqueue a push notification for delivery to a user's Informer GO devices. See [Using `notify()`](#using-notify). |
| `email` | `async (to, message) => { id }` | Enqueue an email for delivery via the tenant's mail transport. See [Using `email()`](#using-email). |
| `crypto` | `object` | Cryptographic helpers (all async): `hmac`, `hash`, `randomUUID`, `randomBytes`, `timingSafeEqual`, `verifyHmac`, `encrypt`/`decrypt` (AES-256-GCM), `verify`. See [Using `crypto`](#using-crypto). |
| `log` | `function` | Structured logging. `log(message, data?)` or `log.info()`/`log.warn()`/`log.error()`/`log.debug()`. Writes to `app_log`. See [Using `log()`](#using-log). |
| `env` | `object` | App environment variables — decrypted values from the app's Environment. Set in **Admin → Environment**; declared keys in `informer.yaml` `env:` arrive as unset placeholders for the installer to fill per tenant. Encrypted at rest; never returned by any API. |
| `request` | `object` | The incoming request (see below). |

**Sandbox globals (available without destructuring):**

The following are available as **globals** inside the V8 isolate — not as keys on the handler argument. Don't destructure them from the handler arg (it'll bind to `undefined`); just call them.

| Global | Type | Description |
|--------|------|-------------|
| `markdown` | `async (text) => string` | Convert markdown text to HTML using `marked`. |
| `extractText` | `async (data, contentType) => string` | Extract plain text from a base64 file (PDF, Excel, Word, text). Throws on unsupported types (e.g. images). See [Using `extractText()`](#using-extracttext). |
| `base64Decode` | `async (encoded) => string` | Decode base64 to UTF-8 text (handles multi-byte; safer than `atob`). |
| `base64Encode` | `async (string) => string` | Encode UTF-8 string to base64. |
| `base64UrlDecode` | `async (encoded) => string` | Decode base64url to UTF-8 (Gmail API payloads, JWT segments). |
| `base64UrlEncode` | `async (string) => string` | Encode UTF-8 string to base64url. |
| `atob` / `btoa` | `(string) => string` | Standard Web APIs. Use `base64*` variants above for non-ASCII. |

**`request` object:**

| Property | Type | Description |
|----------|------|-------------|
| `request.method` | `string` | HTTP method (`GET`, `POST`, etc.) |
| `request.path` | `string` | Matched route path (e.g. `/orders/:id`) |
| `request.params` | `object` | Route parameters (e.g. `{ id: 'abc123' }`) |
| `request.query` | `object` | Query string parameters |
| `request.body` | `any` | Request body (parsed JSON for POST/PUT/PATCH) |
| `request.rawBody` | `string\|null` | Raw request body string (for HMAC signature verification). Only available on webhook routes. |
| `request.headers` | `object` | Request headers |
| `request.roles` | `string[]` | The viewer's assigned role IDs (see App Roles in SKILL.md) |
| `request.user` | `object` | Current user identity (see below) |

**`request.user` object:**

| Property | Type | Description |
|----------|------|-------------|
| `request.user.username` | `string` | Login username |
| `request.user.displayName` | `string` | User's display name |
| `request.user.email` | `string\|null` | Email address |
| `request.user.timezone` | `string\|null` | Timezone (e.g. `America/New_York`) |

## Sanitized Request Inputs

`request.headers` is always `{}` for server routes — use `request.user` / `request.roles` for identity. `request.query` has Informer's `app_token` stripped before the handler runs (your own params pass through untouched).

Webhook handlers use a narrower deny-list (signature headers and Bearer tokens are preserved for verification) — see [Sanitized Request Inputs](webhooks.md#sanitized-request-inputs) in `webhooks.md`.

## Calling Typed Dep Slots

The handler's `context` object carries one property per `dependencies:` slot, with methods that proxy to the bound target. See "Accessing Your Dependencies" in SKILL.md — that's the canonical reference, with worked examples for all five target types (`dataset` / `query` / `datasource` / `integration` / `app`), the `dependency_unbound` / `dependency_broken` error pattern, and the rules for the frontend equivalents.

The short version: in a handler, write `context.<slotName>.<method>(args)` — never raw `fetch('/api/datasets/<uuid>/...')`. Slots survive bundle export/import and resource renames; raw paths don't.

## Return Values

Handlers can return values in several formats — pick the one that matches the response you want to send:

**Simple value** — automatically wrapped as a 200 JSON response:
```javascript
export async function GET({ query }) {
    const rows = await query('SELECT * FROM orders');
    return rows; // → 200, Content-Type: application/json
}
```

**Response object** — full control over status, headers, and body:
```javascript
export async function POST({ query, request }) {
    const { customer } = request.body;
    if (!customer) {
        return { status: 400, body: { error: 'Customer is required' } };
    }

    const rows = await query(
        'INSERT INTO orders (customer) VALUES ($1) RETURNING *',
        [customer]
    );
    return { status: 201, body: rows[0] };
}
```

> **How a return value becomes a response — and relaying dependency data.** The runtime reads your return as a full response descriptor (`{ status, headers?, body?, encoding? }`) **only when `typeof result.status === 'number'`**; any other value — including an object whose `status` is a string — is wrapped as a `200` JSON response with itself as the body. Two things follow when a handler relays data from a dependency. First, `context.<slot>.request(...)` already returns the **parsed upstream body** — a JSON response is the object or array itself, not a `{ status, body }` wrapper (a non-2xx throws; a binary 2xx returns a base64 envelope) — so return it directly; there is no envelope to peel off with `res.body` / `res.data`. Second, if a relayed record owns a **numeric** `status` field of its own, wrap it so it is sent as data rather than read as a descriptor: `return { status: 200, body: record }`.

**No return value** — returns 204 No Content:
```javascript
export async function DELETE({ query, request }) {
    await query('DELETE FROM orders WHERE id = $1', [request.params.id]);
    // implicit 204
}
```

**Text response (non-JSON)** — when `body` is a string with no `encoding` field, the runtime sends it as-is. Use this for CSV, HTML, SVG, plain text — anything you can produce as a UTF-8 string:
```javascript
export async function GET({ query }) {
    const rows = await query('SELECT id, customer, total FROM orders');
    const csv = ['id,customer,total', ...rows.map(r => `${r.id},${r.customer},${r.total}`)].join('\n');
    return {
        status: 200,
        headers: {
            'content-type': 'text/csv',
            'content-disposition': 'attachment; filename="orders.csv"'
        },
        body: csv
    };
}
```

**Binary response** — set `encoding: 'base64'` to send raw bytes (images, PDFs, file downloads). The body is decoded from base64 before being written to the HTTP response, and the `content-type` you set on `headers` is sent as-is:
```javascript
export async function GET({ query, request }) {
    const [row] = await query(
        `SELECT encode(data, 'base64') AS data, mime_type, name
         FROM attachments WHERE id = $1`,
        [request.params.id]
    );
    if (!row) return { status: 404, body: { error: 'Not found' } };
    return {
        status: 200,
        headers: {
            'content-type': row.mime_type,
            'content-disposition': `inline; filename="${row.name}"`
        },
        body: row.data,
        encoding: 'base64'
    };
}
```

This is the recommended pattern for serving file attachments stored as `bytea` in the workspace — Postgres' `encode(col, 'base64')` does the heavy lifting in SQL, so the handler just passes the string through. For `inline` disposition the browser will render the file directly (images, PDFs); use `attachment` to force a download.

If your source is base64url instead of standard base64 (Gmail API attachments, JWT segments), normalize first: `await base64Encode(await base64UrlDecode(input))`. The runtime validates against the standard alphabet and rejects the `-` / `_` characters that base64url uses.

| Response field | Type | Notes |
|----------------|------|-------|
| `status` | `number` | HTTP status code |
| `headers` | `object` | Response headers. `content-type` is forwarded verbatim; defaults to `application/json` if unset |
| `body` | `any` | Object/array → JSON-stringified. String → sent as-is. With `encoding: 'base64'` → decoded to bytes |
| `encoding` | `'base64'` | Optional. When set, `body` must be a base64-encoded string and is written as raw bytes |

## Using `query()`

The `query` callback executes SQL against the app's Postgres workspace — the same schema managed by `migrations/`. It takes a SQL string and an optional params array, and returns the result rows directly.

```javascript
export async function GET({ query, request }) {
    // Parameterized query (always use $1, $2, etc.)
    const orders = await query(
        'SELECT * FROM orders WHERE status = $1 ORDER BY created_at DESC',
        [request.query.status || 'pending']
    );

    // Aggregation
    const [stats] = await query(`
        SELECT COUNT(*) as count, SUM(total) as revenue
        FROM orders WHERE status = 'completed'
    `);

    return { orders, stats };
}
```

All `query()` calls within a single request share the same database connection, which is automatically closed when the handler completes.

## Using `fetch()`

The `fetch` callback makes authenticated API calls through Informer, using the viewer's credentials. It goes through the same whitelist as client-side API calls, so the endpoint must be allowed in `informer.yaml`.

```javascript
export async function GET({ fetch }) {
    // Fetch data from a dataset
    const result = await fetch('datasets/admin:sales-data/_search', {
        method: 'POST',
        body: { query: { match_all: {} }, size: 100 }
    });

    return result.body.hits.hits.map(h => h._source);
}

export async function POST({ fetch, request }) {
    // Call an integration
    const result = await fetch('integrations/salesforce/request', {
        method: 'POST',
        body: {
            url: '/data/v59.0/sobjects/Contact',
            method: 'POST',
            data: request.body
        }
    });

    return { status: result.status, body: result.body };
}
```

The `path` argument is relative to `/api/` — pass `'datasets/admin:sales-data/_search'`, not `'/api/datasets/...'`.

### Common pitfalls

The sandboxed `fetch` and `request` behave differently from their browser counterparts. The four mistakes below come up often because muscle memory from browser code doesn't transfer.

**1. `fetch()` returns `{ status, body }`, not a Web `Response`.** No `.ok`, no `.json()`, no `.text()`, no `.headers` getter.

```javascript
// WRONG — Web Response methods don't exist server-side
const response = await fetch('datasets/admin:sales/_search', { method: 'POST', body: { query: { match_all: {} } } });
if (!response.ok) throw new Error('Failed');     // ❌ .ok is undefined
const data = await response.json();              // ❌ .json is not a function

// CORRECT — destructure or read fields directly
const result = await fetch('datasets/admin:sales/_search', { method: 'POST', body: { query: { match_all: {} } } });
if (result.status !== 200) return { status: result.status, body: { error: 'Search failed' } };
const hits = result.body.hits.hits.map(h => h._source);
```

**2. Pass `body` as a plain object — never `JSON.stringify` it, never set `Content-Type`.** The runtime handles both.

```javascript
// WRONG — double-serializes into a JSON string literal
body: JSON.stringify({ query: { match_all: {} } })

// CORRECT
body: { query: { match_all: {} } }
```

**3. Don't `new URL(request.url)`.** The sandbox doesn't ship a full origin/host on `request.url`. The fields you'd extract are already parsed:

```javascript
// WRONG — request.url may not be a fully-qualified URL; URL() can throw
const url = new URL(request.url);
const status = url.searchParams.get('status');

// CORRECT — use the pre-parsed objects
const status = request.query.status;
const orderId = request.params.id;
```

**4. Plain-text upstream responses break the dev `apiFetch` body parser.** In dev mode, the Vite plugin's `apiFetch` reads the upstream body with `resp.json()` first and only falls back to `resp.text()` on failure — but `resp.json()` already consumes the stream, so the fallback throws "Body already read" and the call appears to fail silently. If you're proxying through an upstream that returns `text/plain`, parse it in the handler and return JSON, rather than passing the raw body through.

## Using `respond()`

The `respond` callback sends an early HTTP response to the caller while the handler keeps running in the background. This is useful when an external caller has a tight response deadline (e.g. Slack's 3-second limit for slash commands) but the handler needs more time to complete its work.

```javascript
// server/slack/commands.js

export const config = { timeout: 25000 };

export async function POST({ query, fetch, respond, request }) {
    const { text, response_url } = request.body;

    // Ack immediately — the HTTP response is sent now
    await respond({ response_type: 'ephemeral', text: 'Processing your request...' });

    // Everything below runs in the background (isolate stays alive)
    const result = await fetch('datasets/admin:sales-data/_search', {
        method: 'POST',
        body: { query: { match_all: {} }, size: 50 }
    });

    // Post the real answer back via response_url
    await fetch('integrations/slack/request', {
        method: 'POST',
        body: { url: response_url, method: 'POST', data: { text: `Found ${result.body.hits.total} records` } }
    });
}
```

**Key behavior:**

- Only the **first** `respond()` call takes effect — subsequent calls are ignored
- `respond()` accepts the same shapes as a synchronous return: a plain value (wrapped as 200 JSON), a response object (`{ status, body, headers? }`), or a binary response (`{ status, headers, body, encoding: 'base64' }`) — see [Return Values](#return-values) for the full shape table
- The isolate, database connection, and timeout all remain active until the handler fully returns (or times out)
- If background work throws an error after `respond()`, the error is logged server-side but does **not** affect the already-sent response
- If `respond()` is never called, the handler returns normally — `respond` is entirely opt-in

**When to use `respond()`:**

- Webhook receivers with tight deadlines (Slack, Stripe, GitHub)
- Fire-and-forget patterns where the caller only needs an acknowledgment
- Long-running operations where you want to ack first, then process asynchronously

**When NOT to use `respond()`:**

- Normal CRUD handlers — just return the result directly
- When the caller needs the actual result in the response body

## Using `log()`

The `log` callback writes structured log entries to the app's log table (`app_log`). Logs are visible in the **Logs tab** of the App Admin panel in Informer GO, and can be filtered by level, source, and agent.

```javascript
// server/orders/index.js

export async function POST({ query, log, request }) {
    const { customer, total } = request.body;

    log.info('Creating order', { customer, total });

    const [order] = await query(
        'INSERT INTO orders (customer, total) VALUES ($1, $2) RETURNING *',
        [customer, total]
    );

    log('Order created', { orderId: order.id });  // shorthand for log.info()
    return { status: 201, body: order };
}
```

**Log levels:**

| Method | Level | Use case |
|--------|-------|----------|
| `log(message, data?)` | `info` | Shorthand — logs at info level |
| `log.debug(message, data?)` | `debug` | Verbose diagnostic info |
| `log.info(message, data?)` | `info` | Normal operational events |
| `log.warn(message, data?)` | `warn` | Unexpected but recoverable situations |
| `log.error(message, data?)` | `error` | Failures that need attention |

**Parameters:**

- `message` — string describing the event. Non-string values are automatically JSON-stringified.
- `data` — optional object with structured metadata (stored as JSONB). Useful for filtering and debugging.

**Key behavior:**

- Logging is **fire-and-forget** — it never blocks or throws. If the log write fails, it's silently dropped.
- The `source` field is set automatically based on where the handler runs: `'server'` for server routes, `'webhook'` for webhook handlers, `'tool'` for agent tool handlers.
- Correlation fields are set automatically based on context: `invocationId` for server routes and webhooks; `agentId` and `runId` for agent tool handlers. You don't need to pass them.
- Available in **server routes**, **webhook handlers**, and **agent tool handlers**.

## Handler Config

Handlers can export a `config` object to customize behavior:

```javascript
// server/webhooks/stripe.js

export const config = {
    timeout: 60000,            // Wall-clock timeout in ms (default: 30000)
    roles: ['admin', 'manager'] // Restrict to specific roles (see App Roles)
};

export async function POST({ query, request }) {
    // Only users with 'admin' or 'manager' role can reach this handler
    const event = request.body;
    await query('INSERT INTO webhook_events (type, payload) VALUES ($1, $2)', [
        event.type,
        JSON.stringify(event)
    ]);
    return { status: 200, body: { received: true } };
}
```

| Config | Type | Default | Description |
|--------|------|---------|-------------|
| `timeout` | `number` | `30000` | Wall-clock timeout in ms. Handler is killed if it exceeds this. |
| `roles` | `string[]` | `[]` (open) | If set, only viewers with at least one matching role can call this route. Returns 403 otherwise. |

## Using `notify()`

Enqueue a push notification for delivery to a user's registered Informer GO devices. Messages are queued and delivered asynchronously via FCM. Returns immediately with the message ID. The app's ID is automatically attached — tapping the notification in GO opens this app.

```javascript
// Single notification
export async function POST({ notify, request }) {
    const { id } = await notify('jane', {
        title: 'Order Shipped',
        body: 'Your order #1234 has shipped!',
        path: '/orders/1234'     // optional deep link within this app
    });
    return { notificationId: id };
}
```

**Bulk notifications** — pass an array to send multiple in a single call:

```javascript
const { ids, queued } = await notify([
    { username: 'jane', title: 'Report Ready', body: 'Your Q1 report is ready' },
    { username: 'bob', title: 'Report Ready', body: 'Your Q1 report is ready' },
]);
```

**Parameters (single):**

| Parameter | Type | Description |
|-----------|------|-------------|
| `username` | string | Informer username to notify |
| `message.title` | string | **Required.** Notification title |
| `message.body` | string | Notification body text |
| `message.path` | string | Deep link path within the app (e.g. `/orders/123`) |
| `message.data` | object | Custom data (values coerced to strings for FCM) |

**Bulk:** Array of `{ username, title, body, path?, data? }` objects.

Messages are retried up to 3 times on failure, then moved to `dead` status. Message history is viewable via `GET /api/apps/{id}/messages`.

## Using `email()`

Enqueue an email for delivery via the tenant's configured mail transport (SMTP, Gmail API, Microsoft Graph). Returns immediately with the message ID.

```javascript
export async function POST({ email, request }) {
    const { id } = await email('jane@acme.com', {
        subject: 'Invoice #1234',
        html: '<h2>Invoice</h2><p>Amount due: <strong>$1,500</strong></p>'
    });
    return { emailId: id };
}
```

**Bulk emails:**

```javascript
const { ids, queued } = await email([
    { to: 'jane@acme.com', subject: 'Monthly Report', html: '<p>See attached</p>' },
    { to: 'bob@acme.com', subject: 'Monthly Report', html: '<p>See attached</p>', from: 'reports@acme.com' },
]);
```

**Parameters (single):**

| Parameter | Type | Description |
|-----------|------|-------------|
| `to` | string | **Required.** Recipient email address |
| `message.subject` | string | **Required.** Email subject line |
| `message.html` | string | HTML email body |
| `message.from` | string | Sender address (defaults to tenant's configured default) |

**Bulk:** Array of `{ to, subject, html, from? }` objects.

## Using `crypto`

Host-backed cryptographic helpers, available in server routes, webhooks, and agent tools alike. **Every method is async** — `await` them.

| Method | Description |
|--------|-------------|
| `crypto.hmac(algorithm, key, data, encoding?='hex')` | HMAC digest |
| `crypto.hash(algorithm, data, encoding?='hex')` | Plain digest (e.g. `sha256`) |
| `crypto.randomUUID()` | RFC 4122 v4 UUID |
| `crypto.randomBytes(length, encoding?='hex')` | Random bytes (length capped at 1024; lengths ≤ 0 are silently clamped to 1) |
| `crypto.timingSafeEqual(a, b)` | Constant-time compare; `false` on length mismatch. **Throws on `null`/`undefined` inputs** — guard missing headers with `\|\| ''`. Use instead of `===` for secrets/signatures. |
| `crypto.verifyHmac(algorithm, key, data, signature, encoding?='hex')` | Compute HMAC + constant-time compare → boolean. The safe way to verify webhook signatures. **Throws on a `null`/`undefined` signature** — guard a missing header with `\|\| ''`. |
| `crypto.verify(algorithm, data, signature, publicKey, signatureEncoding?='base64')` | Verify an asymmetric (RSA/ECDSA) signature against a PEM key → boolean |
| `crypto.encrypt(plaintext, key)` | AES-256-GCM → self-describing `iv:tag:ciphertext` (base64). `key` is any passphrase (hashed to 32 bytes). |
| `crypto.decrypt(payload, key)` | Reverses `encrypt`; throws on a malformed payload (not `iv:tag:ciphertext`), wrong key, or tampering |

```javascript
const sig = await crypto.hmac('sha256', secret, payload, 'hex');
const id = await crypto.randomUUID();
const ok = await crypto.verifyHmac('sha256', secret, request.rawBody, header);
const token = await crypto.encrypt(JSON.stringify({ userId: 7 }), env.APP_SECRET);
const { userId } = JSON.parse(await crypto.decrypt(token, env.APP_SECRET));
```

## Using `extractText()`

Extract plain text from a base64-encoded file on the host, using the platform's bundled parsers. The isolate has no npm, so this is the way to read a PDF or Office document into text. Async (it crosses the isolate boundary), so `await` it.

```javascript
const text = await extractText(base64Bytes, 'application/pdf');
```

| Content type | Result |
|--------------|--------|
| `application/pdf` | Extracted page text (empty for a scanned, image-only PDF) |
| Excel (`.xlsx`, `.xls`) | One CSV block per sheet, under a `### Sheet: <name>` heading |
| Word (`.docx`) | Extracted document text |
| `text/*`, `application/json`, `application/csv`, `application/xml` | Returned unchanged |

Any other content type (including images) throws. For a PDF or image you want an agent to read **natively as a document** (layout, scanned pages) rather than as text, return it from a tool with the `$file` convention instead (see `agents.md`).

## Imports

Files under `server/`, `webhooks/`, and `tools/` are bundled at deploy by an esbuild plugin that resolves imports **only against the app's own library** — the host filesystem and `node_modules` are invisible.

**Use relative imports only** (`./foo`, `../shared/util.js`); implicit `.js` / `.json` / `/index.js` resolution works. The bundler rejects (and `npm run deploy` fails on):

- Bare specifiers — `fs`, `node:crypto`, `lodash`, anything not starting with `./` or `../`. Apps have no `node_modules` and no Node built-ins.
- Absolute paths (`/etc/...`, `C:\...`).
- `..` paths that escape the project root.

For HTTP, hashing, base64, and markdown, use the injected sandbox helpers (`fetch`, the `crypto` helpers, the `base64*` globals, `markdown`) — don't try to import their underlying libraries. For third-party logic, copy what you need into a project-local file and import that.

`npm run dev` uses Vite, not this bundler — a forbidden import may run in dev and only fail at deploy.

## Sandbox Constraints

Server handlers run in a sandboxed V8 isolate. This means:

- **No Node.js APIs** — no `require()`, `fs`, `http`, `process`, `Buffer`, etc. The bundler blocks these as imports (see [Imports](#imports) above); even if you got one past the bundler, the runtime has no Node module system to load it.
- **No network access** — all external calls must go through `fetch()` (which enforces the whitelist)
- **No filesystem** — use `query()` for persistence
- **`btoa()` and `atob()` are available** — base64 encode/decode strings (Latin-1 only, per spec)
- **UTF-8 base64 helpers** — `base64Decode()`, `base64Encode()`, `base64UrlDecode()`, `base64UrlEncode()` are async functions that correctly handle multi-byte UTF-8 characters (e.g. smart quotes, emoji). **Prefer these over `atob()`/`btoa()` for any text that may contain non-ASCII characters.**
- **`markdown(text)`** — async function that converts markdown text to HTML using `marked`. Useful for generating formatted email bodies.
- **`extractText(data, contentType)`** — async function that extracts plain text from a base64 file (PDF, Excel, Word, text/*). Throws on unsupported types (e.g. images). See [Using `extractText()`](#using-extracttext).
- **`log(message, data?)`** — structured logging with level methods (`log.info()`, `log.warn()`, `log.error()`, `log.debug()`). Writes to `app_log` in production; prints to console in dev mode.
- **128 MB memory limit** — the isolate is killed if it exceeds this
- **Wall-clock timeout** — defaults to 30s, configurable via `config.timeout`
- **Ephemeral** — a fresh isolate is created for each request; no state persists between calls

## Calling Server Routes from App Code

Server routes are accessed through the app's view API proxy at `/api/_server/`:

```javascript
// GET /api/_server/orders
const response = await fetch('/api/_server/orders');
const orders = await response.json();

// POST /api/_server/orders
const response = await fetch('/api/_server/orders', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ customer: 'Acme Corp', total: 1500 })
});
const newOrder = await response.json();

// GET /api/_server/orders/abc123
const response = await fetch('/api/_server/orders/abc123');
const order = await response.json();

// POST /api/_server/orders/abc123/approve
const response = await fetch('/api/_server/orders/abc123/approve', {
    method: 'POST'
});
```

Server routes use the same authentication as the rest of the app's API proxy — the view token cookie is automatically included.

## Project Structure with Server Routes

```
my-app/
  migrations/
    001-create-orders.sql
    002-create-line-items.sql
  server/
    index.js              → GET /
    orders/
      index.js            → GET,POST /orders
      [id].js             → GET,PUT,DELETE /orders/:id
      [id]/
        approve.js        → POST /orders/:id/approve
        line-items.js     → GET,POST /orders/:id/line-items
  public/
    favicon.svg
  src/
    main.js
  informer.yaml
  index.html
  package.json
  .env
```

## Full Example: Orders API

**Migration:**
```sql
-- migrations/001-create-orders.sql
CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    customer TEXT NOT NULL,
    total NUMERIC(10,2) DEFAULT 0,
    status TEXT DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

**Server handlers:**
```javascript
// server/orders/index.js

export async function GET({ query, request }) {
    const status = request.query.status;
    if (status) {
        return await query('SELECT * FROM orders WHERE status = $1 ORDER BY created_at DESC', [status]);
    }
    return await query('SELECT * FROM orders ORDER BY created_at DESC LIMIT 100');
}

export async function POST({ query, request }) {
    const { customer, total } = request.body;
    if (!customer) {
        return { status: 400, body: { error: 'Customer is required' } };
    }
    const [order] = await query(
        'INSERT INTO orders (customer, total) VALUES ($1, $2) RETURNING *',
        [customer, total || 0]
    );
    return { status: 201, body: order };
}
```

```javascript
// server/orders/[id].js

export async function GET({ query, request }) {
    const [order] = await query('SELECT * FROM orders WHERE id = $1', [request.params.id]);
    if (!order) return { status: 404, body: { error: 'Order not found' } };
    return order;
}

export async function PUT({ query, request }) {
    const { customer, total, status } = request.body;
    const [order] = await query(
        'UPDATE orders SET customer = COALESCE($1, customer), total = COALESCE($2, total), status = COALESCE($3, status) WHERE id = $4 RETURNING *',
        [customer, total, status, request.params.id]
    );
    if (!order) return { status: 404, body: { error: 'Order not found' } };
    return order;
}

export async function DELETE({ query, request }) {
    const [order] = await query('DELETE FROM orders WHERE id = $1 RETURNING id', [request.params.id]);
    if (!order) return { status: 404, body: { error: 'Order not found' } };
}
```

**Client code:**
```javascript
// src/main.js

async function loadOrders() {
    const response = await fetch('/api/_server/orders');
    const orders = await response.json();
    renderTable(orders);
}

async function createOrder(customer, total) {
    const response = await fetch('/api/_server/orders', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ customer, total })
    });
    if (!response.ok) {
        const err = await response.json();
        alert(err.error);
        return;
    }
    loadOrders();
}
```

## Local Development

Server routes run locally during `npm run dev` via Vite's `ssrLoadModule()`. The Vite plugin:
1. Detects a `server/` directory in your project
2. Mounts middleware at `/api/_server` that loads and executes your handler files
3. Passes the dev workspace connection to `query()` and proxies `fetch()` to the Informer server
4. Supports HMR — editing a server handler file takes effect immediately without restarting

No extra configuration is needed beyond having `.env` set up with `INFORMER_URL` and credentials. If your handlers use `query()`, ensure `migrations/` exists so the workspace is auto-provisioned (see `persistence.md`).
