# Warehouses & ETL

An Informer App can be a **warehouse**: a Postgres workspace filled from the
app's dependency slots (datasources, integrations) on a schedule, queried by
people and other apps.

**A warehouse ships a small, deliberate UI.** Not a dashboard for its own
sake — a grounding surface: what this warehouse is, when each table was last
synced, a Sync button with live progress, reconciliation checks against the
source, and a pointer to docs. The platform deliberately provides **no
refresh buttons**: Informer GO's Data panel (available on every app with a
workspace) covers schema exploration, ad-hoc SQL, per-table data/pipeline/
history views, and live run progress — observation and query, never
orchestration. Refresh orchestration is yours, because only the app knows
its sequencing.

The authoring model is **migrations + routes + informer.yaml**:

```
migrations/           tables, PRIMARY KEYs, FKs, indexes, matviews
server/etl/*.js       routes that own the loads (call `load()`)
informer.yaml         dependency slots + `automations:` schedules
public/               the UI (index.html) + favicon.svg + docs.html
```

**Declare real PRIMARY KEYs (and FKs) in your migrations.** They are not
decoration — the PK is the default merge key for upsert loads, and FK
`ON DELETE` actions behave correctly because the upsert publish preserves
row identity (see §4).

## 1. The sync surface — choose entry points deliberately

Refresh sequencing usually matters: parents before children, cross-table
consistency, watermarks that assume a prior step ran. So the DEFAULT shape
is **one sync route** driving a multi-table load (§4b) — not a refresh route
per table. Expose a per-table entry point only when that table is genuinely
independent and refreshing it alone is safe.

Two kinds of routes, split by who calls them:

- **Sync/rebuild routes** are normal server routes — your UI POSTs them,
  `automations:` schedule them, and other apps can call them via a
  `target: app` slot. Gate them with `config.roles` (an ETL trigger is not
  an every-viewer affordance).
- **Pump hooks** (page walkers, batch handlers, `onComplete`/`onLoaded`)
  are `config.internal: true` — the pump invokes them directly, and
  internal routes 404 on EVERY HTTP dispatch path (your UI, automations,
  cross-app `request()`). Never mark a route internal if anything but the
  pump must reach it.

## 2. ETL routes

A sync route calls the `load()` bag helper and **returns its run
descriptor** — `{ id, status }`, the task your UI then watches.

```javascript
// server/etl/sync.js — THE sync entry point (one atomic multi-table load)
export const config = { roles: ['operator'] };   // NOT internal — the UI calls it

export async function POST({ load, request }) {
    return await load({
        from: { slot: 'quickbooks', pages: 'etl/fetch' },   // the walker IS internal
        into: {
            invoices: { key: 'id', prune: true },
            invoice_lines: { key: ['invoice_id', 'line_index'], prune: { scope: 'invoice_id' } }
        },
        mode: 'upsert',
        onLoaded: 'etl/loaded',            // e.g. REFRESH MATERIALIZED VIEW
        // ALWAYS wire this passthrough so `POST etl/sync {"dryRun": true}`
        // validates the whole pipeline without publishing (§4c)
        dryRun: request.body.dryRun,
        params: { full: request.body.full },   // rebuild = same route, full pull
        description: 'Sync QuickBooks warehouse'
    });
}
```

The frontend triggers it against its own server surface and watches SSE:

```javascript
const res = await fetch('/api/_server/etl/sync', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{}' });
const { id } = await res.json();
const events = new EventSource(`/api/tasks/${id}/events`);   // progress.records / total / stage → your progress bar
```

## 3. The `load()` spec

```javascript
await load({
    // ONE source form:
    from: { slot: 'src', query: { language: 'sql', payload: 'SELECT ...' } },  // datasource slot — the pump streams the query itself
    from: { slot: 'sf', pages: 'etl/fetch' },                                  // walker route + the slot it reads (integration OR datasource)

    into: 'leads',                 // must already exist (migration-created)
    mode: 'replace' | 'append' | 'upsert',
    key: ['id'],                   // upsert only; defaults to the table's PRIMARY KEY
    prune: true,                   // upsert only; delete live rows absent from this run

    batch: {
        size: 5000,
        handler: 'etl/clean',      // per-batch transform route (rows in → rows out)
        onError: 'fail' | 'skip' | { retry: 3 }   // 'skip' is invalid for pages sources
    },
    onComplete: 'etl/finalize',    // runs against the STAGING build (run.target), pre-publish
    onLoaded: 'etl/loaded',        // runs after the data is LIVE — matview refreshes go here
    onError: 'etl/fail-log',
    emit: 'leads:refreshed',       // app event, fired only on full success
    params: { full: true },        // opaque; delivered verbatim to every hook invocation
    columns: { CreatedDate: 'date' },  // declared types refining inference (drift gate + receipt)
    description: 'Refresh leads'
});
// → { id, status: 'queued' }  — the task; RETURN THIS from your route
```

Teaching errors (surface on the task): `table_missing` (write a migration),
`schema_drift` (`{ newColumns, typeChanges }` — write an ALTER migration),
`upsert_key_missing` (declare a PK or pass `key`).

## 4. Publish semantics — pick the right mode

All staged modes build in a hidden staging table (an exact shape-clone of the
live one), COPY batches into it, run `onComplete` against it, then publish in
**one transaction**. Readers never see partial data; dependent views,
matviews, policies, and grants never detach.

- **`upsert`** — the default choice for any table with a key. Publishes as a
  keyed merge: duplicate keys within a run are safe (last-arrived wins, so
  overlap-window walkers are idempotent by construction), unchanged rows are
  skipped entirely (no UPDATE triggers, no WAL), and `prune: true` deletes
  rows that left the source. Row identity is preserved, so FK `ON DELETE`
  actions fire only for rows that genuinely departed. Run receipts report
  `inserted / updated / unchanged / pruned` — **on the task's `progress`**
  (`GET /api/tasks/{id}`), NOT on the 202 dispatch body, which is only
  `{ id, status }`.
- **`replace`** — full refill (DELETE + INSERT cutover) for keyless tables.
  Note it rewrites every row each run — with FK children or audit triggers,
  prefer `upsert` + `prune`.
- **`append`** — straight COPY into the live table; pair with a watermark in
  your walker for incremental feeds where a merge isn't needed.

## 4b. Multi-table loads — one source pass, one atomic publish

When one source entity feeds several tables (the header/line pattern: a QBO
Invoice carries its lines), do NOT run two loads that each page the whole
entity — that doubles the API calls AND publishes at different times, so the
warehouse holds parents whose children are stale between the two publishes.
Instead, make `into` a map and let ONE walker feed every table:

```javascript
await load({
    from: { slot: 'quickbooks', pages: 'etl/invoices/fetch' },
    into: {
        // declaration order is publish order: parents FIRST
        invoices: { key: 'id', prune: true },
        invoice_lines: { key: ['invoice_id', 'line_index'], prune: { scope: 'invoice_id' } }
    },
    mode: 'upsert'   // a multi-table map is always merge semantics
});
// the walker returns rows as a map:
// { rows: { invoices: [...], invoice_lines: [...] }, cursor }
```

- **One transaction publishes everything**: merges run in declaration order
  (parents first, so children's FKs resolve), prunes run in reverse
  (children first). There is no moment between the tables' publishes —
  FK-linked tables are consistent by construction.
- **`prune: { scope: 'invoice_id' }`** is the incremental-child rule: delete
  a child row only when its parent (scope value) appeared in this run's
  staging but the row didn't. Untouched parents keep all their children. A
  bare `prune: true` on a child of an incremental run would wipe every
  unchanged parent's children — scope is what makes child prune safe.
- Map values: `'id'` (key shorthand) | `['col','col']` | `{ key?, prune? }`
  (key defaults to the table's PK). With a pages source, a batch `handler`
  receives and returns the same `{ table: [...] }` map. Per-table receipts
  land under `progress.tables`.
- `columns` overrides and top-level `key` don't apply to the map form.

**Query-fed multi-table (the JOIN-split form).** A SQL source can feed the
map directly: run ONE denormalized `header JOIN lines` query and make the
batch handler the splitter — it receives each **flat batch array** and
returns the `{ table: [...] }` map (the one asymmetry vs. a pages-source
handler, which receives a map). The handler is REQUIRED in this form.

```javascript
await load({
    from: { slot: 'truerev', query: { language: 'sql', payload: INVOICE_JOIN_SQL } },
    into: {
        invoices: { key: 'id', prune: true },
        invoice_lines: { key: ['invoice_id', 'line_index'], prune: { scope: 'invoice_id' } }
    },
    mode: 'upsert',
    batch: { handler: 'etl/split' }   // flat rows in → { invoices, invoice_lines } out
});
```

Do NOT dedupe the repeated header rows in the splitter — the merge dedupes
them within the run (last-arrived wins) and no-ops unchanged rows against
live, so a straight `rows.map(...)` per table is correct by construction.
Bonus over a keyset walker: the query form gets the COUNT(*) probe, so the
run reports real percent progress (`progress.records` counts source rows).

## 4c. Dry runs — validate the mapping before it runs at 3am

`dryRun` runs the REAL pipeline on a sample and publishes nothing:

```javascript
await load({ ...same spec..., dryRun: true });          // 2 pages / 1000 rows
await load({ ...same spec..., dryRun: { pages: 5 } });  // or { rows: N }
```

What it validates, in order:
1. **Merge arbiter up front** — upsert keys without a unique index fail
   immediately (`upsert_key_unindexed`) instead of at publish time.
2. **The mapping against the real DDL** — staging is built WITH the live
   table's NOT NULL and CHECK constraints, so a mapper emitting a null into
   a required column (or violating any CHECK) fails at COPY, naming the row.
   Transforms run; finalize/onLoaded/emit/prune are skipped.
3. **Would-be receipts** — read-only comparison against live reports
   `inserted / updated / unchanged / pruned` for what a real run WOULD do
   (`progress.dryRun: true` marks the task). A surprising `pruned` count
   here is the "hidden inactive rows" class of bug caught before it deletes
   anything.

Make a dry run part of every new pipeline's bring-up: build the walker →
`POST etl/sync {"dryRun": true}` (with the §2 passthrough) → read the
receipts → then wire the schedule.

## 5. Page walkers (integration sources)

A `pages` source names an internal route the pump invokes once per page.
It fetches through the integration slot and speaks this contract:

```javascript
// server/etl/fetch.js
export const config = { internal: true };   // pump-only — 404s over HTTP

export async function POST({ context, query, request }) {
    const { cursor, page, params } = request.body;   // params from the load() spec
    // first page: run the query (optionally from a watermark you read out of
    // your own table — `await query('SELECT MAX(...) FROM leads')`);
    // later pages: follow the cursor
    const res = cursor
        ? await context.sf.request({ method: 'GET', url: cursor })
        : await context.sf.request({ method: 'GET', url: '/services/data/v59.0/query', params: { q: SOQL } });
    const rows = res.records.map(({ attributes, ...fields }) => fields);
    return res.done
        ? { rows, done: true, total: res.totalSize }
        : { rows, cursor: res.nextRecordsUrl, total: res.totalSize };
}
```

Reply shape: `{ rows, cursor?, total?, done?, retryAfterMs? }`. Guards the
pump enforces: the cursor must advance, must stay small (≤4KB), and 25
consecutive empty pages without `done` aborts the walk. With `upsert`,
overlap your watermark window (`>=`) freely — the merge dedupes.

**Datasource-slot walkers.** `pages` works over a `target: datasource` slot
too — the walker fetches through `context.<slot>.query(...)` with a keyset
cursor (`WHERE id > $cursor ORDER BY id LIMIT n`). Reach for it when the
walk itself must be stateful (per-window child queries, watermark logic the
splitter can't express); otherwise prefer the simpler `query:` forms — the
pump streams and batches them, and multi-table SQL sources have the
JOIN-split form (§4b).

Before writing a walker for a specific integration, check
`connector-gotchas.md` — hidden-inactive-row defaults, pagination quirks,
and deletion-detection traps are documented per connector there.

## 6. Scheduling & the platform surface

Schedules are plain `automations:` in informer.yaml, targeting your sync
route — cadence lives next to the route it fires, deployed atomically.
**Automation routes are dispatched as GUEST paths**, so a route that lives
in `server/` MUST carry the `/_server/` prefix — without it the dispatch
404s silently (the automation row keeps advancing `nextRunAt`, no task ever
appears):

```yaml
automations:
  nightly-sync:
    route: /_server/etl/sync    # server/etl/sync.js — /_server/ is REQUIRED
    interval: '0 3 * * *'
    payload: {}
```

What the platform provides (observation, not orchestration):

- `GET  /api/apps/{id}/tasks` — the app's run ledger (progress, receipts,
  timings, recorded spec). Allowlist as `GET /api/apps/*/tasks`. (The flat
  `GET /api/tasks?appId={id}` form also works on current servers.)
- `GET  /api/tasks/{taskId}/events` — live SSE for one run.
- **Informer GO's Data panel** — schema rail with live run %, SQL
  scratchpad, per-table Data/Schema/Pipeline/History views. It discovers
  in-flight runs from the ledger, so a sync your UI (or a cron) kicks shows
  live there with no wiring on your part.

Allowlist note: `access.apis` patterns match the PATH only — a query string
never affects matching, so `GET /api/tasks` allows `tasks?appId=…`.

## 7. Row security — scope shared data by viewer

A warehouse shared broadly needs row policies. Every workspace ships helper
functions for exactly this; policies are authored in migrations like all
structure, and the vocabulary they read is declared in the manifest:

```sql
-- migrations/00X-row-security.sql
ALTER TABLE "invoices" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "rep_scope" ON "invoices" FOR SELECT
    USING ("inf_unrestricted"() OR "ownerRep" = (SELECT "inf_var"('rep_id')));
```

```yaml
# informer.yaml — REQUIRED for every variable a policy reads:
# deploy cross-checks pg_policies and FAILS on undeclared refs
share:
  variables:
    rep_id: The rep's Salesforce user id
```

How it works at query time: consumer reads (the GO Data panel, datasource-
share slots in other apps) run as a read-only role stamped with the
requester's context — `inf_var('x')` returns the value their datasource
share granted (a fixed literal, or a `$user.<attr>` binding like
`$user.email` resolved per requester), and `inf_unrestricted()` is true for
the owner/admins. **Fail-closed by construction**: no share variable → NULL
→ no rows. Your own routes, hooks, and ETL run as the owner role, which
OWNS the tables — Postgres never applies RLS to the table owner, so loads
and finalize hooks always see raw data.

**THE LEAK EVERY POLICY-BEARING WAREHOUSE MUST CLOSE**: your own `server/`
routes read through the OWNER connection, which owns the tables — Postgres
never applies RLS to the table owner, so `query()` in a handler ALWAYS
returns raw, unfiltered rows. That is correct for ETL and finalize hooks —
and a data leak the moment a handler feeds rows to your UI for a shared
viewer. Once policies exist, every viewer-facing read must go through the
workspace DATASOURCE as the signed-in user, where the policy applies per
requester:

```javascript
// frontend — allowlist `POST /api/datasources/*/_query` in access.apis
await fetch(`/api/datasources/${wsDsId}/_query`, {
    method: 'POST', headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ language: 'sql', payload: 'SELECT ...', limit: 100, options: {} })
});
```

Audit the classic offenders: a `/rows` or `/dashboard-data` route that
SELECTs and returns rows, KPI aggregates computed in a handler, exports.
Either move those reads to the datasource `_query` path, or accept that
the route serves owner-privileged data and OWNER-GATE it:

```yaml
roles:
  - id: raw_data          # declare a role you grant to nobody
    name: Raw data access
```
```javascript
export const config = { roles: ['raw_data'] };
```

Role resolution's admin override gives owning-team Publishers+ (and
superusers) every DECLARED role implicitly — so the owner passes, shared
viewers 403, and an explicit app-share grant of `raw_data` becomes the
deliberate exception. TRAP: the role MUST appear in the manifest `roles:`
block — with zero declared roles the resolver returns empty for everyone
(before the admin override), locking out the owner too. Note this is a
binary invocation gate, not row filtering — scoped viewing always means
the `_query` path.

Rules of thumb:
- Always author the `inf_unrestricted() OR …` idiom — without it the owner
  sees nothing in the Data panel.
- Keep the `(SELECT inf_var('x'))` initplan form — it evaluates once per
  query, not per row.
- The Data panel shows viewers their own enforcement: a shield on policy-
  bearing tables, a "Filtered view" footer listing their resolved
  variables, and each table's policies under Schema.

### Column masking (CLS) — inf_mask_view

To hide or transform COLUMNS (salaries, emails, SSNs), create a **masking
view** from a migration with `inf_mask_view(name, sql)`. The view lands in
a platform-managed masked schema that consumers resolve FIRST — so a view
named like a table transparently replaces that table for every consumer
read (Data panel, reports, other apps), with **no SQL changing anywhere**.
The platform also revokes the same-named base table from the consumer
role automatically, so a schema-qualified reach for raw data is
permission-denied.

```sql
-- migrations/00X-mask-invoices.sql  (note: '' doubles quotes inside the arg)
SELECT "inf_mask_view"('invoices',
    'SELECT "id", "customer",
            CASE WHEN "inf_unrestricted"() THEN "amount" ELSE NULL END AS "amount",
            "inf_mask_email"("contact") AS "contact"
     FROM "invoices"
     WHERE "inf_unrestricted"() OR "ownerRep" = (SELECT "inf_var"(''rep_id''))');
```

TWO RULES that make masked views correct:

1. **Re-apply row scoping in the view's WHERE.** Masked views run with
   OWNER rights (that's what lets them read the revoked base), which means
   the base table's RLS does NOT apply inside them — a masked view without
   the `inf_unrestricted() OR …` WHERE serves every row to every consumer,
   just with masked columns. The WHERE is the row layer; the SELECT list
   is the column layer; author both.
2. **Derived objects are separate exposures.** A matview or plain view
   computed FROM a masked/policied table is its own relation with its own
   access: matviews are owner-computed snapshots (raw, unscoped data
   frozen at refresh), and owner-schema views are owner-rights by default.
   Masking `invoices` does NOT protect `invoices_by_rep`. For each derived
   object, either confirm it aggregates to genuinely non-sensitive
   granularity, or give it its own inf_mask_view treatment.

Joins compose for free: any unqualified reference — `JOIN invoices`,
`EXISTS (SELECT … FROM invoices)`, CTEs — resolves to the masked view, so
its scoping and masks apply before the join, and a join condition on a
masked column compares the MASKED value (NULL matches nothing).

## 8. Streaming ingest — point any HTTP sink at your webhook

For continuous data (pg WAL/CDC via Debezium, Kafka via Connect's HTTP
sink, Stripe/Segment events), the warehouse is the SINK, not the pipeline:
the customer runs the shipper they already know, aimed at the app's
HMAC'd webhook. At-least-once delivery is fine — the keyed merge makes
replays converge.

**Edge (thin by design)** — the webhook authenticates, appends RAW events
to the platform's `_ingest` buffer, and kicks the drain with `schedule()`:

```javascript
// webhooks/events.js — one durable insert, no transformation here
await query(
    'INSERT INTO "_ingest" ("payload") SELECT * FROM jsonb_array_elements($1::jsonb)',
    [JSON.stringify(events)]
);
// coalescing kick — seconds of latency instead of waiting for the cron
await schedule('/_server/etl/drain', { delay: 1000 });
```

`schedule(route, { delay, payload, key })` is a sandbox primitive (routes,
webhooks, tools): it registers a deferred invocation of one of the app's
own routes, fired as the app owner — same dialect as `automations:` routes,
so server routes carry `/_server/`. Timers **coalesce**: while a kick for
the same key is pending, further calls are no-ops that keep the EARLIER
fire time — a burst of appends costs one drain, and latency stays bounded
at `delay` under constant traffic. `delay` clamps to 0–60s (longer cadence
belongs to an automation). Timers are in-process and lost on restart by
design: `schedule()` buys latency, the minute-cron automation remains the
durable sweeper. Have the drain answer a concurrent-run 409 from `load()`
with `{ busy: true }` — the running drain's cursor advance covers the rows.

**Drain (a load(), kicked by schedule() + swept by a minute cron)** —
consumes buffered events in order through a REQUIRED mapping handler:

```javascript
return await load({
    from: { ingest: true },              // the buffer is the source
    into: 'invoices',
    mode: 'upsert',                      // drains are always keyed merges
    batch: { handler: 'etl/apply-events' }
});
```

```javascript
// etl/apply-events.js — raw events in, three channels out. Debezium-ish:
export const config = { internal: true };
export async function POST({ request }) {
    const out = { rows: [], deletes: [], dead: [] };
    for (const e of request.body.rows) {           // [{ seq, payload, receivedAt }]
        const p = e.payload;
        if (!p.op) { out.dead.push({ seq: e.seq, reason: 'no op' }); continue; }
        if (p.op === 'd') out.deletes.push({ id: p.before.id });
        else out.rows.push(p.after);               // c/u/r — snapshot reads
    }                                              // flow the SAME path: backfill
    return out;                                    // and stream are one code path
}
```

The contract, and why it's safe:
- **`deletes`** apply as targeted key deletes in the same atomic publish —
  the CDC delete primitive (prune remains full-sync-only).
- **`dead`** is for events the mapping DECIDES are trash (→ `_ingest_dead`
  with a reason; drain continues) — never a fallback for events it failed
  to handle.
- **Unexpected throws STALL the drain**: no retry/skip policy exists. The
  watermark advances only inside the committed publish, so the next drain
  replays the same window. Skipping a CDC event silently is divergence,
  not resilience. A schema-bearing event stalls with `schema_drift` → ship
  the ALTER migration → the drain resumes and replays.
- **Bring-up ritual**: let real events accumulate, run the drain with
  `dryRun: true`, read the would-be receipts, THEN schedule it.
- Receipts add `deleted` and `dead`; per-key ordering is the transport's
  job (buffer seq preserves arrival). Multi-table `into` maps work — the
  handler returns `{ table: [...] }` maps per channel.
- The buffer tables are owner-only (raw events are pre-mask, pre-policy —
  consumers can never read them) and applied events age out after 72h.

## 9. The UI — small but real

Always ship an `index.html` (headless warehouses are not a supported
pattern — an app with no entry point renders the server's error page). The
warehouse UI's jobs, in priority order:

1. **Ground the user**: what this warehouse holds, where it comes from,
   per-table as-of lines (derive from the tasks ledger).
2. **The sync affordance**: one button → `POST /api/_server/etl/sync` →
   progress via the task's SSE stream. Add a per-table refresh only where
   refreshing that table alone is truly safe.
3. **Reconciliation checks**: a query against the warehouse vs. a spot
   total from the source (e.g. AR aging vs. QBO's own report) — the trust
   feature no generic surface can provide.
4. **Docs**: a `docs.html` (see `docs-html.md`) explaining tables, cadence,
   and caveats.

Ad-hoc exploration (arbitrary SQL, schema browsing, run history) does NOT
belong in your UI — the platform Data panel already does it for every
viewer with datasource read access.
