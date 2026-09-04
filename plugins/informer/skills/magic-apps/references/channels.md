# Channels (Live Broadcast to Open Pages)

> **Load this reference when:** pushing live updates from the server to every open page of an App — `broadcast(channel, event, payload)` from a route/webhook/tool/channel handler, the `channels:` relay block in `informer.yaml`, gated channels under `channels/` (`join` / `leave` / `config.roles`), the `@user/<username>` private channel, or the page-side `__INFORMER__.channel(name).on(event, fn)` API. Also load it when a user asks for "real-time", "live", "push", "WebSocket", "presence", "typing indicator", or "stop polling".
>
> **Not in this file:** durable events and agents (`emit()`) — see `agents.md`. The rest of the handler bag (`query`, `fetch`, `respond`, …) — see `server-routes.md`. Origin mode itself (`app.appsBaseUrl`, per-app hostnames) — see `accounts-and-login.md`.

A **channel** is a named place a page subscribes to (`orders`, `orders/east`, `@user/jane`). A server-side handler calls `broadcast(channel, event, payload)`; every subscriber of that channel on every server in the cluster gets the frame a moment later. The App never opens a socket, mints a credential, or touches Redis: it names a channel on the page and broadcasts to it from the server.

`broadcast()` is the live counterpart of `emit()`: `emit()` writes a durable app event that agents process; `broadcast()` sends a fire-and-forget, at-most-once frame to whoever is watching right now. See [`broadcast()` vs `emit()`](#broadcast-vs-emit).

## The model

| Layer | Owned by | What it does |
|---|---|---|
| Socket | Informer (harness) | The page fetches `/_socket` on the App's own origin, trades its session for a 5-minute socket credential, and opens **one** WebSocket shared by every channel on the page. Lazy — nothing connects until the first `on()`. |
| Channel names | The App | Declared in `informer.yaml` (`channels:` relay) and/or gated by a handler file under `channels/`. A name that appears nowhere still works (see [Open channels](#open-channels)). |
| Frames | The App's server code | `broadcast(channel, event, payload)` from any server-side surface. One Redis publish, fanned out cluster-wide. No DB row, no delivery report. |
| Fan-out | Informer | Filters every frame by tenant + App, so a socket only ever sees its own App's channels. |

### Channels need origin mode

The socket is opened from the App's **own origin**, which only exists when the Informer server serves Apps in **origin mode** (`app.appsBaseUrl` configured, e.g. `https://{label}.apps.example.com`). On a **path-mode** server:

- **Deploy succeeds with a warning.** An App with a `channels:` block or a `channels/` directory deploys, and the response carries a non-fatal partial failure `{ phase: 'channels', error: 'channels_require_origin_mode' }` (`npm run deploy` prints it under "non-fatal deploy phase failure(s)").
- **`__INFORMER__.channel()` throws synchronously** with `err.code === 'origin_mode_required'` — it never returns a channel that silently never delivers.

Ask whether the target server runs in origin mode before building on channels. Code the page defensively either way (the React hook below shows the fallback).

Channels are an **App** capability: a Magic Report (`type: report`) deploy that carries a `channels:` block or a `channels/` directory is refused with `apps_license_required`, and `broadcast()` on that tier throws `app_channels_unavailable`.

## How it works

1. Name a channel: declare it under `channels:` in `informer.yaml` (relay of events you already `emit()`), and/or add a handler file under `channels/` (gated channel with `join` / `leave`). Or neither — see [Open channels](#open-channels).
2. `npm run deploy` — uploads `channels/`, validates the `channels:` block (400 on a bad name), scans + bundles each handler file exactly like `server/` routes.
3. On the page: `__INFORMER__.channel('orders').on('created', fn)`. The first `on()` connects the socket.
4. From any server-side handler: `await broadcast('orders', 'created', payload)`. Every subscriber runs `fn(payload, frame)`.

## Channel and event names

| | Grammar | Max | Examples |
|---|---|---|---|
| Channel | Segments of `[A-Za-z0-9_.-]` joined by `/`. A name beginning `@user/` is the exception: everything after the prefix is ONE username and may hold anything except whitespace | 128 | `orders`, `orders/east`, `tickets/42/typing`, `@user/jane@acme.com` |
| Event | `[A-Za-z0-9_.-]+` | 64 | `created`, `order_created`, `presence` |

Regexes (server and dev plugin share them): channel `^(@user\/\S+|[\w.-]+(\/[\w.-]+)*)$`, event `^[\w.-]+$`. The same grammar applies in `informer.yaml`, in `broadcast()`, in `channels/` export names, and in `channel()` on the page. A `default` export is never a valid event export.

## Relaying events with `channels:`

The quickest path to live updates is to relay events the App already emits:

```yaml
# informer.yaml
events:
  order_created:
    description: Fired when a new order is submitted
  order_shipped:
    description: Fired when an order ships

channels:
  orders:
    description: Live order activity for the Order Desk dashboard
    on: [order_created, order_shipped]
  payments:
    description: Payment confirmations
    on: payment_received
```

Every `emit('order_created', payload)` now does two things: creates the durable app event (agents still trigger) **and** broadcasts a frame to `orders` with the **same event name and payload**. No handler code changes.

| Field | Type | Description |
|---|---|---|
| `description` | string, optional | Author-facing note, ≤ 500 chars |
| `on` | string or string[], optional | Event names to relay into this channel. Persisted as an array on `app.defn.channels` |

Rules:

- Names are validated at deploy. A bad channel or event name **fails the deploy** with `400 Invalid channels: block in informer.yaml: …` — never a silent drop.
- A relay that can't be delivered (frame too large, App over its broadcast rate, channels disabled) is logged on the server as "App channel relay dropped" and skipped. **The `emit()` itself still succeeds** — relay never fails an emit.
- Only `emit()` calls from the App's own handlers are relayed. The platform's `onFailure` event (agent run terminally failed) is not.
- `emit()` with no payload crosses the sandbox as `{}`, so the relayed frame's `payload` is `{}`, not `null`.
- Removing the block and redeploying removes the relay (`app.defn.channels` is deleted).

### Open channels

**The `channels/` handler file is the only gate.** A channel that exists only in `channels:` — or one that appears nowhere at all — is **open**: every page of the App can subscribe (the socket is already bound to the App + tenant, so "everyone" means "every viewer of this App"). `broadcast('anything', …)` to a name no file covers reaches whoever subscribed to it. Add a `channels/` file when a channel must be limited to some users. The one exception is `@user/<username>`, which is owner-checked at the socket layer with no file needed.

## Channel handlers in `channels/`

A handler file makes a channel **gated**: it decides who may join, learns when they leave, and can restrict the channel to roles. Same file-convention routing as `server/`; `[segment]` becomes a param:

| File | Channel pattern | Matches |
|---|---|---|
| `channels/orders.js` | `orders` | `orders` |
| `channels/orders/[region].js` | `orders/:region` | `orders/east`, `orders/west` |
| `channels/tickets/[id]/typing.js` | `tickets/:id/typing` | `tickets/42/typing` |

Deploy stores each file as an app_route row with the synthetic method `CHANNEL`, so it never collides with HTTP routes and is never reachable over HTTP.

### Reserved exports

| Export | Runs | Contract |
|---|---|---|
| `config` | At deploy | `{ roles?: string[], timeout?: number }`. A `config` that can't be parsed **fails the deploy** (same rule as a route's). `roles`: subscriber must hold at least one, checked before `join` runs. `timeout`: wall-clock cap in ms for `join` and `leave`, never above the server's `joinTimeoutMs` (default 5000) |
| `join` | When a socket subscribes to a name this file matches | Must return **exactly `true`** to admit. Anything else — `1`, a row, `undefined`, a thrown error — refuses with `join_refused` on the page |
| `leave` | When that socket unsubscribes, calls `close()`, or disconnects | Return value ignored. **Never throws through** — a failing `leave` is logged at warn and the unsubscribe proceeds |

All three are optional. **A file with no `join` export admits everyone** the socket-level checks let through (still subject to `config.roles`). No `leave` → nothing runs on leave.

No other export is accepted: event-named exports (`typing`, `cursor`) are reserved for phase-2 inbound messages and are **refused at deploy** until they can run, and `default` is never valid. Every scanner problem fails the deploy — a file skipped with a warning would leave its channel with no handler row, and a channel with no row is open, so a typo on redeploy could silently drop the gate the channel had before:

| File state | Result |
|---|---|
| No exports at all | **Deploy fails** |
| An export other than `config`, `join`, `leave` (event names and `default` included) | **Deploy fails** |
| A path no page could subscribe to (`channels/my orders.js`; `channels/index.js`, which names no channel) | **Deploy fails** |
| Not valid JavaScript | **Deploy fails** |
| Two files mapping to the same channel pattern | **Deploy fails** |
| Unparseable `config` | **Deploy fails** |

### Worked example

```javascript
// channels/orders/[region].js
export const config = {
    roles: ['sales', 'manager'],  // only these roles may subscribe
    timeout: 2000                 // cap for join/leave, ms
};

// Admit only users with access to the region. One indexed query — a subscribe is a user waiting.
export async function join({ channel, request, query, log }) {
    const { region } = channel.params;
    const [row] = await query(
        'SELECT 1 FROM region_access WHERE region = $1 AND username = $2',
        [region, request.user.username]
    );
    log.info('join', { channel: channel.name, user: request.user.username, ok: !!row });
    return !!row;   // exactly true admits
}

export async function leave({ channel, request }) {
    await channel.broadcast('presence', { left: request.user.username });
}
```

### The handler bag

`join` and `leave` receive the shared handler bag — `context`, `query`, `transaction`, `fetch`, `emit`, `broadcast`, `notify`, `email`, `crypto`, `log`, `env` (+ the `markdown` / `extractText` / base64 globals) — **without `respond`** (there is no HTTP response), plus three channel members:

| Member | Type | Description |
|---|---|---|
| `channel` | `object` | `channel.name` — the subscribed name (`orders/east`); `channel.params` — from `[segment]` files (`{ region: 'east' }`); `channel.broadcast(event, payload)` — sugar for `broadcast(channel.name, event, payload)` |
| `payload` | `null` | Always `null` for `join` and `leave` (reserved for phase-2 inbound events) |
| `request` | `object` | `request.user` — `{ username, displayName, email, timezone }` of the subscriber; `request.roles` — their role IDs. **No `body`, `headers`, `params`, or `query`** — a subscription is not an HTTP request; the route params are on `channel.params` |

`leave` gets the same `channel.params` object that matched at join time. `log()` calls land in the App's Logs tab with `source: 'channel'` (filterable there), alongside the operator warnings the server writes for refused joins, rate-limited broadcasts, and dropped relays.

### What `join` sees (order of checks)

Socket-layer checks run first, before any App code:

1. The socket is an App socket for **this** App (mismatch → 403).
2. The name matches the grammar (→ 400) and, for `@user/<name>`, the **whole** remainder `<name>` equals the socket's own username (→ 403). No file needed for this check.
3. `maxChannelsPerSocket` and `maxSubscribersPerApp` (→ 429, `rate_limited` on the page).

Then the handler layer:

4. The subscriber can still read the App (a user who lost access → 404, surfaces as `join_refused`).
5. No `channels/` file matches the name → **admitted** (open channel). Nothing runs on join or leave.
6. `config.roles` set and the subscriber holds none → 403 `app_channel_role_required`.
7. No `join` export → admitted.
8. Compute budget check (→ 402 when exhausted — surfaces as `join_refused`), then `join` runs under `min(config.timeout, joinTimeoutMs)`. `=== true` admits; anything else → 403 `app_channel_join_refused`; timeout → 504 `app_channel_join_timeout` (surfaces as **`disconnected`**, not `join_refused`).

Compute is metered for `join` and `leave` like a route (`route: 'channel:<name>'`).

## Broadcasting from the server

`broadcast(channel, event, payload)` is in the handler bag of **every** server-side surface: `server/` routes, `server/public/` routes, `webhooks/`, `tools/` and `mcp/` handlers, and `channels/` handlers. It resolves to `{ ok: true }` once the frame is **published**; it does not wait for delivery and never reports subscriber count (zero subscribers is not an error).

```javascript
// webhooks/stripe/payment.js — a payment lands, every open dashboard hears about it
export async function POST({ crypto, request, env, query, broadcast }) {
    const header = request.headers['stripe-signature'] || '';
    const sig = Object.fromEntries(header.split(',').map(part => part.split('=')));
    const ok = sig.t && sig.v1
        && await crypto.verifyHmac('sha256', env.STRIPE_WEBHOOK_SECRET, `${sig.t}.${request.rawBody}`, sig.v1);
    if (!ok) return { status: 401, body: { error: 'Invalid signature' } };

    const event = request.body;
    if (event.type === 'payment_intent.succeeded') {
        const intent = event.data.object;
        const [payment] = await query(
            'INSERT INTO payments (intent_id, amount, currency) VALUES ($1, $2, $3) RETURNING *',
            [intent.id, intent.amount, intent.currency]
        );
        await broadcast('payments', 'received', payment);
    }
    return { received: true };
}
```

```javascript
// server/orders/[id]/approve.js — broadcast to a regional channel after the write
export async function POST({ query, request, broadcast }) {
    const [order] = await query(
        `UPDATE orders SET status = 'approved', approved_by = $2 WHERE id = $1 RETURNING *`,
        [request.params.id, request.user.username]
    );
    if (!order) return { status: 404, body: { error: 'Not found' } };
    await broadcast(`orders/${order.region}`, 'approved', order);
    return order;
}
```

`payload` is any JSON value; omitted → `null`. Serialized once, delivered verbatim. **Send the changed row, not the table** — the cap is 64 KiB per frame.

`broadcast()` **rejects** (the `await` throws) when the frame can't be published:

| Error message / code | Status | Why |
|---|---|---|
| `app_channel_invalid_name` | 400 | Channel name fails the grammar or exceeds 128 chars |
| `app_channel_invalid_event` | 400 | Event name fails the grammar or exceeds 64 chars |
| `app_channel_invalid_payload` | 400 | Payload can't be `JSON.stringify`'d (BigInt, circular) |
| `app_channel_frame_too_large` | 413 | Serialized payload > `maxFrameBytes` (64 KiB default) |
| `app_channel_rate_limited` | 429 | App over its cluster-wide broadcast token bucket (50/s, burst 200) |
| `app_channels_unavailable` | 503 / thrown | The App's type has no channels capability (Magic Report), or the server's pub/sub layer is not up |
| `app_channels_disabled` | 403 | An admin set `app.channels.enabled: false` |
| `app_channel_broadcast_failed` | 503 | The pub/sub layer refused the frame, so it never left the server and nobody received it |

**Wrap `broadcast()` in `try`/`catch` when a lost frame must not fail the request.** A broadcast is a courtesy to open pages, not the record of what happened — the write that preceded it already succeeded. If the App also relays via `channels:`, prefer one `emit()` over `emit()` + a hand `broadcast()` of the same thing (double frames).

## The `@user/<username>` channel

Names beginning with `@user/` are private to one user: a socket may subscribe to `@user/jane` **only** when the App session belongs to `jane`. Everything after `@user/` is the username, **all of it**: `@user/jane/typing` belongs to a user named `jane/typing`, not to `jane`. Anyone else is refused at the socket layer (`join_refused`) before any handler runs. Use it to deliver something to exactly one person's open pages — a long-running job they kicked off, a personal notification.

```javascript
// server/reports/[id]/run.js — ack now, broadcast the result to the caller's own pages when done
export async function POST({ query, request, broadcast, respond }) {
    const channel = `@user/${request.user.username}`;
    await respond({ status: 202, body: { channel } });
    const [report] = await query('SELECT * FROM reports WHERE id = $1', [request.params.id]);
    const rows = await query(report.sql);
    await broadcast(channel, 'report_ready', { id: report.id, count: rows.length });
}
```

```javascript
// on the page — subscribe BEFORE kicking off the work so a fast result can't beat the listener
const mine = `@user/${__INFORMER__.user.username}`;
__INFORMER__.channel(mine).on('report_ready', ({ id, count }) => {
    showToast(`Report ${id} finished with ${count} rows`);
});
await fetch(`/api/reports/${reportId}/run`, { method: 'POST' });
```

`window.__INFORMER__.user` is `{ username, displayName }` for the signed-in viewer on every render (main app and widgets). In dev it defaults to `{ username: 'dev', displayName: 'Local Developer' }`; set `mock.user` in `vite.config.js` to test as someone else:

```javascript
informer({ mock: { user: { username: 'jane', displayName: 'Jane Doe' } } })
```

The username admits anything but whitespace (email-style and domain-qualified usernames work) and runs to the end of the name. For a second axis (per person **and** per topic), use a plain channel gated by a `channels/` file rather than a name under `@user/`. A `channels/` file can still cover `@user/...` names when `join`/`leave` logic is needed on top of the ownership check.

## Subscribing on the page

`__INFORMER__.channel(name)` is synchronous and cheap; nothing loads or connects until the first `on()`.

```javascript
const orders = __INFORMER__.channel('orders/east');

const off = orders.on('created', (order, frame) => {
    // order === frame.payload; frame is the whole envelope
    addRow(order);
});

orders.on('error', err => {
    console.warn('orders/east', err.code, err.message);
});

off();            // remove this one handler
orders.close();   // unsubscribe the socket path and drop every handler
```

| Method | Description |
|---|---|
| `__INFORMER__.channel(name)` | Returns a channel object. Throws synchronously — `code: 'join_refused'` on a malformed name, `code: 'origin_mode_required'` on a path-mode server |
| `on(event, fn)` | Registers `fn(payload, frame)` for frames whose `event` matches. Returns an unsubscribe function for that one handler. The first `on()` on the page loads the socket client, fetches `/_socket`, connects, and subscribes; later channels share the connection |
| `on('error', fn)` | Registers `fn(err)`; `err.code` is one of the codes below. Without an error handler, errors go to `console.warn` |
| `send(event, payload)` | **Not supported yet** — always rejects with `code: 'not_supported'`. See [Inbound messages](#inbound-messages-phase-2) |
| `close()` | Unsubscribes and drops all handlers. Idempotent. `on()` after `close()` throws (`code: 'disconnected'`) |

The frame envelope every subscriber receives:

```json
{
  "tenant": "acme",
  "appId": "7d5a9b1e-0c83-4bde-9e2a-3a4b5c6d7e8f",
  "channel": "orders/east",
  "event": "created",
  "payload": { "id": 1042, "customer": "Northwind", "total": 1500 },
  "at": 1724944800000
}
```

An exception inside one handler is logged (`[Informer] channel handler failed`) and does not stop the others.

### Error codes

| `err.code` | Meaning | What to do |
|---|---|---|
| `join_refused` | Subscribe refused: `join` returned something other than `true`, a `config.roles` miss, malformed name, user can't read the App, compute budget spent, or a `@user/` name that belongs to someone else. (Any 4xx other than 429.) | Don't retry in a loop. Render without the live feed, or tell the user why |
| `rate_limited` | This socket holds `maxChannelsPerSocket` (20) subscriptions, or the App has `maxSubscribersPerApp` (500) on this server. (429) | `close()` channels you no longer need; combine channels |
| `disconnected` | The socket dropped, couldn't be established (credential refused, client failed to load), **or the App's `join` timed out** (504). Every open channel receives it once per drop | Nothing required — the shim reconnects on its own (below). **Re-fetch state you may have missed**: frames sent during the gap are gone |
| `origin_mode_required` | Thrown by `channel()` itself on a path-mode server | Fall back to polling a server route |
| `not_supported` | Returned by `send()` | Post to a server route and let it `broadcast()` the result back |

### Reconnect behaviour

Informer's own nes auto-reconnect is **off** (it would replay the short-lived credential). Instead the shim:

- Reports `disconnected` once to every open channel on a drop.
- Retries on its own with **bounded, jittered backoff** — 1 s doubling to a 30 s cap (+0–50 % jitter) — minting a fresh `/_socket` credential each attempt, and resets the delay once a connection lands.
- Reconnects **immediately when the page becomes visible** again (`visibilitychange`), so a phone back from sleep or a laptop lid recovers without help.
- Also reconnects on the next `channel()` or `on()` call if one comes first.
- Re-subscribes every open channel after reconnecting — `join` runs again for gated ones.
- Stops retrying when no channel holds a handler (all closed).

A listen-only page therefore recovers by itself; the App's only job is to **re-fetch on `disconnected`** if it must be exact.

### React example

```jsx
import { useEffect, useState } from 'react';

// Ties one subscription to the component lifecycle; degrades to no live feed on path mode.
function useChannel(name, event, onFrame) {
    useEffect(() => {
        let channel;
        try {
            channel = window.__INFORMER__.channel(name);
        } catch (err) {
            console.warn(`Live updates unavailable: ${err.code}`);   // origin_mode_required
            return undefined;
        }
        channel.on(event, onFrame);
        channel.on('error', err => console.warn(`${name}: ${err.code}`));
        return () => channel.close();
    }, [name, event, onFrame]);
}

export function OrderFeed({ region }) {
    const [orders, setOrders] = useState([]);

    useEffect(() => {
        fetch(`/api/orders?region=${region}`)
            .then(res => res.json())
            .then(setOrders);
    }, [region]);

    useChannel(`orders/${region}`, 'created', order => {
        setOrders(current => [order, ...current]);
    });

    return (
        <ul>
            {orders.map(order => (
                <li key={order.id}>{order.customer}: {order.total}</li>
            ))}
        </ul>
    );
}
```

Pattern: **load current state from a server route first, then let the channel keep it fresh.** Memoize `onFrame` (`useCallback`) so the effect doesn't resubscribe on every render. A page that must be exact re-fetches when it sees `disconnected`.

## `broadcast()` vs `emit()`

| | `emit(event, payload)` | `broadcast(channel, event, payload)` |
|---|---|---|
| Writes a row | Yes — an app event agents process and you can inspect later | No |
| Delivery | Durable: retried, dead-lettered, visible in run history | **At most once**: whoever is subscribed right now; lost if nobody is, or during a reconnect |
| Audience | Agents (and, via `channels:`, subscribers) | Open pages |
| Ordering | Processed asynchronously | No ordering guarantee between frames |
| Cost | A DB write per call | A Redis publish per call, rate-limited per App |
| In dev | Console log only (+ runs the relay) | Real frames over Vite's dev socket |

**Rule of thumb: if you'd be upset it was lost, `emit`; if it'd be stale in a second anyway, `broadcast`.** An approved order is a fact — `emit('order_approved')` and let the `channels:` relay tell the dashboards. "Jane is typing" is a moment — `broadcast('tickets/42/typing', 'typing', …)` and forget it. A handler that needs both the fact and the live update should `emit()` once and rely on the relay, so the durable record and the live frame come from one call.

## Limits

Server defaults under `app.channels` (`config-factory.js`). An admin can change them; an App cannot.

| Setting | Default | Enforced when |
|---|---|---|
| `enabled` | `true` | `false` → every `broadcast()` rejects with `app_channels_disabled` |
| `maxSubscribersPerApp` | 500 | Subscriptions per App, counted **cluster-wide** (redis, per-node heartbeat; a dead node's sockets drop out within 30 s). Next subscribe → `rate_limited` |
| `maxChannelsPerSocket` | 20 | Subscriptions one page's socket may hold. Next `on()` on a new channel → `rate_limited` |
| `maxFrameBytes` | 65536 (64 KiB) | Serialized **payload** size per broadcast; larger → `app_channel_frame_too_large` |
| `broadcastRate` | `{ perSecond: 50, burst: 200 }` | Per-App token bucket shared across the cluster (Redis); exceeding → `app_channel_rate_limited` |
| `inboundRate` | `{ perSecond: 10, burst: 30 }` | Reserved for phase-2 `send()`; not enforced today |
| `joinTimeoutMs` | 5000 | Hard ceiling for `join` / `leave`, whatever `config.timeout` says |

The socket credential from `/_socket` lives 5 minutes; the shim re-mints it on every reconnect, so the App never handles it.

## What the operator sees (App **Logs** tab, `channel` source)

Channel activity is too chatty to log per event, so every refusal and drop is counted per `(code, channel)` and flushed to the App's own log stream once a minute: one warn row per code, naming the three busiest channels (`14 relays dropped on "orders" in the last minute`). **This is the only trace of a `broadcast()` that failed after the call returned** — point the author at the App Admin panel's **Logs** tab filtered to `channel`, not at the server log.

| Code | Means |
|---|---|
| `join_refused` | `join` returned something other than `true` |
| `join_role_required` | Subscriber holds none of `config.roles` |
| `join_timeout` | `join` ran past `joinTimeoutMs` |
| `join_failed` | `join` threw |
| `join_invalid_name` | Name could not be decoded, so no handler or role gate could match it (fails closed) |
| `subscriber_limit` | App at `maxSubscribersPerApp` cluster-wide |
| `socket_limit` | One page over `maxChannelsPerSocket` |
| `broadcast_rate_limited` | App over `broadcastRate` |
| `broadcast_failed` | Pub/sub refused the frame; nobody received it |
| `budget_exhausted` | App compute budget spent |
| `budget_check_failed` | Budget unreadable, so the frame was let through rather than lost |
| `relay_dropped` | An `emit()` could not be relayed to its channel |

The **Channels** tab of the same panel carries the live counters (subscribers now; broadcasts / deliveries / rate-limited over 60m; joins / refusals / leaves over 30d) and the server's limits.

## Local development

`npm run dev` runs the whole loop with **no server socket**:

- `broadcast()` is in the dev handler bag for server routes and agent tools — same name/event/payload/frame-size validation and the same error codes as production. Every call is logged to the terminal (`[app-channel] broadcast(...)`).
- `emit()` runs the `channels:` relay locally (no app-event row in dev), so a page subscribed to a relayed channel sees the frame (`[app-channel] relayed emit("...") → channel "..."`).
- `__INFORMER__.channel()` on the dev page has the production surface. Frames ride **Vite's own dev WebSocket** (`import.meta.hot`) — no second socket, nothing to configure. `frame.tenant` is `'dev'`, `frame.appId` is the mocked App id.
- The `channels:` block is validated at dev-server boot; problems print as `[informer] informer.yaml: …` so you see at boot what the deploy would 400 on.
- `__INFORMER__.user` defaults to `{ username: 'dev', displayName: 'Local Developer' }`; override with `mock.user`.

What dev does **not** do:

- `channels/` handlers never run locally — `join`, `leave`, `config.roles`, `config.timeout`, and the `@user/` ownership check are **not enforced**. Everything is an open channel in dev.
- `rate_limited` never happens (no subscriber caps, no broadcast token bucket); `app_channels_disabled` / `app_channels_unavailable` never happen.
- The mock only works on a page served by `vite dev` with its HMR socket available; without it, the first `on()` reports `disconnected`. A Vite HMR drop surfaces as `disconnected` too.

**Validate gating by deploying to an origin-mode server.** "Works in dev, `join_refused` after deploy" almost always means `join` didn't return exactly `true`, `config.roles` missed, or the `@user/` owner check fired.

## Inbound messages (phase 2)

Page → server over the channel is **not in this release**: `send()` rejects with `not_supported`, `inboundRate` is unenforced, and event-named exports in `channels/` files are refused at deploy. Until then, send user input through a server route and let the route `broadcast()` the result back. Don't design a feature around `send()` landing.

## Gotchas

- **Don't broadcast an event named `error`.** On the page, `on('error', fn)` receives channel errors (`{ code, message }`); a broadcast frame with `event: 'error'` would also dispatch to those handlers, with `(payload, frame)` instead of an `Error`. Pick another name (`failed`, `problem`).
- **A `join` timeout surfaces as `disconnected`, not `join_refused`.** The server answers 504; the shim maps non-4xx to `disconnected` and then keeps reconnecting (and re-running `join`). Make `join` faster or raise `config.timeout` (≤ `joinTimeoutMs`).
- **`join` must return exactly `true`.** `return row`, `return 1`, `return !!row || undefined` — anything but the boolean `true` refuses.
- **Frames over 64 KiB are rejected, not truncated.** `broadcast()` throws `app_channel_frame_too_large`; a relay of the same size is dropped and logged. Broadcast the changed row (or just its id and let the page fetch), never a table.
- **The `channels/` file is the only gate.** No file = open to every viewer of the App. `channels:` in `informer.yaml` names a relay, it does not restrict anyone. If a channel carries data some viewers shouldn't see, it needs a handler file with `config.roles` and/or `join`.
- **Subscribe to the exact name the server broadcasts to.** `orders/east` is not `orders`; there is no wildcard or parent-channel fan-in. A page that wants all regions subscribes to each, or the server broadcasts to a summary channel as well.
- **Subscribe before you kick off the work.** With at-most-once delivery a fast result can land before `on()` runs.
- **Frames during a reconnect are lost.** Re-fetch on `disconnected` if exactness matters; `emit()` + relay if the fact must survive.
- **`channel.params`, not `request.params`.** A channel handler's `request` is `{ user, roles }` only; route params live on `channel.params`, and there is no `respond`.
- **Older skill/docs examples use `/api/_server/...`** for route calls; the bare `/api/...` spelling is current (see `server-routes.md`). Both reach the same route.
- **`maxSubscribersPerApp` fails open.** The cluster-wide count lives in redis; if redis is unreachable the cap admits everyone (with a server warning) rather than refusing all subscribes.

## Project structure with channels

```
my-app/
  channels/
    orders/
      [region].js         → orders/:region (config, join, leave)
    tickets/
      [id]/
        typing.js         → tickets/:id/typing
  server/
    orders/
      [id]/
        approve.js        → POST /orders/:id/approve, broadcasts to orders/:region
    reports/
      [id]/
        run.js            → POST /reports/:id/run, broadcasts to @user/<username>
  webhooks/
    stripe/
      payment.js          → broadcasts to payments
  informer.yaml           → channels: relay block (+ events:, agents:)
  index.html
  package.json
```

`npm run deploy` uploads `channels/` alongside `server/` and `webhooks/`, then prints "Registered N channel handler(s)" and "Relaying events to N channel(s)" from the deploy result (`channelHandlers`, `channels`).
