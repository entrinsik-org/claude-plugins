# Connector Gotchas

Integration-specific traps that hand-rolled walkers rediscover one production
incident at a time. Check this file for your source BEFORE writing a walker;
add what you learn the hard way. Pair every new pipeline with a
`dryRun: true` pass (see `warehouse-etl.md` §4c) — a surprising receipt is
usually one of these.

## QuickBooks Online (QBO)

- **Name-list entities silently hide inactive rows.** `SELECT * FROM
  Customer` returns only `Active = true` — on a real org that can be ~10% of
  rows vanishing with no error. Applies to every name-list entity (Customer,
  Vendor, Employee, Item, Class, Department, ...). Always:
  `SELECT * FROM Customer WHERE Active IN (true, false)`.
- **Pagination is positional**: `STARTPOSITION n MAXRESULTS m` (1-based).
  There is no stable cursor — sort by `Id` (or `MetaData.LastUpdatedTime`
  for incremental) so pages don't shift under you mid-walk, and remember the
  hard cap is 1000 rows per page.
- **Header/line entities** (Invoice, Payment, CreditMemo, Bill) carry their
  lines inline. NEVER run two loads that each page the full entity — use the
  multi-table `into` map (`warehouse-etl.md` §4b): one pass fills
  `invoices` + `invoice_lines` and publishes them in one transaction.
- **Incremental**: filter `MetaData.LastUpdatedTime >= '<watermark>'` (read
  the watermark from your own table, overlap the boundary — the merge
  dedupes). Deletions do NOT appear here: use the ChangeDataCapture endpoint
  (`/cdc?entities=...&changedSince=...`) to learn about deleted ids, or
  schedule a periodic full sync (`prune: true`) to reconcile.
- **Custom/undocumented fields**: org-specific custom fields ride in
  `CustomField` arrays with numeric `DefinitionId`s — map them explicitly;
  never assume their presence or order across orgs.
- **Minor versions matter**: some fields only exist at newer
  `minorversion=` query params; pin one in the walker.

## Salesforce

- **FLS-hidden fields 400 the whole SOQL** (`INVALID_FIELD`), and which
  fields are hidden varies per org/profile. Verify the field list against
  `/sobjects/<Entity>/describe` before shipping a walker, and record removed
  fields in a comment.
- **`nextRecordsUrl` IS the cursor** — instance-relative; pass it straight
  back as the walker's cursor. `totalSize` arrives on page one, so progress
  is determinate from the start.
- **Incremental**: filter on `SystemModstamp >= <watermark>` (not
  `LastModifiedDate` — SystemModstamp also moves on system updates). Use
  `>=` overlap; second-precision truncation can never skip a row and the
  merge dedupes.
- **Soft deletes**: `queryAll` + `IsDeleted` reveals recycle-bin rows;
  a plain query never shows deletions — same remedy as QBO (periodic full
  sync with `prune: true`).

## Postgres WAL (test_decoding shippers)

- **A PK-changing UPDATE is secretly a DELETE + INSERT.** `test_decoding`
  emits it as one UPDATE line carrying two sections — `old-key: id[...]:5
  new-tuple: id[...]:9 ...`. Parse the whole line as one column bag and the
  delete silently vanishes: the warehouse keeps BOTH rows. Split on
  `old-key:`/`new-tuple:` and emit a delete event for the old key plus an
  upsert for the new tuple whenever the key changed.
- **`old-key:` only appears when the key changes** (or when the table has
  `REPLICA IDENTITY FULL`) — a plain UPDATE line has just the column bag.
  Handle both shapes.
- **Peek, ship, then advance.** `pg_logical_slot_peek_changes` + POST +
  `pg_replication_slot_advance` only after a 2xx gives at-least-once
  delivery; the warehouse's keyed merge makes replays converge. Never use
  `get_changes` (consumes on read — a failed POST loses the window).
- **Advance past noise too**: BEGIN/COMMIT lines and other tables' changes
  still occupy the slot. Advance to the last PEEKED lsn even when no
  mappable events were shipped, or the slot pins WAL forever.
