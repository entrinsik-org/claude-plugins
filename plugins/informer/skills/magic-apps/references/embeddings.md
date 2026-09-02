# Embeddings (Declarative Vector Search)

> **Load this reference when:** the app needs semantic/vector search over its own workspace data — declaring embedding use cases under `embeddings/`, chunking profiles, `embed(name, text)` query-time vectors, `vector(…)` columns in migrations, or the embeddings status/run routes.
>
> **Not in this file:** migration mechanics and the dev-workspace lifecycle — see `persistence.md`. `query()` calling shape and parameter binding — see `server-routes.md`. `emit()` event plumbing — see `server-routes.md` / `agents.md`.
>
> **Availability:** ships in an upcoming Informer release (I5-12984). The folder, `embed()`, and the status/`_run` routes simply do not exist on older servers, and the CLI ships `embeddings/` only from `@entrinsik/vite-plugin-informer` versions that list it. An app that must also run on older servers **feature-detects** (`platform.capabilities.embeddings` on the handler bag, `window.__INFORMER__.platform.capabilities.embeddings` in the browser, `typeof embed === 'function'`), keeps its vector DDL out of numbered migrations or gates it with `-- requires: embeddings` (see `persistence.md`), and only states a floor (`requires: { informer: '>=…' }` in informer.yaml, see `informer-yaml.md`) when it cannot work without the feature.

Apps can maintain vector embeddings over their own data **declaratively**. You ship an `embeddings/` folder with one file per use case; the platform acts as an **embedding pump** that asks your app what's pending, chunks and embeds the content in billed batches, and hands the vectors back for your app to store in its own workspace tables. You never call an embedding provider yourself, and the platform never holds a copy of your corpus.

The folder is capability-gated: full `app` type only, not legacy Magic Reports.

## The inversion: your storage is the ledger

The design inverts the usual indexing service. The platform keeps **no copy of the corpus and no progress ledger** — your app's own tables are the ledger:

| Piece | Owner | Carries |
|---|---|---|
| `embeddings/<name>.js` | You | The use case: a `config` export plus `GET` and `POST` handlers |
| Platform projection row | Platform | Validated config, a revision hash, pump run state — rebuilt from the folder on every deploy |
| Workspace tables | Your app | The vectors themselves, in whatever schema your migrations define |

Because `GET` anti-joins your own embedding table, the pump is idempotent and crash-tolerant by construction: a run that dies mid-way simply finds the same rows pending next time, and your `POST` upserts.

## A use case file

One file per use case, **top level** in `embeddings/` (no subdirectories). Every file must export all three of `config`, `GET`, and `POST` — a missing half fails the deploy.

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

Each run drains the pending set in a loop: `GET` the next batch, chunk each row's `content` by the configured profile, embed all chunks in batched provider calls, then `POST` the results. The loop stops when `GET` returns `[]`, or after 20 batches (the run then re-pokes itself so the next sweep continues).

### `GET({ query, batch })`

- `batch: { limit, revision }` — request at most `limit` rows; compare `revision` against what's stored beside your vectors.
- Return an array of rows shaped `{ id, content, metadata? }`.
- **Return `[]` when drained.** Returning no body at all (a missing `return`) is an authoring error, not a drained corpus — the platform treats it as such rather than silently stopping.

### `POST({ query, batch })`

`batch: { revision, docs, failures }`:

- `docs`: `[{ id, metadata, chunks: [{ seq, content, metadata, embedding }] }]` — grouped per document, so delete-and-replace per doc (as in the example above) is the natural idiom.
- `failures`: `[{ id, error, permanent, skipped? }]` — see below.

Store `batch.revision` beside each vector and include `<> $revision` in your `GET` query.

### Revision: one string, three triggers

The `revision` the pump hands you couples your config (chunking profile, token budgets, `config.revision`) **to the resolved platform embedding model**. So a corpus-wide re-embed surfaces automatically as pending work when any of these change:

- you bump `config.revision`
- you change the chunking profile or token budgets
- an admin repoints the platform embedding model

No manual invalidation — the `revision <> $revision` clause in your `GET` finds everything.

### Failures and tombstones

Deterministic failures (content over the model's input cap, chunker errors) are reported in `failures` and **tombstoned platform-side by content hash** — an unembeddable document is attempted exactly once per content-and-config even if you ignore the array. Tombstoned rows are re-reported on **every** run with `skipped: true`, so stamp them in your own table and exclude them from your `GET` query, or they'll ride along in every batch report forever:

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
| `description` | Shown in the embeddings status listing |
| `chunking` | `none` (row = one embedding, the default), `prose` (markdown-aware recursive splitting with heading breadcrumbs), or `code` |
| `maxTokens` / `overlapTokens` | Splitter budgets for `prose`/`code`; `overlapTokens` must be less than `maxTokens` |
| `on` | Event names (from `emit()`) that trigger a run |
| `cron` | A cron schedule; desugars into an automation that triggers runs |
| `batchSize` | Rows requested per `GET` (1–1000, default 100) |
| `timeout` | Sandbox wall-clock per handler invocation, in milliseconds |
| `revision` | Author-bumped value that forces a corpus-wide re-embed |

**The schema is strict — unknown keys fail the deploy.** Don't park extra metadata in `config`.

## Triggers

Every trigger converges on the same platform poke, and runs take a **single-flight lease per use case**, so concurrent triggers coalesce instead of double-embedding:

- **Deploy** pokes each use case (initial backfill — a fresh deploy starts embedding immediately)
- **`emit()` events** matching `on:` poke
- **`cron`** automations poke
- **Manual run** via the `_run` route (below)

A background platform sweep executes pending use cases **as the app owner**.

## Workspace and pgvector

Apps with the embeddings capability get the `vector` extension provisioned in their workspace database. Migrations can declare real vector columns:

```sql
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

The `ON DELETE CASCADE` is the cleanup story — the platform never touches your vector tables, so your own foreign keys are what keep them in sync with the source rows.

### Searching: plain SQL + `embed(name, text)`

Search is ordinary SQL in your own `server/` handlers. The sandbox bag gains `embed(name, text)` for query-time vectors — **scoped to a declared use case** so query vectors come from the same model as the stored corpus:

```javascript
// server/search.js
export async function POST({ query, embed, request }) {
  const qv = await embed('tickets', request.body.q);
  return await query(`
    SELECT t.*, 1 - (e.embedding <=> $1::vector) AS score
    FROM ticket_embeddings e JOIN tickets t ON t.id = e.ticket_id
    ORDER BY e.embedding <=> $1::vector
    LIMIT 20
  `, [JSON.stringify(qv)]);
}
```

### Billing

Embedding calls are billed to the app — batched, one usage entry per provider batch, not per value. Pump compute is metered per handler invocation against the app's compute budget. `embed()` at query time is billed to the app too.

## Routes

### `GET /apps/{id}/embeddings`

Lists the app's embedding use cases with pump status: declared config (description, chunking, triggers, batch size), `revision`, `running`, `pending` (a poke is queued), `tombstoned` (count of permanently failed documents), `lastRunAt`, and `lastError`. Tombstone content hashes stay server-side.

**Permission:** read access to the App — it's status metadata, like the dependencies listing.

### `POST /apps/{id}/embeddings/{name}/_run`

Drains one use case immediately: claims the single-flight lease and executes the pump loop, returning `{ status, processed, failed, skipped, batches, drained }`. Returns `{ status: 'already_running' }` when a fresh lease is held; a lease older than 30 minutes (a crashed run) is reclaimed.

**Permission:** `permission.app.write`. Running the pump triggers billed provider calls, so the gate is a spend control, not just a data guard.

This is your debugging loop during development: deploy, `_run`, check `lastError` in the status listing, fix, repeat.

## Deploy behavior & gotchas

- `embeddings/` is uploaded and scanned like `server/` — `npm run deploy` is the whole setup, no manifest block.
- Projection rows reconcile per deploy: config and revision rebuilt, run state on surviving rows preserved, removed files drop their row. **Your vector tables are never touched** — dropping a use case file leaves its data for your migrations to clean up.
- A path collision between folders (`embeddings/x.js` next to `server/x.js`) fails the deploy with an error naming both files.
- **Pump handlers are never reachable through the app's own API surface or webhooks, and never appear in the app's `openapi.json`.** Only the pump invokes them. Don't try to call `GET`/`POST` from the frontend — put shared logic in a module both can import if you need it.
