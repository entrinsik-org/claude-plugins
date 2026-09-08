# Embeddings (Declarative Vector Search)

> **Load this reference when:** the app needs semantic/vector search over its own workspace data — declaring embedding use cases under `embeddings/`, chunking profiles, `embed(name, text)` query-time vectors, `vector(…)` columns in migrations, or the embeddings status/run routes.
>
> **Not in this file:** migration mechanics and the dev-workspace lifecycle — see `persistence.md`. `query()` calling shape and parameter binding — see `server-routes.md`. `emit()` event plumbing — see `server-routes.md` / `agents.md`.
>
> **Availability:** Informer **2026.1.3+** (I5-12984). The folder, `embed()`, and the status/`_run` routes simply do not exist on older servers, and the CLI ships `embeddings/` only from `@entrinsik/vite-plugin-informer` **≥ 2.8.0** (2.7.0 and earlier never upload the folder, so the use case silently does not exist on the server, and any `server/` file importing from it fails the deploy at bundle time with `import not found in app library`). An app that must also run on older servers **feature-detects on `platform.capabilities.embeddings`** (see Feature detection below), keeps its vector DDL out of numbered migrations or gates it with `-- requires: embeddings` (see `persistence.md`), and only states a floor (`requires: { informer: '>=…' }` in informer.yaml, see `informer-yaml.md`) when it cannot work without the feature.

Apps can maintain vector embeddings over their own data **declaratively**. You ship an `embeddings/` folder with one file per use case; the platform acts as an **embedding pump** that asks your app what's pending, chunks and embeds the content in billed batches, and hands the vectors back for your app to store in its own workspace tables. You never call an embedding provider yourself, and the platform never holds a copy of your corpus.

The folder is capability-gated: full `app` type only, not legacy Magic Reports.

## The inversion: your storage is the ledger

The design inverts the usual indexing service. The platform keeps **no copy of the corpus and no progress ledger** — your app's own tables are the ledger:

| Piece | Owner | Carries |
|---|---|---|
| `embeddings/<name>.js` | You | The use case: an optional `config` export plus `GET` and `POST` handlers |
| `app_embedding` projection row | Platform | Validated config, a revision hash, pump run state — rebuilt from the folder on every deploy |
| Workspace tables | Your app | The vectors themselves, in whatever schema your migrations define. Cleanup is your own foreign keys |

Because `GET` anti-joins your own embedding table, the pump is idempotent and crash-tolerant by construction: a run that dies mid-way simply finds the same rows pending next time, and your `POST` upserts.

## A use case file

One file per use case, **top level** in `embeddings/` (no subdirectories). Every file must export **both** `GET` and `POST` — a missing half fails the deploy. `config` is optional.

```javascript
// embeddings/tickets.js
export const config = { chunking: 'none', on: ['ticket.created'], batchSize: 100, revision: 1 };

// GET: return the rows that still need embedding. The query IS the watermark.
export async function GET({ query, batch }) {
  return await query(`
    SELECT t.id, t.subject || ' ' || t.body AS content
    FROM tickets t
    LEFT JOIN ticket_embeddings e ON e.ticket_id = t.id AND e.seq = 0
    WHERE e.ticket_id IS NULL OR e.embedded_at < t.updated_at OR e.revision <> $2
    ORDER BY t.id
    LIMIT $1
  `, [batch.limit, batch.revision]);
}

// POST: store the embedded results wherever the app wants.
export async function POST({ query, batch }) {
  for (const doc of batch.docs) {
    await query('DELETE FROM ticket_embeddings WHERE ticket_id = $1', [doc.id]);
    for (const c of doc.chunks) {
      await query(
        'INSERT INTO ticket_embeddings (ticket_id, seq, embedding, content, revision) VALUES ($1, $2, $3::vector, $4, $5)',
        [doc.id, c.seq, JSON.stringify(c.embedding), c.content, batch.revision]
      );
    }
  }
  return { stored: batch.docs.length };
}
```

The three clauses in the `GET` `WHERE` are the whole freshness model: *never embedded* (`IS NULL`), *stale* (`embedded_at < updated_at`), and *config/model changed* (`revision <> $revision`). Write all three.

## The pump contract

Each run drains the pending set in a loop: `GET` the next batch, chunk each row's `content` by the configured profile, embed all chunks in batched provider calls, then `POST` the results. The loop stops when `GET` returns `[]` or fewer rows than `batchSize` (return a full page while work remains), when a batch yields no embeddable rows, or after 20 batches (`drained: false` in the result: the run re-poked itself so the next sweep continues). A batch whose rows were all tombstoned stops, and the app has to exclude them.

### `GET({ query, batch })`

- `batch: { limit, revision }` — request at most `limit` rows; compare `revision` against what's stored beside your vectors.
- Return an array of rows shaped `{ id, content, metadata? }`.
- **Return `[]` when drained.** Returning no body at all (a missing `return`) is an authoring error, not a drained corpus — the platform treats it as such rather than silently stopping.
- A row whose `content` exceeds **1,000,000 characters**, or whose content produces no chunks at all (empty or whitespace-only), is reported in `failures` and skipped on later runs rather than chunked. Both are deterministic for that content, and tokenizing is synchronous work that would otherwise stall the server.

### `POST({ query, batch })`

`batch: { revision, docs, failures }`:

- `docs`: `[{ id, metadata, chunks: [{ seq, content, metadata, embedding }] }]` — grouped per document, so delete-and-replace per doc (as in the example above) is the natural idiom. `chunks[].embedding` is a **bare array**, ready to `JSON.stringify` into a `vector` literal.
- `failures`: `[{ id, error, code, permanent, skipped? }]` — see below. `chunks[].metadata` is always an object; `headingPath` (the `prose` profile) is its only key today.

**`POST` may be called more than once per `GET` batch.** Results are stored in slices bounded by chunk count (about 2,000 chunks), so a batch of large documents cannot exceed the sandbox's memory and already-embedded vectors are not lost to one failed call. Every call carries the same `revision`; `failures` rides the first call of a batch. The pump is at-least-once, so your `POST` had to be idempotent anyway — a correct upsert needs no change.

Store `batch.revision` beside each vector and include `<> $revision` in your `GET` query.

### Revision: one string, three triggers

The `revision` the pump hands you couples your config (chunking profile, token budgets, `config.revision`) **to the resolved platform embedding model**. So a corpus-wide re-embed surfaces automatically as pending work when any of these change:

- you bump `config.revision`
- you change the chunking profile or token budgets
- an admin repoints the platform embedding model

No manual invalidation — the `revision <> $revision` clause in your `GET` finds everything.

### Failures and tombstones

Deterministic failures (content over the model's input cap, chunker errors) are reported in `failures` and **tombstoned platform-side by content hash** — an unembeddable document is attempted once per content-and-config even if you ignore the array (the platform keeps the most recent 1,000 tombstones per use case; older ones are retried). Tombstoned rows are re-reported on **every** run with `skipped: true`, so stamp them in your own table and exclude them from your `GET` query, or they'll ride along in every batch report forever:

```javascript
for (const f of batch.failures) {
  if (f.permanent) {
    await query('UPDATE tickets SET embed_failed = true WHERE id = $1', [f.id]);
  }
}
```

## Config

| Key | Meaning |
|---|---|
| `description` | Shown in the admin Embeddings tab and the status listing |
| `chunking` | `none` (row = one embedding, the default), `prose` (markdown-aware recursive splitting with heading breadcrumbs), or `code` |
| `maxTokens` | Chunk budget for `prose`/`code`: 16–8191, default 512. Not allowed under `none` |
| `overlapTokens` | Tokens carried from each chunk into the next for `prose`/`code`: default `min(64, maxTokens / 8)`, and **at most half of `maxTokens`** (checked at deploy). Above half each chunk advances by less than it repeats, and the tokens billed grow superlinearly in the ratio. Not allowed under `none` |
| `on` | Event names (from `emit()`) that trigger a run; a single string is accepted |
| `cron` | A five-field cron schedule; desugars into an automation that triggers runs |
| `batchSize` | Rows requested per `GET` (1–1000, default 100) |
| `timeout` | Sandbox wall-clock per handler invocation: 1000–300000 ms, default 30000 |
| `revision` | Author-bumped value that forces a corpus-wide re-embed |

`config` itself is optional: a file exporting only `GET` and `POST` deploys as `{ chunking: 'none', batchSize: 100 }` with no triggers, so it runs only on deploy and on a manual run. The token budgets are not part of that default — under `none` they are **refused**, not applied.

**The schema is strict — unknown keys fail the deploy.** Don't park extra metadata in `config`; it is persisted onto the app's route table and its embedding projection, so nothing unexpected may ride through. And write it as a self-contained literal on the `export const`: the scanner evaluates it with none of the file's imports in scope, so an imported constant, a spread of an imported object, or an `export { config }` re-export fails the deploy (see Handler Config in `server-routes.md`). Other modules may import the literal from the use-case file; the reverse is what's forbidden.

## Triggers

Every trigger converges on the same platform poke, and runs take a **single-flight lease per use case**, so concurrent triggers coalesce instead of double-embedding:

- **Deploy** pokes each use case (initial backfill — a fresh deploy starts embedding immediately)
- **`emit()` events** matching `on:` poke
- **`cron`** automations poke
- **Manual run** via the `_run` route (below), which claims the same lease directly

A background platform sweep executes pending use cases **as the app owner**.

## Workspace and pgvector

Apps with the embeddings capability get the `vector` extension provisioned in their workspace database **where the server may create extensions** — otherwise the deploy log names the cause and a migration using the `vector` type fails. Both the app role and its read-only workbench role can resolve the type and its operators. Migrations can declare real vector columns:

```sql
-- requires: embeddings
CREATE TABLE ticket_embeddings (
  ticket_id INTEGER NOT NULL REFERENCES tickets(id) ON DELETE CASCADE,
  seq INTEGER NOT NULL DEFAULT 0,
  embedding vector(1536) NOT NULL,
  content TEXT NOT NULL,
  revision TEXT NOT NULL,
  embedded_at TIMESTAMPTZ NOT NULL DEFAULT clock_timestamp(),
  PRIMARY KEY (ticket_id, seq)
);
```

Open that migration with `-- requires: embeddings` so it is **skipped, not failed**, on an install without pgvector (see `persistence.md`); it applies on the first deploy after the extension arrives.

The `ON DELETE CASCADE` is the cleanup story — the platform never touches your vector tables, so your own foreign keys are what keep them in sync with the source rows.

### On an install without pgvector

The deploy creates your use cases **parked**, with `pgvector is not installed in the workspace database` as their `lastError`, and does not poke them. That is deliberate: nothing can be stored without the extension, so a pump run would pay a provider for vectors your `POST` is about to reject with `relation ... does not exist` — and that failure looks retryable, which buys five paid re-embeds of the same batch before parking with an error that never names the real cause. The next deploy after pgvector arrives applies the migration and starts the pump normally.

### Searching: plain SQL + `embed(name, text)`

Search is ordinary SQL in your own handlers. Every handler bag (`server/`, `webhooks/`, `tools/`, `mcp/`) exposes `embed(name, text)` for query-time vectors. `name` must be a declared use case — unknown names throw. All use cases embed through the platform's `informer-embedding` alias, resolved to its canonical model.

**`embed()` returns `{ embedding, revision }`, not a bare vector. Filter on the revision as well as ordering by distance.** Resolving through the same alias only keeps a query in the corpus's vector space while the alias has not moved *and* the pump has caught up. When an admin repoints the embedding model, every new query vector is in the new space while the stored rows are still in the old one, and an unfiltered `ORDER BY embedding <=> $1` silently returns near-random neighbours — nothing logged, nothing on the admin tab. Comparing revisions turns that into an empty result set: a visibly wrong answer instead of an invisibly wrong one, until the pump finishes re-embedding.

```javascript
// server/search.js
export async function POST({ query, embed, request }) {
  const { embedding, revision } = await embed('tickets', request.body.q);
  return await query(`
    SELECT t.*, 1 - (e.embedding <=> $1::vector) AS score
    FROM ticket_embeddings e JOIN tickets t ON t.id = e.ticket_id
    WHERE e.revision = $2
    ORDER BY e.embedding <=> $1::vector
    LIMIT 20
  `, [JSON.stringify(embedding), revision]);
}
```

Two things that bite if you skip them. `JSON.stringify(await embed(...))` stringifies the whole object, and Postgres rejects it as a malformed vector literal — destructure first. And an empty result after a model repoint is the guard working, not a bug: distinguish it from an empty corpus (count rows at any revision) before you show the user anything.

A revision hashes **the use case's own config alongside the model**, so two use cases never share one, even on the same install. Searching two corpora therefore needs an `embed()` call per use case. Reusing one query vector across both is geometrically fine — same model, same space — but it leaves the second corpus with no revision to check against, which is the whole guard.

`embed()` is for query-time vectors, so it is bounded: at most **100,000 characters per call** and **100 calls per handler invocation**, and it is refused when the app's compute budget is exhausted. Embedding a corpus belongs in an `embeddings/` use case, where the work is batched and billed per slice.

### Billing

Embedding calls are billed to the app — one usage entry per batch of up to 128 chunks, regardless of how many provider requests run underneath. Pump compute is metered per handler invocation against the app's compute budget. `embed()` at query time is billed to the app too.

### Failed runs

A failed run is retried or parked by cause. A provider error the SDK marks retryable, a handler timeout, a host-side sandbox failure, or an unknown error re-pokes the use case with a doubling delay (**20 s, 40 s, 80 s, 160 s**) and parks it on the fifth consecutive failure. A non-retryable provider error (bad key, deleted model, rejected input), an exhausted compute budget, missing handlers, or a contract violation parks it at once. A parked use case keeps its error as `lastError`; the next trigger (event, cron, deploy, or **Run now**) gives it one more attempt, and a successful run resets the attempt count. A trigger arriving while a run is in progress is never lost to that run's backoff or park.

So a use case showing **Retry scheduled** is healing on its own; one showing **Last run failed** with no retry needs you.

## Feature detection

- **In handler code:** `platform.capabilities.embeddings` on the handler bag. `embed` is **always a function** server-side and throws when the app type lacks the capability, so `typeof embed === 'function'` only tells an older server (no `embed` at all) from a newer one — check the capability flag to know whether a call will succeed.
- **In the browser:** `window.__INFORMER__.platform.capabilities.embeddings`.
- **As a floor:** `requires: { informer: '>=<version>' }` in `informer.yaml` refuses the deploy on an older server with a clear message, for an app that cannot work without the feature.

Locally the Vite plugin's dev mirror reports `embeddings: false`: the pump and `embed()` need a real Informer, so an app sees in development exactly what it sees on an install without the feature. The dev `embed()` exists and throws a written explanation rather than being undefined, so the dev failure reads as the same lesson as the deployed one.

## Watching the pump

The App admin panel has an **Embeddings** tab (Data group): one row per use case with pump status (up to date / **indexed with gaps** / queued / retry scheduled / running / failed), chunking, schedule and event triggers, last run and next run, the effective revision, the last run's failed-docs count, a skipped-docs (tombstoned) count, the failed-runs count while a retry is backing off, the last error inline, and a **Run now** action. *Indexed with gaps* is the degraded state after a run that skipped or failed documents; a warning banner appears when the server has no resolvable embedding model. During development this is usually faster than curling the routes below, which expose the same data.

## Routes

### `GET /apps/{id}/embeddings`

Returns `{ items: [...] }`: per use case the declared config (`description`, `chunking`, `on`, `cron`, `batchSize`), `revision` (config + resolved model; `null` when no embedding model resolves) and `configRevision` (the config-only half), `running`, `pending` (a poke is queued) with `nextRunAt` (in the future while a retry backs off) and `attempts` (consecutive failed runs), `tombstoned` (count of permanently failed documents), `lastRunAt`, `lastError`, and the last run's `lastFailed` / `lastSkipped` counts. Tombstone content hashes stay server-side.

**Permission:** read access to the App — it's status metadata, like the dependencies listing.

### `POST /apps/{id}/embeddings/{name}/_run`

Drains one use case immediately: claims the single-flight lease and executes the pump loop, returning `{ status: 'ok', useCase, processed, failed, skipped, batches, drained }`. Returns `{ status: 'already_running', useCase }` when a fresh lease is held; a lease older than 30 minutes (a crashed run) is reclaimed.

Errors: 402 (compute budget exhausted), 404 (handlers not deployed), 422 (`GET`/`POST` broke the contract, including an error status the handler returned). **Any 4xx parks the use case** with the reason as `lastError`. A 5xx (502 handler timed out or threw, 503 no embedding model resolves, 500 provider error) means the run failed after claiming the lease; whether it re-pokes with backoff or parks is decided by cause, per Failed runs above — a non-retryable provider error surfaces as a 500 and parks.

**Permission:** `permission.app.write`. Running the pump triggers billed provider calls, so the gate is a spend control, not just a data guard. The platform sweep dispatches this route as the resolved app owner.

This is your debugging loop during development: deploy, **Run now** in the admin panel's Embeddings tab (or `_run` here), read `lastError`, fix, repeat.

## Deploy behavior & gotchas

- `embeddings/` is uploaded and scanned like `server/` — `npm run deploy` is the whole setup, no manifest block (plugin ≥ 2.8.0; see Availability above).
- **It is a server-side folder.** Nothing in it is served to browsers, and any entry that is not a handler is reported as a deploy warning. An app that kept assets there before 2026.1.3 must move them.
- `npm run dev` never runs the pump, and its `embed()` throws (see Feature detection). The search route works only against a deployed app.
- Projection rows reconcile per deploy: config and revision rebuilt, run state on surviving rows preserved, removed files drop their row. **Your vector tables are never touched** — dropping a use case file leaves its data for your migrations to clean up.
- A path collision between folders (`embeddings/x.js` next to `server/x.js`) fails the deploy with an error naming both files: `server/`, `webhooks/` and `embeddings/` share one route table. Name a use case for what it produces (`article-passages`) rather than for the table it indexes (`articles`), which is usually already a route.
- **Pump handlers are never reachable through the app's own API surface or webhooks, and never appear in the app's `openapi.json`.** Only the pump invokes them. Don't try to call `GET`/`POST` from the frontend — put shared logic in a module both can import if you need it.
