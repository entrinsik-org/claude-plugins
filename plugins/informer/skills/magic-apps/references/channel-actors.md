# Channel Actors (One Live Sandbox per Channel)

> **Load this reference when:** a channel needs state that survives between messages, or something that happens on a clock rather than on a message: a multiplayer game loop, a shared whiteboard or document, a presence roster, an auction or a countdown the server owns, a "server-authoritative" anything. Covers a `channels/` file with `config.actor`, the `start` / `tick` / `stop` / `snapshot` exports, `restored`, `request.member`, calls running one at a time, what an actor's bag has and lacks, broadcasting from an actor, why an actor stops, snapshots across redeploys and dead servers, the cluster, billing (`ACTOR` / `ACTOR_IDLE`), the `app.channels.actors` limits, the page's `unavailable` code, `__INFORMER__.serverNow()`, and the dev emulation. Also load it for "tick", "game", "keep it in memory", "stateful channel", "30 times a second".
>
> **Not in this file:** channels themselves (names, `broadcast()`, the `channels:` relay, `join` / `joined` / `leave` / event exports, `__INFORMER__.channel()`, replay, the full page error table) — see `channels.md`, which this builds on. The rest of the handler bag — see `server-routes.md`. Durable events for agents (`emit()`) — see `agents.md`.
>
> **Availability:** Informer **2026.1.4+** (I5-13088), on an origin-mode server like every channel. Feature-detect `platform?.capabilities?.channelActors` (`window.__INFORMER__.platform` on the page, `platform` in any handler): it is `false` on a Magic Report, on a server whose admin set `app.channels.actors.enabled: false`, and absent on a build that predates actors. **Where it is not `true`, the same file still deploys and runs as an ordinary channel handler** — each export in a fresh sandbox, nothing kept between messages, `start` / `tick` / `stop` / `snapshot` never called by the server (and refused if a page sends them) — so read the flag on the page and fall back (poll a route, or run the simulation on the page) rather than ship a game that silently never ticks. Dev emulation needs `@entrinsik/vite-plugin-informer` **2.13.0+**; on 2.12.0 and earlier `npm run dev` runs the file as an ordinary handler and `tick` is never called.

A `channels/` file normally runs every export in a fresh sandbox: each join, leave and `send()` starts from nothing. A file that declares `config.actor` gets **one long-lived sandbox per concrete channel** instead (`match/42` and `match/43` are two actors), kept while the channel has subscribers. Module-level variables are the channel's state; a `send()` is a call into the running sandbox rather than a new one (no bundle read, no isolate, no audit rows per message); and the server can call `tick()` at a fixed rate. One server runs each actor; pages on any server reach it.

## When to reach for an actor

| You need | Use |
|---|---|
| Push a fact to open pages when server code changes something | `broadcast()` from the route, or the `channels:` relay — `channels.md` |
| Gate who hears a channel, react to joins/leaves, take a message and write it down | An ordinary `channels/` file — `channels.md` |
| State held **between** messages (positions, a roster, a board), updated by every page's inputs | An actor |
| Something that happens on a **clock** (a game step, a countdown, a periodic state stream) | An actor with `config.actor.tick` — handlers have no `setTimeout` / `setInterval` |
| Anything that must survive a server restart | The workspace database (`query()`), from the actor or a route; a [snapshot](#snapshots) only carries state across a redeploy or a restart, it is not a record |

An actor is memory, not storage: keep what matters in the database and what is only *live* in the actor.

## A minimal actor

```javascript
// channels/match/[id].js
export const config = { actor: { tick: 30, idleMs: 30000, snapshotMs: 5000 } };

let state;                                                // lives as long as the actor

export function start({ channel, restored }) {            // once, before anything else
    state = restored ?? { id: channel.params.id, players: {}, ball: { x: 0, y: 0, dx: 1, dy: 1 } };
}

export function join({ request }) {                       // exactly true admits; runs for every connection
    return Object.keys(state.players).length < 4 || request.member in state.players;
}

export function joined({ request, channel }) {            // idempotent: a reconnect runs it again
    state.players[request.member] ??= { name: request.user.displayName, y: 0, dy: 0, score: 0 };
    return channel.broadcast('roster', state.players);
}

export function leave({ request }) {                      // once this page's last connection is gone
    delete state.players[request.member];
}

export function input({ payload, request }) {             // page: match.send('input', { dy: 1 })
    const me = state.players[request.member];
    if (me) me.dy = Math.max(-1, Math.min(1, Number(payload?.dy) || 0));
}

export async function tick({ channel, dt, frame }) {      // 30 times a second
    step(state, dt);
    await channel.broadcast('state', view(state), { replay: false });   // a stream of moments: keep it out of replay
}

export function snapshot() {                              // what a restart keeps
    return state;
}

export async function stop({ reason, query }) {           // on the way out (not after a hang or crash)
    if (reason === 'idle') {
        await query('INSERT INTO results (match, players) VALUES ($1, $2)', [state.id, JSON.stringify(state.players)]);
    }
}
```

```javascript
// the page (step() and view() above are the app's own game code)
const platform = window.__INFORMER__.platform;
const live = platform?.capabilities?.channels === true && platform?.originMode === true
    && platform?.capabilities?.channelActors === true;

if (!live) {
    showUnavailable();   // or run the simulation on the page
} else {
    const match = __INFORMER__.channel(`match/${id}`);
    let ready = false;
    match.on('state', render);
    match.on('roster', renderRoster);
    match.on('connected', () => { ready = true; });
    match.on('error', err => {
        if (err.code === 'unavailable') showReconnecting();   // its server went away; the page resubscribes on its own
    });
    window.addEventListener('keydown', e => ready && match.send('input', { dy: e.key === 'ArrowUp' ? -1 : 1 }));
}
```

## `config.actor`

| Key | Default | Meaning |
|---|---|---|
| `tick` | none (no tick) | Calls per second to `tick({ dt, frame })`, clamped to `actors.maxTickHz` (60) |
| `idleMs` | 30000 | How long the actor outlives its last subscriber, clamped to `actors.maxIdleMs` (300000). `0` stops it the moment the last page leaves |
| `memoryMb` | 32 | The sandbox heap, clamped to `actors.maxMemoryMb` (128). Idle time is billed by it — ask for what you use |
| `snapshotMs` | 5000 | How often `snapshot()` is called, clamped between 1000 and `actors.maxSnapshotMs` (60000) |

`config.timeout` still applies: it may **lower** the per-call budget below `actors.callTimeoutMs` (1000), never raise it. `config.roles` gates joins as on any channel file.

The deploy refuses (400, naming the file) a `config.actor` that is not an object; an unknown key (`tickRate`, `tickk` — a typo cannot pass silently); a number below its floor (`tick` < 0, `idleMs` < 0, `memoryMb` < 8, `snapshotMs` < 1000); a `tick` rate with no `tick` export; a `tick` export with no rate (a page cannot send it on an actor channel, so it would never run); and a `snapshotMs` with no `snapshot` export. Out-of-range values that are merely too large are clamped, not refused.

## Exports and the order calls run in

| Export | Called by | Receives (besides the bag) |
|---|---|---|
| `start` | The server, once, before anything else | `restored` — the kept snapshot, or `undefined` |
| `join` | Each connection's subscribe (and a send from a page this actor has not admitted) | `request`. Must return exactly `true` |
| `joined` | Each connection, after admission | `request` |
| `leave` | Once, when a page's last connection is gone | `request` (the one it joined with) |
| `<event>` | A page's `send(event, payload)` | `payload`, `request`; the return value answers the `send()` |
| `tick` | The server, `config.actor.tick` times a second | `dt` (seconds since the last tick), `frame` (its number, from 1) |
| `snapshot` | The server, every `snapshotMs`, and before a stop it should come back from | — ; return plain JSON |
| `stop` | The server, on the way out (not after a hang or a crash) | `reason` — `idle`, `lifetime`, `redeploy`, `shutdown`, `budget`, `lease_lost`, `meter_failed` |

`start`, `tick`, `snapshot` and `stop` are the actor's own: a page `send()` naming one of them (or `config`, `join`, `joined`, `leave`) is refused as `send_refused` without running anything.

**One call at a time, in arrival order.** The handler never sees two messages interleave, so plain module variables need no locking. Page calls (joins, leaves, sends) wait in a queue behind the running one: at most `actors.maxQueue` (64) of them — past that a `send()` is refused as `unavailable` (503 `app_channel_actor_busy`, audited `actor_busy`) — and one that waited longer than its caller would (`2 × actors.callTimeoutMs + 1 s`) is dropped **unrun** (504, `handler_failed`). The actor's own calls always go through. **A tick that comes due while the actor is busy is skipped, not queued**: a slow tick costs a frame, never a backlog, and deadlines stay fixed from the first tick, so one slow tick does not push the rest back. `dt` reports the real gap; step your simulation by it.

## Members and `request.member`

`request.member` names the **page** (one browser tab): the same for every connection that page makes, reconnects included, different for another tab even of the same person. It is an opaque string; key per-player state by it, never by `request.user.username` (two tabs of one person are two players). Ordinary channel handlers get it too (`channels.md`).

- `join` and `joined` run for **every connection**, so a page that reconnects runs them again: make both idempotent (`??=`, "already here?").
- `leave` runs **once**, when the page's last connection goes — including a page whose server died and never said goodbye (the owner drops that server's members once its heartbeat lapses and runs their `leave`). A reconnect is never a departure followed by an arrival.
- **An actor never holds a member its own `join` did not admit.** A page whose actor restarted (idle, redeploy, crash, lifetime) is put through `join` again by its next `send()`, without the page doing anything; a `join` that refuses answers that `send()` with `send_refused`.
- A `join` that refuses the only page on a fresh actor stops it within a second, so refused joins do not hold the App's actor slots.
- A wildcard cannot join an actor: `match/*` names a family of channels and an actor is one of them (403 `app_channel_actor_wildcard` → `join_refused`).
- Joins on an actor channel spend a token from the same per-user bucket as its sends (`actors.inboundRate`), since a join may start an actor (audited `join_rate_limited`).

## The actor's bag

The channel bag (`channel`, `payload`, `request`, `query`, `transaction`, `emit`, `broadcast`, `notify`, `email`, `crypto`, `log`, `env`, `platform`, `markdown`, `extractText`) **without `fetch` and without typed `context` dependencies**: those run with one user's credentials, and an actor serves every subscriber. `fetch()` throws a named error (`fetch() is not available in a channel actor…`); `context` is empty. Call a `server/` route from the page for anything that needs the viewer's identity.

- `request` is the sender for `join`, `joined`, `leave` and events, and **`null`** for `start`, `tick`, `stop` and `snapshot`.
- `query()` and `transaction()` work. The actor opens a workspace connection on the first query and closes it after 10 s without one, so an actor waiting between ticks holds no connection.
- `log()` lands in the App's Logs tab (`source: 'channel'`, with the channel name). A throwing export is logged once per export per metering window, not 60 times a second.
- No `setTimeout` / `setInterval` — `tick` is the only clock. Work an export starts and does not await keeps running, is billed, and past `callTimeoutMs` of such CPU in one window stops the actor as hung.

## Broadcasting from an actor

A broadcast to the actor's **own channel** is validated and rate-limited on the spot, then published in order off the call path, so a tick streaming state never waits on Redis. It answers once queued: `{ ok: true, queued: true, seq: null }` (the frame still takes the channel's next `seq`; replay and `replay_gap` work as usual). It draws on the actor's own allowance, `actors.broadcastRate` (120/s, burst 240), not the App's; past it the `await` throws `app_channel_rate_limited` inside the actor. A broadcast to **any other channel** goes the way every handler's does (`{ ok: true, seq }`, the App's `broadcastRate`).

Send state streams with `{ replay: false }`: a position from half a second ago is noise to a reconnecting page, and 30 frames a second would push everything else out of the 50-frame replay window. Send the diff or a compact view, not the whole state, and keep each frame under 64 KiB.

## Why an actor stops

The first join (or a `send()` after a restart) starts one on the current deploy. It stops:

| Reason | When | `stop()` runs | Snapshot | Request-list row |
|---|---|---|---|---|
| `idle` | `idleMs` after its last page left | yes | dropped | 200 |
| `lifetime` | after `actors.maxLifetimeMs` (4 h) | yes | kept | 200 |
| `redeploy` | the App deployed (after the deploy commits), here and on every server | yes | kept, and restarted at once if it has members | 200 |
| `shutdown` | its server is stopping | yes | kept | 200 |
| `budget` | the App's compute budget is spent (checked every `meterEveryMs`) | yes | dropped | 402 |
| `meter_failed` | none of its compute could be recorded for a minute | yes | kept | 500 |
| `lease_lost` | another server holds its channel now | yes | untouched (the other one's) | 500 |
| `timeout` | a call ran past `callTimeoutMs`, or unawaited work used that much CPU between calls | **no** | dropped | 500 |
| `crashed` | the sandbox died (out of memory, for one) | **no** | dropped | 500 |

A graceful stop lets the call in flight finish, then runs `stop({ reason })` within `actors.stopTimeoutMs` (5 s); page calls still waiting are refused and retried on the next actor, and the next actor for the channel starts only once this one has stopped. A hung call answers its caller 504 (`handler_failed`); a result over `actors.maxResultBytes` (128 KB of JSON) is refused unparsed (413, `send_refused`). Every stop writes the reason to the Logs tab, and one request-list row per actor run (method `ACTOR`, path `channel:<name>`, user `_actor`) shows how long it lived and why it ended.

## Snapshots

An actor's state lives in its sandbox's memory. Export `snapshot()` to carry it across a redeploy, a shutdown or a lost server: return what a new actor needs to carry on (plain JSON, at most `actors.maxSnapshotBytes`, 256 KB) and the next `start()` receives it as `restored`.

- Taken every `snapshotMs`, between calls like any call (billed as compute), and once more before a `lifetime`, `redeploy`, `shutdown` or `meter_failed` stop.
- **Redeploy:** the actor keeps a snapshot, runs `stop({ reason: 'redeploy' })`, and — if it exports `snapshot` and has members — starts again at once on the new code from it. Its pages stay subscribed and are carried in, each through the new code's `config.roles` and `join`; one the new code refuses is out until it subscribes again. An actor without `snapshot()` just stops; the next join or `send()` starts it fresh on the new code.
- **A dead server:** the actor that takes over starts from the last periodic snapshot, at most `snapshotMs` old.
- Kept for 15 minutes (`actors.snapshotTtlMs`). An oversize snapshot is not kept (the last one that fit stands) and is logged at warn.
- **A new deploy's `start()` receives the old deploy's state.** Version it (`{ v: 2, … }`) and read it defensively; if `start()` throws with a restored state, the snapshot is dropped so the start after it is fresh.
- After a restart, pages still subscribed `join` again, so `join`/`joined` can see a member the restored state already holds — key by `request.member`.

## Across a cluster

Each actor runs on exactly one server, named by a Redis lease (`actors.leaseMs`, 15 s, renewed while it lives). The first join starts it on the server that join reached; joins, leaves and sends arriving at any other server are carried to it over Redis and answered back (about one round trip each way), and its frames reach every server's pages like any broadcast.

A server that dies loses its actors. Until the lease lapses, a subscribe or `send()` for one answers **`unavailable`** (409 `app_channel_actor_unreachable`); the page resubscribes on its own with backoff, and a `send()` should be retried shortly (one refused this way may still have reached the actor if its server stopped mid-call). After that a new actor starts by itself, wherever pages are still subscribed — a channel whose pages only listen does not stay silent — from the last snapshot if the file keeps them. Actors a live server stopped on purpose (idle, budget, redeploy) stay stopped until a page joins or sends. A leave that could not reach its actor's server is retried on each heartbeat, so an actor does not keep a ghost member and never go idle.

## Billing

The time an actor **works** (inside calls, or the sandbox's own CPU clock when work ran on after a call returned, whichever is more) is app compute at the per-second rate, like any handler's — the Usage tab shows it as method `ACTOR`. The time it **waits** between calls costs only the memory it holds, billed by the GB-hour of `memoryMb` plus the isolate's overhead (`actors.idleCreditsPerGbHour`, 0.25) — method `ACTOR_IDLE`. A 32 MB actor waiting an hour costs about 0.009 credits. Both are recorded every `meterEveryMs` (10 s), which is also when the budget is checked; an App out of compute has its actors stopped (`budget`), and a new one refuses to start with 402 (`budget_exhausted` on the page). A tick is work: 60 ticks a second of real computation is 60 small calls a second, billed.

## Limits

Server settings under `app.channels.actors` (`config-factory.js`); an administrator can change them, an App cannot.

| Setting | Default | Meaning |
|---|---|---|
| `enabled` | `true` | `false` → `capabilities.channelActors` is `false` and actor files run as ordinary handlers |
| `maxPerApp` / `maxPerServer` | 20 / 200 | Live actors per App **across the cluster**, and in all on one server. The subscribe that would start one more → `rate_limited` (audited `actor_limit`) |
| `maxTickHz` | 60 | Ceiling on `config.actor.tick` |
| `memoryMb` / `maxMemoryMb` | 32 / 128 | Default heap, and the most `config.actor.memoryMb` may ask for |
| `idleMs` / `maxIdleMs` | 30000 / 300000 | Default idle stop, and its ceiling |
| `maxLifetimeMs` | 14400000 (4 h) | Stopped (gracefully, snapshot kept) after this long |
| `callTimeoutMs` | 1000 | One call; past it the actor is stopped as hung |
| `stopTimeoutMs` | 5000 | How long `stop()` may run |
| `maxQueue` | 64 | Page calls waiting behind the running one |
| `maxResultBytes` | 131072 | What one call may answer, in JSON characters |
| `inboundRate` | 30/s, burst 60 | The per-user bucket for joins and sends on actor channels, apart from the channel `inboundRate` |
| `broadcastRate` | 120/s, burst 240 | Each actor's allowance for broadcasts to its own channel |
| `snapshotMs` / `maxSnapshotMs` | 5000 / 60000 | Default snapshot cadence, and its ceiling |
| `snapshotTtlMs` / `maxSnapshotBytes` | 900000 / 262144 | How long a snapshot is kept, and its size ceiling |
| `idleCreditsPerGbHour` | 0.25 | What waiting costs |
| `meterEveryMs` | 10000 | How often compute is recorded and the budget checked |
| `leaseMs` | 15000 | The lease naming the server that runs an actor |

## On the page

Nothing about subscribing changes: `__INFORMER__.channel(name).on(...)` / `.send(...)` as in `channels.md`. What is new for actors:

| Server answer | On a subscribe | On a `send()` |
|---|---|---|
| 409 `app_channel_actor_unreachable` (its server went away) | `unavailable` — retried with backoff | `unavailable` — retry shortly |
| 503 `app_channel_actor_busy` (queue full) | `handler_failed` (not retried) | `unavailable` — retry shortly |
| 504 `app_channel_actor_timeout` (hung, or dropped unrun) | `handler_failed` | `handler_failed` |
| 413 `app_channel_result_too_large` | — | `send_refused` |
| 403 `app_channel_join_refused` | `join_refused` | `send_refused` (the restarted actor's `join` refused this page) |
| 429 — the App is at its actor cap (`app_channel_actor_limit`), or the user is past `actors.inboundRate` | `rate_limited` | `rate_limited` |
| 402 | `budget_exhausted` | `budget_exhausted` |

**`__INFORMER__.serverNow()`** (also `channel.serverNow()`, every channel page on a 2026.1.4+ server) is the server's clock in ms as closely as the page can tell: `Date.now()` corrected by the quickest socket round trip, sampled three times when the socket comes up and again from every `send()` reply. Use it wherever pages must agree on a moment — a countdown the actor starts, a race clock, a deadline — by broadcasting the server's `Date.now()` and comparing against `serverNow()` on the page. Before the socket is up it is the page's own clock.

## What the operator sees

- **Logs tab, `channel` source:** every stop with its reason ("Stopped: …"), `stop() did not finish`, an oversize snapshot, the first throw of each export per window, and the counted codes `actor_limit`, `actor_busy`, `join_rate_limited` alongside the ordinary channel codes (`channels.md`).
- **Channels tab / `GET /api/apps/{id}/channels`:** each handler row carries its `actor` config (or `null`), and `actors` lists the actors running on the server that answered: channel, state, members, pages, tick rate, ticks run and skipped, calls, snapshots, whether it was restored, when it started.
- **Usage:** `ACTOR` and `ACTOR_IDLE` app-compute rows; **request list:** one `ACTOR` row per run.

## Local development

`npm run dev` with plugin **2.13.0+** runs actors in the dev server: one module instance per concrete channel, calls one at a time, `tick()` on a real timer, the idle stop, `request.member` per page, `join` on every admission (including a send after a restart), and `config.actor` checked at load with the deploy's own wording. A page that closes or reloads leaves its channels. `snapshot()` is kept in memory: editing a file under `channels/`, `shared/`, `lib/` or `server/` restarts the running actors that keep snapshots on the new code from them, each page admitted again by the new `join` — a game in progress survives the edit. `serverNow()` is the page's own clock (the same machine). Actors stop when the dev server closes.

What dev does not have: the cluster and leases (`unavailable` never happens), billing and the budget stop, the actor cap, the queue limit, and the broadcast limits. Every page is the same `mock.user`, but each tab is its own `request.member`, so two tabs *can* stand in for two players.

## Gotchas

- **Read `capabilities.channelActors` on the page.** Without it the same file runs per message on a server without actors: every `send()` sees fresh module state and nothing ticks.
- **Key everything by `request.member`, and make `join` / `joined` idempotent.** Reconnects, restarts and carried members all run them again.
- **`tick` is skipped when the actor is busy.** Step by `dt`, keep ticks cheap, and do slow work (a query per tick) rarely or outside the loop.
- **Await what you start.** An un-awaited promise loop keeps running between calls, is billed, and gets the actor stopped as hung.
- **`request` is `null` in `start` / `tick` / `stop` / `snapshot`.** There is no user on a clock.
- **No `fetch`, no typed `context`.** Put identity-bearing work in a `server/` route the page calls.
- **Stream state with `{ replay: false }`,** and send deltas, not the world.
- **Snapshots cross deploys.** Version their shape; a `start()` that throws on an old shape costs the snapshot, not the actor.
- **Persist results yourself.** `stop()` does not run after a hang or crash, and an `idle` or `budget` stop drops the snapshot: write what must outlive the match to the database as it happens, not only in `stop()`.
- **`memoryMb` is billed while idle.** 16–32 MB is plenty for most games.
