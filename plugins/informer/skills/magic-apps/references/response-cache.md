# Response Caching (`config.cache` on GET Routes)

> **Load this reference when:** a `GET` route is read far more often than its data changes (a dashboard that polls, a lookup or catalog every page loads, settings, a summary), the user asks to make a route faster or cheaper, or asks why a route isn't caching or serves old data, or mentions "cache", "ETag", "304", "`X-Informer-Cache`", "stop re-running the query", "CDN" or a public App under heavy anonymous traffic. Covers `config.cache` (`true` | `{ ttl, vary, tables, edge }`), what changes the validator and what it can't see, which responses are never tagged, the public-route store and overload relief, putting a CDN in front, how to verify caching (the `X-Informer-Cache` header, the per-App switch and Clear), the deploy warnings for a bad declaration or an unwatched relation, and the `app.responseCache` / `app.heldFiles` server settings.
>
> **Not in this file:** the rest of the handler bag and `config.timeout` / `config.roles` / `config.api` — see `server-routes.md`. Public serving itself (`public: true`, `server/public/**`, accounts) — see `accounts-and-login.md`. Client-side freshness after a mutation (TanStack Query invalidation) — see `ui-quality.md`; server caching does not replace it.
>
> **Availability:** Informer **2026.2.0+** (I5-13259). **Older servers ignore `config.cache`**: the route deploys and runs uncached, with no error, so the declaration is safe to ship to any target and needs no feature detection. **The Vite dev server never caches** (no plugin version emulates it): every `npm run dev` request runs the handler. **Neither does a draft being edited in Informer** (`X-Informer-Cache: bypass; reason=draft`, and its workspace gets no triggers). Check caching against the published App.

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
- `cache: true` equals `cache: {}`. `cache: false` is valid and means not cached. The object form:

| Option | Type | Default | Meaning |
|---|---|---|---|
| `ttl` | integer seconds, 1–86400 | none | Upper bound on reuse. **Required** for a response that reads anything the tag can't see (below), else that response gets no tag at all |
| `vary` | `'user'` \| `'none'` | `'user'` | `'user'`: the caller (what `request.user` shows) and the API key are in the tag. `'none'`: callers holding the same roles share one tag |
| `tables` | non-empty, unique `string[]` | every table | Only writes to these workspace tables invalidate. Unqualified names of **plain tables only**, spelled and cased as in the App's schema. A view, a partitioned table, a partition or a typo makes the route follow every table (deploy reports `syncResponseCache`, below) |
| `edge` | integer seconds, 0–86400 | `0` | `s-maxage` for a CDN. Only with `vary: 'none'` (with `vary: 'user'` it validates but is ignored), only for credential-free requests on the App's origin |

- `config` is read as a literal at deploy, like `timeout` and `roles` (see `server-routes.md`): no imported identifiers inside it.
- **A malformed `cache` does not fail the deploy.** The route deploys uncached, and the deploy response carries a partial failure `{ "phase": "scanRoutes", "handlerPath": "server/orders/summary.js", "error": "config.cache is invalid and was ignored, so responses are not cached: <joi message>" }`, which `npm run deploy` prints under "non-fatal deploy phase failure(s)". Read the deploy output after adding `cache`; a typo (`ttl: '60'`, `vary: 'users'`, `tables: []`) means no caching, silently in the browser. `cache` on a file that exports no `GET` also deploys with a `scanRoutes` warning: "config.cache applies only to GET, and this file exports no GET handler, so nothing is cached".
- **`tables` naming anything but a plain table** deploys with a `syncResponseCache` partial failure: "config.cache.tables names `<X>`, which is not a plain table in this App's workspace (a view, a partitioned table, a partition or a misspelling), so any workspace write invalidates this route's responses. Name plain tables exactly as in the workspace." The route still caches, just as if `tables` were omitted.

## What the tag covers

| Input | Changes the tag when |
|---|---|
| Workspace data | Any committed write to any watched workspace table, from any path: routes, webhooks, agent tools, channel handlers, the SQL console. With `tables`, only writes to those tables. Rolled-back writes change nothing. Materialized views and foreign tables are never watched (below) |
| Code | Every deploy (route rows are replaced, so new code never matches an old tag) |
| Environment | An env var is added, changed or removed |
| The App row | Rename, owner change, `public:` flip, the App's caching switch, any update to the App record. A **Clear** replaces the same token |
| The request | Path params, the sanitized query string, `request.roles`; with `vary: 'user'` also `request.user` and `request.apiKey` |
| Address | The `Host` (and forwarded host / proto / path) the request came on |
| Server | An Informer upgrade, or a change to `externalUrl`, `app.appsBaseUrl` or `app.tenantSubdomains` (each response misses once) |
| Clock | With `ttl`, every `ttl`-second window (aligned to the clock, so reuse is **at most** `ttl` seconds, sometimes less) |

**Coverage.** A table a server route or webhook creates is covered when that run ends. One created any other way (an agent tool, a channel handler, the SQL console) is not watched until the next deploy or route/webhook run, so writes to it change no tag in between; give a route that reads it a `ttl`. **Caching pauses** (no `ETag`s, `bypass; reason=not-ready`) after a workspace restore, a bundle import or a workspace copy, after a SQL console statement other than plain DML (`SELECT` / `INSERT` / `UPDATE` / `DELETE` / `MERGE` / `TRUNCATE`), and after a console write while some table lacks its trigger. It resumes at the next deploy or server-route/webhook run. Writes made while a handler has `ALTER TABLE … DISABLE TRIGGER` on are never seen.

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
- **Materialized views and foreign tables.** Triggers go on plain tables only, so a `REFRESH MATERIALIZED VIEW`, or a write on a foreign table's remote server, changes no tag. Every deploy of an App with a cached route reports each one as a `syncResponseCache` partial failure, for example "`sales_mv` is a materialized view: a REFRESH never invalidates cached responses that read it. Give a cached route that reads it a ttl." (a foreign table says "a write on its remote server" instead). Do what it says.

```javascript
// server/sales/today.js: reads a Dataset slot, and "today" moves on its own
export const config = { cache: { ttl: 300 } };

export async function GET({ context }) {
    return await context.sales.search({ query: { range: { date: { gte: 'now/d' } } } });
}
```

## Responses that are never tagged

Only a plain `200` is tagged. No `ETag`, never a `304`, when (the `X-Informer-Cache` reason in brackets):

- the status is anything else (`status`; returning nothing is a `204`: not cached)
- the handler returned a staged download (`download`)
- the handler set its own `ETag` (`etag`) or any `Set-Cookie` (`cookie`)
- it read an unversioned input (above) without a `ttl` (`unversioned`)

A `Cache-Control` the handler sets itself is kept on the `200`; otherwise a tagged response gets `Cache-Control: private, no-cache` (the browser stores it and revalidates every time). A `304` is answered before the handler runs, so it always carries the platform's value.

## Choosing the options

- **Default to `cache: true`** for a workspace-only read. Correct by construction: any write invalidates.
- **Add `tables`** when the App writes often to tables this route doesn't read (an `audit_log`, an event ledger, a sync staging table), so those writes stop forcing reruns. **List every table the handler reads**, including tables behind functions and joins. For a view, list the base tables behind it, never the view's own name. A table missing from the list is a stale-data bug: the route answers from before the write until a listed table changes or the `ttl` lapses. When unsure, omit `tables`.
- **Use `vary: 'none'`** only when the handler never reads `request.user` or `request.apiKey` (a catalog, reference lists, public settings). Roles stay in the tag, so role-dependent answers remain correct.
- **Add `ttl`** for any slot/`fetch()`/time dependency. Pick the staleness the screen can tolerate, not the shortest possible.
- **`edge`** only for a public App whose anonymous traffic is large enough to want a CDN, and only for answers that may lag by `edge` seconds: a CDN cannot be invalidated.

Do not use caching in place of client freshness: after a mutation the page must still invalidate its TanStack Query keys (`ui-quality.md`). The refetch is what will be cheap now. A run that may have written waits until its writes are recorded before each `broadcast()` and before it answers, so the caller's refetch, and a channel subscriber's refetch on the event (`channels.md`), never get a `304` for the old data. Don't add cache-busting query parameters.

## In the browser

Nothing changes in App code. `fetch('/api/orders/summary')` resolves `200` with the browser-cached body when the server answered `304`; DevTools' Network panel shows the `304`. A script calling the route with an App API key gets `304` only if it sends `If-None-Match` itself.

## Public routes and anonymous traffic

On a public App (`public: true`, origin mode; see `accounts-and-login.md`), credential-free requests to a cached route under `server/public/**` (`/api/public/...`) get more:

- **Per-server store.** Each server keeps recent bodies of those responses and answers a repeat anonymous request from memory, checked against the current tokens first (one Redis call; nearly never Postgres). Invalidation is identical to a `304`.
- **Shared misses.** Identical concurrent anonymous misses run the handler once; the rest get that response.
- **Overload relief.** With 4 anonymous runs of an App's cached routes already in flight on a server (`app.responseCache.maxMissesPerApp`), more anonymous requests get the latest stored response for that request: up to 10 minutes old (`staleMs`), and only if no Clear, deploy, or App or env change has happened since it was stored. It goes out with `Cache-Control: no-store`, no `ETag` and `X-Informer-Cache: stale`. With nothing suitable stored, the handler runs unstored, and identical requests share that run. Caching never refuses a request.

"Credential-free" means no `Authorization` header, no `X-Informer-App-Assertion`, no `token` or `sid` cookie, no `token` / `app_token` query parameter. A signed-in visitor gets the per-user behavior.

**With `edge`** (and `vary: 'none'`), a credential-free response is sent `Cache-Control: public, max-age=0, s-maxage=<edge>` and `Vary: cookie, authorization`; other route responses stay `private, no-cache`. A public App's own static files (its built JS, CSS, images) are also shared-cacheable (`public, max-age=0, s-maxage=60`) when requested credential-free on its origin while caching is on for the server and the App, whether or not any route declares `config.cache`. `Vary` does not cover `X-Informer-App-Assertion` or a `token` / `app_token` query parameter. So a CDN in front of App origins must either key on `Host`, the `token` cookie, `Authorization`, `X-Informer-App-Assertion` and the full query string, or bypass its cache for any request that carries a `token` cookie, a `token` / `app_token` query parameter, or either header. Otherwise a signed-in visitor can be handed the anonymous response. Tell the user this when proposing `edge`; it is server-admin configuration, not App code. Turning caching off or a Clear doesn't reach a CDN: its copy lives out its `s-maxage`.

## Verifying

Only against a deployed, published App:

1. **Read `X-Informer-Cache`** on the route's response in DevTools Network. Every response of a cached route carries it: `hit` (a `304`, or a body from the public store), `miss` (the handler ran and the response is tagged), `stale` (overload relief), or `bypass; reason=<r>`. **No header at all** means the route isn't cached: not a `GET`, `cache: false`, a deploy partial failure for `config.cache`, or a server older than 2026.2.0.
2. **On a `bypass`, the reason says why:**
   - `app-disabled`: the App's own switch is off. Turn it on (below).
   - `draft`: a draft never caches; check the published App.
   - `not-ready`: caching is paused (see Coverage: restore, import, copy, console DDL, a failed trigger sync). The next deploy or route/webhook run resumes it.
   - `status`, `download`, `etag`, `cookie`, `unversioned`: the response itself can't carry a tag (see "never tagged"); for `unversioned`, add a `ttl`.
   - `disabled`: an admin turned caching off for the whole server (`app.responseCache.enabled: false`).
   - `not-heard`, `unavailable`: this server isn't receiving the database's change notifications, or its Redis didn't answer. Server-side; tell the user's admin.
3. **`miss` then `hit`**: reload; the second response is `304` with the first one's `ETag`.
4. **Stale data**: the change came through something the tag can't see (a Dataset, `fetch()`, the clock, a materialized view refresh, a foreign table, a table missing from `tables`, a table created outside a route or webhook). Add `ttl` or fix `tables`, then **Clear** to drop what's already cached.

**The per-App switch and Clear.** Once an App declares a cached route, its admin panel's **API Routes** tab shows a **Response caching** card: a switch ("Cache this App's route responses") and, while caching is on, **Clear cached responses**. Anyone who can manage the App can use both, no server admin needed. Clear makes every stored and browser-held response miss once, which is the fix after a change the tag can't see; the switch rules caching out of a stale-data report without a redeploy. The API behind it, gated on `permission.app.manage`: `GET` / `PUT /api/apps/{id}/response-cache` (`PUT` body `{ "enabled": false }`; both return `{ state, serverEnabled, enabled, ready }`, where `state` is `on` or a bypass reason) and `POST /api/apps/{id}/response-cache/_clear` (adds `cleared`). Both refuse a draft with `409`.

The same tab shows "`<n>`% served from cache" under **Total Calls (30d)** and a green per-route count ("`<n>` calls served from cache"). Cached responses count toward totals but are absent from recent invocations and from average latency (here and on Overview); they are written in one-minute batches. `GET /api/apps/{id}/stats/api` returns them as `routes[].cached30d` and `daily[].cachedCount`. A cached response is billed as App compute for the time it took to answer, not as a handler run.

## Server settings (for the admin, not the App)

Reach for the App's own switch and Clear first (above). These are server-wide, in `config.json` under `app`, read at server start:

- `app.responseCache`: `enabled` (default `true`; `false` = no route is cached and no `ETag`s, deploys drop the workspace triggers, and public App files go out `private, no-cache`), `reconcileMs` (30000), `maxBytes` (64 MB per server, counting each stored response's body, key and headers plus 512 bytes), `maxEntryBytes` (1 MB; larger bodies still `304` but aren't stored), `maxMissesPerApp` (4), `staleMs` (600000).
- `app.heldFiles`: each server holds every App's `informer.yaml`, `data-access.yaml` and compiled handler code in memory, re-read on change and at least every `maxAgeMs` (60000). `enabled: false` reads them from the Library on every request (the server logs a warning). `manifestMaxBytes` 8 MB, `bundleMaxBytes` 64 MB; a file over an eighth of its bound isn't held.

Both switches exist to rule a layer out when an App appears to serve old data or old code, after the per-App switch hasn't explained it; suggest them to the user's admin in that situation rather than adding workarounds to the App.
