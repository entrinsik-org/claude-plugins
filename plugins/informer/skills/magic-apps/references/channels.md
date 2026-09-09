# Channels (Live Broadcast to Open Pages, and Back)

> **Load this reference when:** pushing live updates from the server to every open page of an App — `broadcast(channel, event, payload, options?)` from a route/webhook/tool/channel handler, the `channels:` relay block in `informer.yaml`, gated channels under `channels/` (`join` / `joined` / `leave` / event exports, `config.roles`), the `@user/<username>` private channel, wildcard subscriptions (`rooms/*`), the page-side `__INFORMER__.channel(name, { since }).on(event, fn)` / `.send(event, payload)` API, frame `seq`, replay after a reconnect, `connected`, `replay_gap`. Also load it when a user asks for "real-time", "live", "push", "WebSocket", "presence", "typing indicator", "chat", "cursor", "stop polling", or "send from the page over the socket".
>
> **Not in this file:** durable events and agents (`emit()`) — see `agents.md`. The rest of the handler bag (`query`, `fetch`, `respond`, …) — see `server-routes.md`. Origin mode itself (`app.appsBaseUrl`, per-app hostnames) — see `accounts-and-login.md`.
>
> **Availability:** Informer **2026.1.3** (I5-12980 phase 1, I5-13027 phase 2), on an origin-mode server. Phase 1 is broadcast, relay, `join`/`leave`, `@user/`. Phase 2 adds inbound `send()`, the `joined` export, wildcards, `seq` + replay, `connected`, `platform.originMode`, and requires `on` in the `channels:` block; **earlier 2026.1.3 preview builds carry phase 1 only.** Feature-detect: `platform.originMode` is `undefined` on a phase 1 build and a boolean on phase 2; on the page a phase 1 `send()` rejects with `not_supported`. Older servers have no `broadcast` in the bag and no `__INFORMER__.channel`; a path-mode server of any version deploys the app with a warning and `channel()` throws `origin_mode_required`. Below the floor, poll the route you would have broadcast from. Dev support for phase 2 needs `@entrinsik/vite-plugin-informer` **2.11.0+**.

A **channel** is a named place a page subscribes to (`orders`, `orders/east`, `rooms/*`, `@user/jane`). A server-side handler calls `broadcast(channel, event, payload)`; every subscriber of that channel on every server in the cluster gets the frame a moment later. A subscribed page can answer with `channel.send(event, payload)`, which runs a handler of the App's on the server. The App never opens a socket, mints a credential, or touches Redis: it names a channel on the page and broadcasts to it from the server.

`broadcast()` is the live counterpart of `emit()`: `emit()` writes a durable app event that agents process; `broadcast()` sends a fire-and-forget frame to whoever is watching right now, with a short replay window for pages that drop and come back. See [`broadcast()` vs `emit()`](#broadcast-vs-emit).

## The model

| Layer | Owned by | What it does |
|---|---|---|
| Socket | Informer (harness) | The page fetches `/_socket` on the App's own origin, trades its session for a 5-minute socket credential, and opens **one** WebSocket shared by every channel on the page. Lazy — nothing connects until the first `on()`. `send()` and the replay read travel over the same socket. |
| Channel names | The App | Declared in `informer.yaml` (`channels:` relay) and/or gated by a handler file under `channels/`. A name that appears nowhere still works (see [Open channels](#open-channels)). |
| Frames | The App's server code | `broadcast(channel, event, payload)` from any server-side surface. One Redis publish, fanned out cluster-wide, numbered per channel (`seq`), kept briefly for replay. No DB row, no delivery report. |
| Inbound | The App's `channels/` file | `send(event, payload)` runs the export named after the event, as the viewer. The subscription is the authorization. |
| Fan-out | Informer | Filters every frame by tenant + App, so a socket only ever sees its own App's channels. |

### Channels need origin mode

The socket is opened from the App's **own origin**, which only exists when the Informer server serves Apps in **origin mode** (`app.appsBaseUrl` configured, e.g. `https://{label}.apps.example.com`). On a **path-mode** server:

- **Deploy succeeds with a warning.** An App with a `channels:` block or a `channels/` directory deploys, and the response carries a non-fatal partial failure `{ phase: 'channels', error: 'channels_require_origin_mode' }` (`npm run deploy` prints it under "non-fatal deploy phase failure(s)").
- **`__INFORMER__.channel()` throws synchronously** with `err.code === 'origin_mode_required'` — it never returns a channel that silently never delivers.

**Decide before the first `channel()` call, not in a catch.** `window.__INFORMER__.platform.originMode` is `true` on an origin-mode server and `false` in path mode (phase 2; `undefined` on phase 1 builds and older servers, which is your cue to treat it as unknown and ask). The same `platform` object reaches every handler bag, and the Vite dev mock reports `true`.

```javascript
const live = window.__INFORMER__.platform?.originMode === true;
if (live) __INFORMER__.channel('orders').on('created', addRow);
else setInterval(refreshOrders, 15000);
```

Another way to read a running server, after any deploy: `GET /api/apps/{owner}:{slug}/channels` reports `originMode` next to the limits. On an origin-mode server the app URL also redirects to `https://<slug>--<label>.<host>`, which is the quickest visual confirmation. Ask whether the target server runs in origin mode before building on channels, and code the page defensively either way.

Channels are an **App** capability: a Magic Report (`type: report`) deploy that carries a `channels:` block or a `channels/` directory is refused with `apps_license_required`, and `broadcast()` on that tier throws `app_channels_unavailable`.

## How it works

1. Name a channel: declare it under `channels:` in `informer.yaml` (a relay of events you already `emit()`), and/or add a handler file under `channels/` (a gated channel with `join` / `joined` / `leave`, and the place inbound messages land). Or neither — see [Open channels](#open-channels).
2. `npm run deploy` — uploads `channels/`, validates the `channels:` block (400 on a bad name or a missing `on`), scans + bundles each handler file exactly like `server/` routes.
3. On the page: `__INFORMER__.channel('orders').on('created', fn)`. The first `on()` connects the socket; once the subscription is up the channel fires `connected`.
4. From any server-side handler: `await broadcast('orders', 'created', payload)`. Every subscriber runs `fn(payload, frame)`.
5. Back the other way: `channel.send('typing', { at })` runs the `typing` export of the covering `channels/` file and resolves with whatever it returned.

## Channel and event names

| | Grammar | Max | Examples |
|---|---|---|---|
| Channel | Segments of `[A-Za-z0-9_.-]` joined by `/`. A subscription may end in one extra `*` segment (a [wildcard](#wildcard-subscriptions)). A name beginning `@user/` is the exception: everything after the prefix is ONE username and may hold anything except whitespace | 128 | `orders`, `orders/east`, `tickets/42/typing`, `rooms/*`, `@user/jane@acme.com` |
| Event | `[A-Za-z0-9_.-]+` | 64 | `created`, `order_created`, `presence` |

Regexes (server and dev plugin share them): channel `^(@user\/\S+|[\w.-]+(\/[\w.-]+)*(\/\*)?)$`, event `^[\w.-]+$`. The same grammar applies in `informer.yaml`, in `broadcast()`, in `send()`, in `channels/` export names, and in `channel()` on the page. **Two event names are reserved: `error` and `connected`** — the page client dispatches those itself, so `broadcast()` refuses them (`app_channel_reserved_event`), `send()` refuses them, and a `channels/` file cannot export them. A `default` export is never valid either. Use `failed` or `problem` for your own error frames.

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
| `on` | string or non-empty string[], **required** | Event names to relay into this channel. Persisted as an array on `app.defn.channels` |

**The block declares relays and nothing else.** It is not access control, and it does not create a channel: a name that appears nowhere is already subscribable, so a channel with nothing to relay needs no entry. Do not list channels here "for documentation" — an entry without `on` (a bare `orders:` key, description only, or an empty list) fails the deploy with `400 Invalid channels: block in informer.yaml: channels.orders: "on" is required — list the events to relay into the channel; a channel with nothing to relay needs no declaration`.

Rules:

- Names are validated at deploy. A bad channel or event name **fails the deploy** with `400 Invalid channels: block in informer.yaml: …` — never a silent drop. Every problem is reported at once. A wildcard cannot be a relay target.
- A relay that can't be delivered (frame too large, App over its broadcast rate, channels disabled) is logged on the server as "App channel relay dropped" and skipped. **The `emit()` itself still succeeds** — relay never fails an emit.
- Only `emit()` calls from the App's own handlers are relayed. The platform's `onFailure` event (agent run terminally failed) is not.
- `emit()` with no payload crosses the sandbox as `{}`, so the relayed frame's `payload` is `{}`, not `null`.
- Removing the block and redeploying removes the relay (`app.defn.channels` is deleted).

### Open channels

**The `channels/` handler file is the only gate.** A channel that exists only in `channels:` — or one that appears nowhere at all — is **open**: every page of the App can subscribe (the socket is already bound to the App + tenant, so "everyone" means "every viewer of this App"), nothing runs on join or leave, and `send()` on it is refused (there is no handler to receive a message). Add a `channels/` file when a channel must be limited to some users, or when pages need to send on it. The one exception is `@user/<username>`, which is owner-checked at the socket layer with no file needed.

## Channel handlers in `channels/`

A handler file makes a channel **gated**: it decides who may join, can announce the join, learns when they leave, can restrict the channel to roles, and receives what pages `send()`. Same file-convention routing as `server/`; `[segment]` becomes a param:

| File | Channel pattern | Matches |
|---|---|---|
| `channels/orders.js` | `orders` | `orders` |
| `channels/orders/[region].js` | `orders/:region` | `orders/east`, `orders/west`, and the wildcard `orders/*` (with `region: '*'`) |
| `channels/tickets/[id]/typing.js` | `tickets/:id/typing` | `tickets/42/typing` |

Deploy stores each file as an app_route row with the synthetic method `CHANNEL`, so it never collides with HTTP routes and is never reachable over HTTP.

### Exports

| Export | Runs | Contract |
|---|---|---|
| `config` | At deploy | `{ roles?: string[], timeout?: number }`. A `config` that can't be parsed **fails the deploy** (same rule as a route's). `roles`: subscriber must hold at least one, checked before `join` runs. `timeout`: wall-clock cap in ms for every export in the file, never above the server's `joinTimeoutMs` (default 5000) |
| `join` | When a socket subscribes to a name this file matches, **before** it is admitted | Must return **exactly `true`** to admit. Anything else — `1`, a row, `undefined`, a thrown error — refuses with `join_refused` on the page |
| `joined` | A moment **after** that socket is admitted | Return value ignored. A `joined` that throws or times out never affects the subscription (audited `joined_failed`). The place to announce presence: a broadcast from here reaches the joiner too |
| `leave` | When that socket unsubscribes, calls `close()`, or disconnects | Return value ignored. **Never throws through** — a failing `leave` is logged at warn and the unsubscribe proceeds |
| `<event>` (any other valid event name) | When a subscribed page calls `send(event, payload)` | Runs as the viewer with the message as `payload`; whatever it returns resolves the page's `send()` (`null` when it returned nothing) |

Every export is optional, but the file must export something. **A file with no `join` export admits everyone** the socket-level checks let through (still subject to `config.roles`). No `leave` → nothing runs on leave. No export named `typing` → `send('typing', …)` is refused with `send_refused`.

Every scanner problem fails the deploy — a file skipped with a warning would leave its channel with no handler row, and a channel with no row is open, so a typo on redeploy could silently drop the gate the channel had before:

| File state | Result |
|---|---|
| No exports at all | **Deploy fails** |
| An export that is neither a lifecycle name nor a valid event name (`not$valid`), or a reserved one (`error`, `connected`, `default`) | **Deploy fails** |
| A path no page could subscribe to (`channels/my orders.js`; `channels/index.js`, which names no channel) | **Deploy fails** |
| Not valid JavaScript | **Deploy fails** |
| Two files mapping to the same channel pattern | **Deploy fails** |
| Unparseable `config` | **Deploy fails** |

### Worked example

```javascript
// channels/rooms/[room].js — gates rooms/<room> and rooms/*
const ROOMS = new Set(['lobby', 'east', 'west']);

export const config = { timeout: 2000 };

// Decide. Runs before admission; a broadcast from here never reaches the joiner.
export async function join({ channel, request }) {
    const { room } = channel.params;
    if (room === '*') return request.roles.includes('moderator');   // "may this user hear every room?"
    return ROOMS.has(room);                                          // exactly true admits
}

// Announce. Runs after admission, so the joiner hears its own arrival.
export async function joined({ channel, request }) {
    if (channel.params.room === '*') return;   // a wildcard listener observes, it is not a member
    await channel.broadcast('presence', { kind: 'joined', user: request.user.username });
}

export async function leave({ channel, request }) {
    if (channel.params.room === '*') return;
    await channel.broadcast('presence', { kind: 'left', user: request.user.username });
}

// Inbound: channel.send('typing') from any admitted page. A moment, not a fact —
// keep it out of the replay buffer.
export async function typing({ channel, request }) {
    await channel.broadcast('typing', { user: request.user.username }, { replay: false });
}

// Inbound with a result: channel.send('comment', { body }) resolves with { id }.
export async function comment({ channel, request, payload, query }) {
    const [saved] = await query(
        'INSERT INTO comments (room, author, body) VALUES ($1, $2, $3) RETURNING *',
        [channel.params.room, request.user.username, payload.body]
    );
    await channel.broadcast('comment', saved);   // everyone in the room, the sender included
    return { id: saved.id };
}
```

### The handler bag

Every export receives the shared handler bag — `context`, `query`, `transaction`, `fetch`, `emit`, `broadcast`, `notify`, `email`, `crypto`, `log`, `env`, `platform` (+ the `markdown` / `extractText` / base64 globals) — **without `respond`** (there is no HTTP response) and without `uploads` / `downloads`, plus three channel members:

| Member | Type | Description |
|---|---|---|
| `channel` | `object` | `channel.name` — the subscribed name (`orders/east`, or `orders/*` for a wildcard); `channel.params` — from `[segment]` files (`{ region: 'east' }`, `{ region: '*' }`); `channel.broadcast(event, payload, options?)` — sugar for `broadcast(channel.name, event, payload, options)` |
| `payload` | any | `null` for `join`, `joined` and `leave`. For an event export, the message the page passed to `send()` (`null` when it passed nothing) |
| `request` | `object` | `request.user` — `{ username, displayName, email, timezone }` of the subscriber, taken from the socket credential, never from the message; `request.roles` — their role IDs. **No `body`, `headers`, `params`, or `query`** — a subscription is not an HTTP request; the route params are on `channel.params` |

`joined`, `leave`, and event exports get the same `channel.params` object that matched at join time. Every run is capped by `min(config.timeout, joinTimeoutMs)` and metered as compute (`route: 'channel:<name>'`). `log()` calls land in the App's Logs tab with `source: 'channel'`, alongside the operator warnings the server writes for refused joins, rate-limited broadcasts, dropped relays, and failed inbound handlers.

### What `join` sees (order of checks)

Socket-layer checks run first, before any App code:

1. The socket is an App socket for **this** App (mismatch → 403).
2. The name matches the grammar (→ 400) and, for `@user/<name>`, the **whole** remainder `<name>` equals the socket's own username (→ 403; `@user/*` is refused here too). No file needed for this check.
3. `maxChannelsPerSocket` and `maxSubscribersPerApp` (→ 429, `rate_limited` on the page).

Then the handler layer:

4. The subscriber can still read the App (a user who lost access → 404, surfaces as `join_refused`).
5. The name resolves against the `CHANNEL` rows. No file matches → **admitted** (open channel), unless the name is a wildcard reaching over a gated channel (→ 403 `app_channel_wildcard_gated`, see [Wildcard subscriptions](#wildcard-subscriptions)). Nothing runs on join or leave for an open channel.
6. `config.roles` set and the subscriber holds none → 403 `app_channel_role_required`.
7. No `join` export → admitted.
8. Compute budget check (→ 402 when exhausted — surfaces as `join_refused`), then `join` runs under `min(config.timeout, joinTimeoutMs)`. `=== true` admits; anything else → 403 `app_channel_join_refused`; timeout → 504 `app_channel_join_timeout` (surfaces as **`disconnected`**, not `join_refused`).
9. nes registers the subscription. A macrotask later, `joined` runs (if exported); its failure is logged and never unwinds the subscription.

### Inbound messages: `send()` on the server side

`channel.send(event, payload)` on the page is a request **over the app socket** to `POST /api/apps/{id}/channels/_send` (never plain HTTP — over HTTP it is 403 `app_channel_socket_required`). The server checks that the socket currently holds the channel, that the event is valid and not reserved, that the covering file exports it, takes a token from the **user's** inbound bucket (`inboundRate`: 10/s, burst 30, per user per App, shared by all of that person's tabs), checks the compute budget, and runs the export. **The subscription is the authorization**: whatever `join` and `config.roles` admitted may send, and nothing else can; there is no separate permission to declare.

| Server answer | When | On the page |
|---|---|---|
| 403 `app_channel_not_subscribed` | The socket does not hold the channel | `send_refused` |
| 404 `app_channel_no_handler` | No export of that name, or an open channel (no file) | `send_refused` |
| 400 `app_channel_reserved_event` / `app_channel_invalid_event` | `error`, `connected`, or not an event name | `send_refused` |
| 429 `app_channel_rate_limited` | The user is over `inboundRate` | `rate_limited` |
| 402 | The App's compute budget is spent | `send_refused` |
| 504 `app_channel_send_timeout` | The export ran past its cap | `disconnected` |
| 500 `app_channel_send_failed` | The export threw | `disconnected` |

A message body over 128 KiB is refused before any handler runs. Each inbound run is recorded as a `SEND` invocation row under `channel:<name>#<event>` and counted as **Sends · 30d** in the Channels tab; a thrown export is audited `send_failed`, a rate-limited one `send_rate_limited`.

## Broadcasting from the server

`broadcast(channel, event, payload, options?)` is in the handler bag of **every** server-side surface: `server/` routes, `server/public/` routes, `webhooks/`, `tools/` and `mcp/` handlers, and `channels/` handlers. It resolves to `{ ok: true, seq }` once the frame is **published** — `seq` is the frame's position in the channel's sequence; it does not wait for delivery and never reports subscriber count (zero subscribers is not an error).

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

**Replay opt-out.** Every published frame is kept for a short while (the last `replay.frames` per channel, 50 by default, for `replay.ttlMs`, 60 s) so a page that drops and reconnects can catch up. A frame that would be stale by the time anyone replayed it — a typing indicator, a cursor position, a heartbeat — should stay out: `broadcast(channel, event, payload, { replay: false })`, or `channel.broadcast(event, payload, { replay: false })` in a channel handler. It still takes a `seq` and reaches every live subscriber. Do this for every "moment" frame, or a busy typing channel pushes the frames that matter out of the window.

`broadcast()` **rejects** (the `await` throws) when the frame can't be published:

| Error message / code | Status | Why |
|---|---|---|
| `app_channel_invalid_name` | 400 | Channel name fails the grammar, exceeds 128 chars, or is a wildcard (`rooms/*`) — pages listen to those, nothing broadcasts to them |
| `app_channel_invalid_event` | 400 | Event name fails the grammar or exceeds 64 chars |
| `app_channel_reserved_event` | 400 | The event is `error` or `connected` |
| `app_channel_invalid_payload` | 400 | Payload can't be `JSON.stringify`'d (BigInt, circular) |
| `app_channel_frame_too_large` | 413 | Serialized payload > `maxFrameBytes` (64 KiB default) |
| `app_channel_rate_limited` | 429 | App over its cluster-wide broadcast token bucket (50/s, burst 200) |
| `app_compute_budget_exhausted` | 402 | The App's compute budget for the period is spent |
| `app_channels_unavailable` | 503 / thrown | The App's type has no channels capability (Magic Report), or the server's pub/sub layer is not up |
| `app_channels_disabled` | 403 | An admin set `app.channels.enabled: false` |
| `app_channel_broadcast_failed` | 503 | The pub/sub layer refused the frame, so it never left the server and nobody received it |

**Wrap `broadcast()` in `try`/`catch` when a lost frame must not fail the request.** A broadcast is a courtesy to open pages, not the record of what happened — the write that preceded it already succeeded. If the App also relays via `channels:`, prefer one `emit()` over `emit()` + a hand `broadcast()` of the same thing (double frames).

## The `@user/<username>` channel

Names beginning with `@user/` are private to one user: a socket may subscribe to `@user/jane` **only** when the App session belongs to `jane`. Everything after `@user/` is the username, **all of it**: `@user/jane/typing` belongs to a user named `jane/typing`, not to `jane`, and `@user/*` names a user called `*`. Anyone else is refused at the socket layer (`join_refused`) before any handler runs. Use it to deliver something to exactly one person's open pages — a long-running job they kicked off, a personal notification.

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

## Wildcard subscriptions

A page can hear a whole family of channels with one subscription by ending the name in a `*` segment: `rooms/*` receives every frame broadcast to a name beneath `rooms/` (`rooms/east`, `rooms/east/typing`), each frame still carrying its concrete `channel`:

```javascript
__INFORMER__.channel('rooms/*').on('message', (msg, frame) => appendTo(frame.channel, msg));
```

- `*` only as the **last** segment, on its own: `rooms/*` is a wildcard; `rooms/*/typing`, `room*`, and `*` alone are invalid; `@user/*` is refused as another user's channel.
- A wildcard is listened to, never broadcast to (`app_channel_invalid_name`) or sent on (`send_refused`, decided on the page). Send on the concrete channel.
- **Gating fails closed.** The wildcard name resolves through `channels/` like any other name, with `*` as the param: `rooms/*` runs `channels/rooms/[room].js` with `channel.params.room === '*'`, and its `join` and `config.roles` decide whether this user may hear every room. A wildcard no file covers is admitted only when no file covers anything beneath the prefix either; if one does (`channels/rooms/lobby.js` with a `join`), the subscribe is refused — 403 `app_channel_wildcard_gated`, `join_refused` on the page, `join_wildcard_gated` in the Logs tab — because admitting it would hand out a gated channel's frames around its gate. So when an App gates channels under a prefix with literal files, add the `[param]` file too if wildcards should be allowed, and have its `join` answer the `'*'` case explicitly.
- A wildcard counts as **one** subscription toward `maxChannelsPerSocket`.
- Replay is tracked per concrete channel: after a reconnect, a wildcard subscription catches up on each channel it had already heard from.

## Subscribing on the page

`__INFORMER__.channel(name, opts?)` is synchronous and cheap; nothing loads or connects until the first `on()`.

```javascript
const orders = __INFORMER__.channel('orders/east');

const off = orders.on('created', (order, frame) => {
    // order === frame.payload; frame is the whole envelope, frame.seq its number
    addRow(order);
});

orders.on('connected', ({ replayed }) => setLive(true));   // after every (re)subscribe, once replay is done

orders.on('error', err => {
    if (err.code === 'replay_gap') refetchOrders();          // missed frames the server no longer buffers
    else console.warn('orders/east', err.code, err.message);
});

const { id } = await orders.send('comment', { body: 'Looks good' });   // runs the `comment` export

off();            // remove this one handler
orders.close();   // unsubscribe the socket path and drop every handler
```

| Method | Description |
|---|---|
| `__INFORMER__.channel(name, opts?)` | Returns a **new** channel object each call (safe under React StrictMode's double mount: close one, create another). Throws synchronously — `code: 'join_refused'` on a malformed name, `code: 'origin_mode_required'` on a path-mode server, `code: 'channels_disabled'` when an admin turned channels off. `opts.since` (a `seq`) replays everything after that frame on the first subscribe (ignored for wildcards) |
| `on(event, fn)` | Registers `fn(payload, frame)` for frames whose `event` matches. Returns an unsubscribe function for that one handler. The first `on()` on the page loads the socket client, fetches `/_socket`, connects, and subscribes; later channels share the connection |
| `on('connected', fn)` | `fn({ replayed })` after every successful subscribe and re-subscribe, once any replay is done. A listener added while the channel is already up hears it once, asynchronously, with `{ replayed: 0 }` |
| `on('error', fn)` | `fn(err)`; `err.code` is one of the codes below. Without an error handler, errors go to `console.warn` |
| `send(event, payload?)` | Sends a message to the App over the socket; resolves with the handler's return value (`null` when it returned nothing). Rejects with `code` `rate_limited`, `send_refused`, or `disconnected`. Phase 1 builds reject every call with `not_supported` |
| `close()` | Unsubscribes and drops all handlers. Idempotent. `on()` after `close()` throws (`code: 'disconnected'`); `send()` after `close()` rejects the same way |

The frame envelope every subscriber receives:

```json
{
  "tenant": "acme",
  "appId": "7d5a9b1e-0c83-4bde-9e2a-3a4b5c6d7e8f",
  "channel": "orders/east",
  "event": "created",
  "payload": { "id": 1042, "customer": "Northwind", "total": 1500 },
  "seq": 57,
  "at": 1724944800000
}
```

An exception inside one handler is logged (`[Informer] channel handler failed`) and does not stop the others. `seq` is contiguous per channel (1, 2, 3 …), so a page holding two frames can tell whether anything was sent between them.

### Sequence numbers and replay

The server keeps the most recent frames of each channel (50 frames, 60 s by default — the `replay` limit), and the page client remembers the last `seq` it delivered on each concrete channel. After every re-subscribe (the socket dropped and came back) the channel reads what the server still buffers past that `seq`, over the same socket, delivers those frames in order **before** any live frame that arrived meanwhile, drops duplicates, then fires `connected` with `{ replayed: <count> }`. A short disconnect, a laptop lid, a phone back from the background: nothing sent in between is lost, as long as it fits the window.

When the window is not enough the channel says so: frames were sent while the page was away and the buffer no longer reaches back to the last `seq` → `error` with `code: 'replay_gap'` and `err.channel` naming the concrete channel. **That is the refetch signal.** Re-fetch that channel's state from a server route; live frames keep arriving. A channel idle long enough for its counter to expire (30 days) restarts at 1 and the page handles it on its own.

To survive a full reload the same way, persist the last `seq` and hand it back:

```javascript
const key = 'orders/east.seq';
const since = Number(sessionStorage.getItem(key)) || undefined;
const orders = __INFORMER__.channel('orders/east', since ? { since } : undefined);
orders.on('created', (order, frame) => { addRow(order); sessionStorage.setItem(key, String(frame.seq)); });
```

Without `since`, a first subscribe starts from now and replays nothing. If a replay read itself fails (refused, or the socket dropped mid-read) the channel reports it as an `error` (`send_refused` or `disconnected`), still comes up on live frames, and `connected` fires with `{ replayed: 0 }`.

### Error codes

| `err.code` | Meaning | What to do |
|---|---|---|
| `join_refused` | Subscribe refused: `join` returned something other than `true`, a `config.roles` miss, malformed name, user can't read the App, compute budget spent, a `@user/` name that belongs to someone else, or a wildcard reaching over a gated channel. (Any 4xx other than 429.) | Don't retry in a loop. Render without the live feed, or tell the user why |
| `rate_limited` | On subscribe: this socket holds `maxChannelsPerSocket` (20) subscriptions, or the App has `maxSubscribersPerApp` (500) on this server. On `send()`: the user is over `inboundRate` (10/s, burst 30). | `close()` channels you no longer need; combine channels (a wildcard is one subscription). A refused subscribe is retried with backoff on its own; a rate-limited `send()` is not — slow down |
| `disconnected` | The socket dropped, couldn't be established (credential refused, client failed to load), **or the App's `join` timed out** (504). Every open channel receives it once per drop. Also the rejection of a `send()` before the channel is up, after `close()`, or whose handler threw or timed out | Nothing required — the shim reconnects on its own and **replays what it missed**. Only act on `replay_gap` |
| `replay_gap` | After a reconnect (or a `since`), frames were sent that the server no longer buffers; `err.channel` names the concrete channel | Re-fetch that channel's state from a server route. Live frames continue |
| `send_refused` | The server declined a `send()`: not subscribed, no export of that name, a reserved/invalid event, or compute budget spent. Also returned without a round trip for a reserved/invalid event name or a wildcard channel | Fix the event name or the handler file; do not retry the same message |
| `origin_mode_required` | Thrown by `channel()` itself on a path-mode server | Check `platform.originMode` first and fall back to polling a server route |
| `channels_disabled` | Thrown by `channel()` itself when an admin turned channels off | Same fallback. Nothing the App does will change it |
| `not_supported` | Returned by `send()` on a phase 1 build | Post to a server route and let it `broadcast()` the result back; the server predates I5-13027 |

### Reconnect behaviour

Informer's own nes auto-reconnect is **off** (it would replay the short-lived credential). Instead the shim:

- Reports `disconnected` once to every open channel on a drop.
- Retries on its own with **bounded, jittered backoff** — 1 s doubling to a 30 s cap (+0–50 % jitter) — minting a fresh `/_socket` credential each attempt, and resets the delay once a connection lands.
- Reconnects **immediately when the page becomes visible** again (`visibilitychange`), so a phone back from sleep or a laptop lid recovers without help.
- Also reconnects on the next `channel()` or `on()` call if one comes first.
- Re-subscribes every open channel after reconnecting — `join` (and `joined`) run again for gated ones — then replays each channel from its last `seq` and fires `connected`.
- Stops retrying when no channel holds a handler (all closed).

A listen-only page therefore recovers by itself, frames included. The App's only jobs are to act on `replay_gap` and to wait for `connected` before the first `send()`.

### React: the hook and the store

Two patterns that hold up. First, a hook that reads its handlers through a ref, so callers can pass fresh closures every render without resubscribing, and that returns `send`:

```jsx
import { useCallback, useEffect, useRef } from 'react';

export function useChannel(name, handlers, { enabled = true, since } = {}) {
    const ref = useRef(handlers);
    useEffect(() => { ref.current = handlers; });
    const channelRef = useRef(null);
    const events = Object.keys(handlers).filter(e => e !== 'error' && e !== 'connected').sort().join(',');

    useEffect(() => {
        if (!enabled || !name || !window.__INFORMER__?.platform?.originMode) return undefined;
        const channel = window.__INFORMER__.channel(name, since === undefined ? undefined : { since });
        channelRef.current = channel;
        for (const event of events.split(',').filter(Boolean)) {
            channel.on(event, (payload, frame) => ref.current[event]?.(payload, frame));
        }
        channel.on('connected', info => ref.current.connected?.(info));
        channel.on('error', err => ref.current.error?.(err));
        return () => { channelRef.current = null; channel.close(); };
    }, [name, events, enabled, since]);

    const send = useCallback((event, payload) => {
        const channel = channelRef.current;
        if (!channel) return Promise.reject(Object.assign(new Error('The channel is not open'), { code: 'disconnected' }));
        return channel.send(event, payload);
    }, []);

    return { send };
}
```

```jsx
// Load state from a route first, let the channel keep it fresh, refetch only on a gap.
export function OrderFeed({ region }) {
    const qc = useQueryClient();
    const orders = useQuery({ queryKey: ['orders', region], queryFn: () => api(`/api/orders?region=${region}`) });
    const { send } = useChannel(`orders/${region}`, {
        created: order => qc.setQueryData(['orders', region], (cur = []) => cur.some(o => o.id === order.id) ? cur : [order, ...cur]),
        error: err => { if (err.code === 'replay_gap') qc.invalidateQueries({ queryKey: ['orders', region] }); },
    });
    // ...
}
```

Second, when several components subscribe, one **store** every channel reports into (`useSyncExternalStore`) is the cleanest way to drive a header status pill and a frame log: record every frame, every `connected`, and every error there, and derive "live / reconnecting / unavailable" from it. Render the app **without** `React.StrictMode` (or accept that its double mount opens and closes every channel twice on load); `channel()` returns a fresh object per call, so the second mount works either way. Dedupe on `id` when a mutation's response and the relayed frame both arrive.

## `broadcast()` vs `emit()`

| | `emit(event, payload)` | `broadcast(channel, event, payload, options?)` |
|---|---|---|
| Writes a row | Yes — an app event agents process and you can inspect later | No |
| Delivery | Durable: retried, dead-lettered, visible in run history | **At most once** to whoever is subscribed; a page reconnecting inside the replay window (60 s, 50 frames by default) catches up, past it it is told there was a gap |
| Audience | Agents (and, via `channels:`, subscribers) | Open pages |
| Ordering | Processed asynchronously | Contiguous `seq` per channel; each frame delivered once |
| Cost | A DB write per call | A Redis publish per call, rate-limited per App |
| In dev | Console log only (+ runs the relay) | Real frames over Vite's dev socket |

**Rule of thumb: if you'd be upset it was lost, `emit`; if it'd be stale in a second anyway, `broadcast`** — and if it'd be stale in a second, also `{ replay: false }`. An approved order is a fact — `emit('order_approved')` and let the `channels:` relay tell the dashboards. "Jane is typing" is a moment — `send('typing')` from the page, `channel.broadcast('typing', …, { replay: false })` from the handler, and forget it.

## Limits

Server defaults under `app.channels` (`config-factory.js`). An admin can change them; an App cannot.

| Setting | Default | Enforced when |
|---|---|---|
| `enabled` | `true` | `false` → every `broadcast()` rejects with `app_channels_disabled`, `channel()` throws `channels_disabled` |
| `maxSubscribersPerApp` | 500 | Subscriptions per App, counted **cluster-wide**. Next subscribe → `rate_limited` |
| `maxChannelsPerSocket` | 20 | Subscriptions one page's socket may hold; a wildcard is one. Next `on()` on a new channel → `rate_limited` |
| `maxFrameBytes` | 65536 (64 KiB) | Serialized **payload** size per broadcast; larger → `app_channel_frame_too_large` |
| `broadcastRate` | `{ perSecond: 50, burst: 200 }` | Per-App token bucket shared across the cluster; exceeding → `app_channel_rate_limited`. Typing forwarded through a handler counts against it — throttle typing on the page (one `send()` per person every 2 s or so) |
| `inboundRate` | `{ perSecond: 10, burst: 30 }` | Per-user, per-App bucket for `send()`; exceeding → the page's `send()` rejects `rate_limited` |
| `replay` | `{ frames: 50, ttlMs: 60000 }` | Frames kept per channel for reconnecting pages, and for how long |
| `joinTimeoutMs` | 5000 | Hard ceiling for every channel handler run (`join`, `joined`, `leave`, event exports), whatever `config.timeout` says |

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
| `join_wildcard_gated` | A wildcard subscribe reached over a gated channel and no file covered the wildcard itself |
| `joined_failed` | `joined` threw or timed out; the subscriptions stand |
| `send_rate_limited` | One user's `send()` calls exceeded `inboundRate` |
| `send_failed` | An event export threw or timed out |
| `subscriber_limit` | App at `maxSubscribersPerApp` cluster-wide |
| `socket_limit` | One page over `maxChannelsPerSocket` |
| `broadcast_rate_limited` | App over `broadcastRate` |
| `broadcast_failed` | Pub/sub refused the frame; nobody received it |
| `budget_exhausted` | App compute budget spent |
| `budget_check_failed` | Budget unreadable, so the frame was let through rather than lost |
| `relay_dropped` | An `emit()` could not be relayed to its channel |

The **Channels** tab of the same panel carries the live counters (subscribers now; broadcasts / deliveries / rate-limited over 60m; joins / refusals / leaves / sends over 30d) and the server's limits, including `inboundRate` and `replay` on phase 2 servers.

## Local development

`npm run dev` with `@entrinsik/vite-plugin-informer` **2.11.0+** runs the whole loop with **no server socket**:

- `broadcast()` is in the dev handler bag for server routes, agent tools, and channel handlers — same name/event/payload/reserved-event/frame-size validation and the same error codes as production, resolving `{ ok: true, seq }` with a per-channel `seq`, honoring `{ replay: false }`. Every call is logged to the terminal (`[app-channel] broadcast(...)`).
- `emit()` runs the `channels:` relay locally (no app-event row in dev), so a page subscribed to a relayed channel sees the frame (`[app-channel] relayed emit("...") → channel "..."`).
- **`channels/` handlers run locally.** A subscribe runs the covering file's `join` (with `config.roles` checked against `mock.roles`), then `joined`; an unsubscribe runs `leave`; `send()` runs the event-named export and resolves with its return value, metered per user at the production default. `request.user` is `mock.user`, `request.roles` is `mock.roles`. The `@user/` ownership check and wildcard gating behave as on the server. The terminal shows `[app-channel] join("rooms/lobby") admitted|refused (<code>)` and `send("rooms/lobby", "typing") handled`.
- `__INFORMER__.channel()` on the dev page has the production surface: `on()`, `on('connected')`, `send()`, `close()`, `since`, replay after a dropped dev socket, `replay_gap`, wildcards. Frames ride **Vite's own dev WebSocket** (`import.meta.hot`) — no second socket, nothing to configure. `frame.tenant` is `'dev'`, `frame.appId` is the mocked App id.
- `__INFORMER__.platform.originMode` is `true` in dev.
- `informer.yaml` and `channels/` are validated at dev-server boot: an entry without `on`, a bad name, a stray or reserved export, two files on one channel print as `[informer] …` so you see at boot what the deploy would 400 on.
- `__INFORMER__.user` defaults to `{ username: 'dev', displayName: 'Local Developer' }`; override with `mock.user`.

What dev does **not** do: no compute budget, no per-App broadcast rate, no `enabled` switch, no subscriber or per-socket caps — `rate_limited` on subscribe, `app_channels_disabled`, and `app_channels_unavailable` never happen. Every page is the same mocked user, so two tabs cannot stand in for two people (presence and typing from "someone else" need a deployed App or a second checkout with a different `mock.user`). The mock only works on a page served by `vite dev` with its HMR socket available; without it, the first `on()` reports `disconnected`. A Vite HMR drop surfaces as `disconnected` too — and then replays, like production.

**Plugin 2.10.0 and earlier** never ran `channels/` handlers (every channel was open in dev, `send()` rejected `not_supported`), and its dev `respond()` answered a plain 200 wrapping the descriptor instead of the early status — a route that returns `202` via `respond()` looked wrong only in dev. Upgrade rather than work around it.

**Validate gating on a deployed App too.** "Works in dev, `join_refused` after deploy" means the real viewer's roles differ from `mock.roles`, or they cannot open the App; dev also has no compute budget and no broadcast rate limit.

## Gotchas

- **You never see your own join from `join`.** It runs before admission. Decide in `join`, announce in `joined`. Test presence with two browsers or two checkouts, not two tabs of the dev server.
- **`channels:` is relays only.** It is not a registry and not access control; `on` is required. An open channel needs no entry, and a gated one needs a file.
- **Check `platform.originMode` before `channel()`,** rather than catching `origin_mode_required` after the page has laid itself out.
- **Wait for `connected` before the first `send()`.** A send made before the subscribe lands fails (`disconnected` while connecting, `send_refused` once up but not yet admitted).
- **Refetch only on `replay_gap`.** A plain `disconnected` is followed by a reconnect and a replay; re-fetching on every drop throws away what replay would have restored for free.
- **Opt "moment" frames out of replay.** `{ replay: false }` on typing, cursors, heartbeats; otherwise they crowd the 50-frame window and the frame that mattered rolls off.
- **Throttle typing on the page.** Every `send('typing')` costs one inbound token per user and, forwarded, one broadcast token per App. One per person every couple of seconds is plenty.
- **Don't broadcast, send, or export `error` or `connected`.** Reserved; `default` exports are refused too.
- **A `join` timeout surfaces as `disconnected`, not `join_refused`.** Make `join` faster or raise `config.timeout` (≤ `joinTimeoutMs`).
- **`join` must return exactly `true`.** `return row`, `return 1`, `return !!row || undefined` — anything but the boolean `true` refuses.
- **Frames over 64 KiB are rejected, not truncated.** Broadcast the changed row (or just its id and let the page fetch), never a table.
- **Subscribe to the exact name the server broadcasts to, or to a wildcard above it.** `orders/east` is not `orders`; `orders/*` hears both `orders/east` and `orders/east/rush`, never `orders` itself.
- **Gating a prefix with literal files blocks wildcards over it** until a `[param]` file covers the wildcard and its `join` answers the `'*'` case.
- **`channel.params`, not `request.params`.** A channel handler's `request` is `{ user, roles }` only; route params live on `channel.params`, and there is no `respond`.
- **`seq` restarts** when a channel's counter key expires (30 days idle) or Redis is flushed; the page copes per channel, but a flush restarts every channel at once.
- **Older skill/docs examples use `/api/_server/...`** for route calls; the bare `/api/...` spelling is current (see `server-routes.md`). Both reach the same route.
- **`maxSubscribersPerApp` fails open.** If redis is unreachable the cap admits everyone (with a server warning) rather than refusing all subscribes.

## Project structure with channels

```
my-app/
  channels/
    rooms/
      [room].js           → rooms/:room and rooms/* (config, join, joined, leave; `typing` and `comment` answer send())
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
  informer.yaml           → channels: relay block (each entry needs `on`; + events:, agents:)
  index.html
  package.json
```

`npm run deploy` uploads `channels/` alongside `server/` and `webhooks/`, then prints "Registered N channel handler(s)" and "Relaying events to N channel(s)" from the deploy result (`channelHandlers`, `channels`).
