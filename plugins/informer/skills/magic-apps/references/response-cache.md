# Response Caching (`config.cache` on GET Routes)

> **Load this reference when:** a `GET` route is read far more often than its data changes (a dashboard that polls, a lookup or catalog every page loads, settings, a summary), the user asks to make a route faster or cheaper, or mentions "cache", "ETag", "304", "stop re-running the query", "CDN" or a public App under heavy anonymous traffic. Covers `config.cache` (`true` | `{ ttl, vary, tables, edge }`), what changes the validator and what it can't see, which responses are never tagged, the public-route store and overload relief, putting a CDN in front, how to verify caching, the deploy warning for a bad declaration, and the `app.responseCache` / `app.heldFiles` server settings.
>
> **Not in this file:** the rest of the handler bag and `config.timeout` / `config.roles` / `config.api` — see `server-routes.md`. Public serving itself (`public: true`, `server/public/**`, accounts) — see `accounts-and-login.md`. Client-side freshness after a mutation (TanStack Query invalidation) — see `ui-quality.md`; server caching does not replace it.
>
> **Availability:** Informer **2026.2.0+** (I5-13259). **Older servers ignore `config.cache`**: the route deploys and runs uncached, with no error, so the declaration is safe to ship to any target and needs no feature detection. **The Vite dev server never caches** (no plugin version emulates it): every `npm run dev` request runs the handler, so caching can only be observed on a deployed App.

A `GET` route that declares `config.cache` gets an `ETag` on its `200` responses. A repeat request whose `If-None-Match` still matches gets `304 Not Modified` **before the handler bundle loads or an isolate starts**. Informer computes the tag from version tokens it keeps for everything it can see change (workspace tables, deploys, environment, the App row) plus the request, so the App writes no invalidation code: a committed write changes the tag, and the next request runs the handler.

## Declaring it

```javascript
// server/orders/summary.js
export const config = { cache: true };

export async function GET({ query }) {
    const [summary] = await query(`
        SELECT count(*) AS orders, sum(total) AS revenue
        FROM orders WHERE status = 'open'
    `);
    return summary;
}
```

- Only the file's `GET` is cached. A `POST` / `PUT` / `DELETE` exported from the same file runs as usual, and its writes are what invalidate the `GET`.
- `cache: true` equals `cache: {}`. The object form:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `ttl` | integer seconds, 1–86400 | none | Upper bound on reuse. **Required** for a response that reads anything the tag can't see (below), else that response gets no tag at all |
| `vary` | `'user'` \| `'none'` | `'user'` | `'user'`: the caller (what `request.user` shows) and the API key are in the tag. `'none'`: callers holding the same roles share one tag |
| `tables` | non-empty, unique `string[]` | every table | Only writes to these workspace tables invalidate. Unqualified table names in the App's schema |
| `edge` | integer seconds, 0–86400 | `0` | `s-maxage` for a CDN. Only with `vary: 'none'`, only for credential-free requests on the App's origin |

- `config` is read as a literal at deploy, like `timeout` and `roles` (see `server-routes.md`): no imported identifiers inside it.
- **A malformed `cache` does not fail the deploy.** The route deploys uncached, and the deploy response carries a partial failure `{ "phase": "scanRoutes", "handlerPath": "server/orders/summary.js", "error": "config.cache is invalid and was ignored, so responses are not cached: <joi message>" }`, which `npm run deploy` prints under "non-fatal deploy phase failure(s)". Read the deploy output after adding `cache`; a typo (`ttl: '60'`, `vary: 'users'`, `tables: []`) means no caching, silently in the browser.

## What the tag covers

| Input | Changes the tag when |
|---|---|
| Workspace data | Any committed write to any workspace table, from any path: routes, webhooks, agent tools, channel handlers, the SQL console. With `tables`, only writes to those tables. Rolled-back writes change nothing |
| Code | Every deploy (route rows are replaced, so new code never matches an old tag) |
| Environment | An env var is added, changed or removed |
| The App row | Rename, owner change, `public:` flip, any update to the App record |
| The request | Path params, the sanitized query string, `request.roles`; with `vary: 'user'` also `request.user` and `request.apiKey` |
| Address | The `Host` (and forwarded host / proto / path) the request came on |
| Clock | With `ttl`, every `ttl`-second window (aligned to the clock, so reuse is **at most** `ttl` seconds, sometimes less) |

A table created at run time (a handler's `CREATE TABLE`) is covered once that handler run ends. A workspace restore, a bundle import, or DDL from the SQL console pauses caching for the App (no tags) until the next handler run re-checks the workspace triggers.

**A revalidation still authenticates** the caller and still enforces `config.roles`, the compute budget and the marketplace license. It skips only loading and running the handler.

## What the tag can't see: declare `ttl` or don't cache

Inputs with no version token. A response whose run touched any of these is **not tagged unless the route declares `ttl`**; with `ttl` it is reused for at most that long:

- `fetch()` to the Informer API
- any `context.<slot>` method (Datasets, Integrations, other Apps, every dependency)
- `uploads` / `downloads`
- `embed()` / embeddings

Never detected at all, so the author must handle them:

- **Time.** SQL `now()` / `current_date`, `Date.now()`, "today", "last 7 days". Without a `ttl` the answer stays until something else changes. Give such a route a `ttl` matching the freshness it needs.
- **Randomness** or anything meant to differ per call.

```javascript
// server/sales/today.js: reads a Dataset slot, and "today" moves on its own
export const config = { cache: { ttl: 300 } };

export async function GET({ context }) {
    return await context.sales.search({ query: { range: { date: { gte: 'now/d' } } } });
}
```

## Responses that are never tagged

Only a plain `200` is tagged. No `ETag`, never a `304`, when:

- the status is anything else (returning nothing is a `204`: not cached)
- the handler returned a staged download
- the handler set its own `ETag` or any `Set-Cookie`
- it read an unversioned input (above) without a `ttl`

A `Cache-Control` the handler sets itself is kept; otherwise a tagged response gets `Cache-Control: private, no-cache` (the browser stores it and revalidates every time).

## Choosing the options

- **Default to `cache: true`** for a workspace-only read. Correct by construction: any write invalidates.
- **Add `tables`** when the App writes often to tables this route doesn't read (an `audit_log`, an event ledger, a sync staging table), so those writes stop forcing reruns. **List every table the handler reads**, including tables behind views, functions and joins. A table missing from the list is a stale-data bug: the route answers from before the write until a listed table changes or the `ttl` lapses. When unsure, omit `tables`.
- **Use `vary: 'none'`** only when the handler never reads `request.user` or `request.apiKey` (a catalog, reference lists, public settings). Roles stay in the tag, so role-dependent answers remain correct.
- **Add `ttl`** for any slot/`fetch()`/time dependency. Pick the staleness the screen can tolerate, not the shortest possible.
- **`edge`** only for a public App whose anonymous traffic is large enough to want a CDN, and only for answers that may lag by `edge` seconds: a CDN cannot be invalidated.

Do not use caching in place of client freshness: after a mutation the page must still invalidate its TanStack Query keys (`ui-quality.md`). The refetch is what will be cheap now.

## In the browser

Nothing changes in App code. `fetch('/api/orders/summary')` resolves `200` with the browser-cached body when the server answered `304`; DevTools' Network panel shows the `304`. A script calling the route with an App API key gets `304` only if it sends `If-None-Match` itself.

## Public routes and anonymous traffic

On a public App (`public: true`, origin mode; see `accounts-and-login.md`), credential-free requests to a cached route under `server/public/**` (`/api/public/...`) get more:

- **Per-server store.** Each server keeps recent bodies of those responses and answers a repeat anonymous request from memory, checked against the current tokens first (one Redis call; nearly never Postgres). Invalidation is identical to a `304`.
- **Shared misses.** Identical concurrent anonymous misses run the handler once; the rest get that response.
- **Overload relief.** With 4 anonymous runs of one App already in flight on a server (`app.responseCache.maxMissesPerApp`), more anonymous requests get the last stored response for that request (up to 10 minutes old, `staleMs`) or `503` with `Retry-After: 1` and `This app is busy. Try again shortly.`

"Credential-free" means no `Authorization` header, no `X-Informer-App-Assertion`, no `token` cookie, no `token` / `app_token` query parameter. A signed-in visitor gets the per-user behavior.

**With `edge`** (and `vary: 'none'`), such a response is sent `Cache-Control: public, max-age=0, s-maxage=<edge>`; everything else stays `private, no-cache`. Informer sends **no `Vary` header** for credentials, so a CDN in front of App origins must key on `Host`, the `token` cookie, `Authorization` and the full query string, or bypass its cache whenever a `token` cookie or `Authorization` header is present. Otherwise a signed-in visitor can be handed the anonymous response. Tell the user this when proposing `edge`; it is server-admin configuration, not App code.

## Verifying

Only against a deployed App:

1. Load the page, open DevTools Network, reload: the route's second response is `304` and the first carries an `ETag`.
2. No `ETag` → walk the "never tagged" list: not a `GET`, deploy partial failure for `config.cache`, non-`200`, `Set-Cookie`, or a slot/`fetch()` read without `ttl`. A server admin may also have `app.responseCache.enabled: false`.
3. Stale data → the change came through something the tag can't see (a Dataset, `fetch()`, the clock, a table missing from `tables`). Add `ttl` or fix `tables`.

The App admin panel's **API Routes** tab shows "`<n>`% served from cache" under **Total Calls (30d)** and a green per-route count ("`<n>` calls served from cache"). Cached responses count toward totals but are absent from recent invocations and from average latency (here and on Overview); they are written in one-minute batches. `GET /api/apps/{id}/stats/api` returns them as `routes[].cached30d` and `daily[].cachedCount`. A cached response is billed as App compute for the time it took to answer, not as a handler run.

## Server settings (for the admin, not the App)

`config.json` under `app`, read at server start:

- `app.responseCache`: `enabled` (default `true`; `false` = no route is cached, no `ETag`s), `reconcileMs` (30000), `maxBytes` (64 MB of anonymous bodies per server), `maxEntryBytes` (1 MB; larger bodies still `304` but aren't stored), `maxMissesPerApp` (4), `staleMs` (600000).
- `app.heldFiles`: each server holds every App's `informer.yaml` and compiled handler code in memory, re-read on change and at least every `maxAgeMs` (60000). `enabled: false` reads them from the Library on every request (the server logs a warning). `manifestMaxBytes` 8 MB, `bundleMaxBytes` 64 MB; a file over an eighth of its bound isn't held.

Both switches exist to rule a layer out when an App appears to serve old data or old code; suggest them to the user's admin in that situation rather than adding workarounds to the App.
