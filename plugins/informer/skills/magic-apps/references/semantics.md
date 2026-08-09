# Semantics — labels, descriptions, types, and enum values for your warehouse

Any app with a workspace database can ship a **semantic layer**: friendly
labels, descriptions, refined types, units, and enum-value labels that every
Informer BI surface reads — grids, pivots, charts, exports, the Data panel,
and SQL autocomplete. Declared once by you, resolved onto query replies at
runtime, internationalized per locale.

**Nothing here is required.** An app with no semantics renders fine (labels
auto-title from column names: `days_open` → "Days Open"). Semantics are
progressive enhancement — but for a marketplace warehouse they are part of
the product: every customer's grid formats correctly on install, in their
language, with zero per-tenant curation.

## The files

Two grammars, flat beside `informer.yaml`:

| File | Carries | Localized? |
|---|---|---|
| `semantics.yaml` | **Structure**: `type`, `unit`, `currency`, `values:` keys — plus optional inline default `label`/`description` for quick development | No |
| `semantics.<locale>.yaml` (e.g. `semantics.en.yaml`, `semantics.es-MX.yaml`) | **Strings only**: labels, descriptions, value labels | Each file IS one locale |

The strings grammar has no structural keys and the structure grammar has no
locale variants — mixing is unrepresentable, which is how ten locales can
never disagree about whether a column is a duration.

## The document — three sections

Every semantics file has up to three top-level sections:

```yaml
categories:   # category ENTITIES — id, label, visual identity
tables:       # per-table docs — the bulk of the file
links:        # declared relationships between tables
```

## Quick development (one file)

Start with inline defaults in `semantics.yaml` and ship nothing else:

```yaml
# semantics.yaml
tables:
  order_tasks:
    description: One row per workflow task on an order
    fields:
      owner:        { label: Owner }
      status:
        values: { open: Open, hold: On hold, done: Done, overdue: Overdue }
      due_date:     { label: Due, type: date }          # calendar date — no TZ shift
      completed_at: { label: Completed, type: date_tz } # instant — viewer's timezone
      days_open:    { label: Days Open, type: duration, unit: days,
                      description: 'Business days from creation to completion' }
```

- `values:` as a **map** declares the enum keys AND their default labels;
  as a **list** (`[open, hold, done]`) it declares keys only.
- `type` REFINES the pg type, never replaces it (pg says `numeric`, you say
  `currency`). Use Informer datatype vocabulary — the same one `load()`'s
  `columns:` declaration uses — never raw SQL types.
- **Quote any flow-map string containing a comma.** In
  `{ label: X, description: One thing, another thing }` YAML parses
  `another thing` as a NEW KEY — your description silently truncates and
  deploy warns `semantics_key_ignored`. Write
  `description: 'One thing, another thing'`.

## Curation — categories, category, and hidden

Explore's subject picker is a consumer surface: curate it. Categories are
**entities** with a visual identity; a table references one by id:

```yaml
# semantics.yaml
categories:
  operations:
    label: Operations       # inline default; localize in overlay files
    color: teal             # an ACCENT TOKEN name — never a hex
    icon: tasks             # one of the curated glyph names below

tables:
  order_tasks:
    label: Escrow Tasks
    category: operations    # an id REFERENCE into categories, not a string
    fields:
      sync_token: { hidden: true }   # plumbing — never reaches Explore
  _ingest_cursor:
    hidden: true            # retract the whole table from Explore
```

- `color` must name an accent token:
  `blue cyan green indigo orange pink purple red lightGreen teal
  lighterBlue deepPurple brightBlueGrey darkBlue`.
- `icon` must be one of:
  `building calendar chart database document finance globe inventory
  operations people sales security support tasks`.
- Unknown color/icon names degrade quietly (no accent, generic glyph) —
  a typo is cosmetic, never a broken picker.
- `hidden: true` (structure file only — overlays can't hide) retracts a
  table or column from CONSUMER surfaces. The builder-facing Data panel
  always shows the whole schema; hidden is curation, not security.
- **Hiding a foreign-key column does NOT hide the relationship** — Explore
  still offers the hop to the target table; only the raw id column
  disappears from rails and menus. Hide FK plumbing freely.
- Underscore-prefixed tables are already excluded everywhere; `hidden` is
  for plumbing that can't wear a `_` prefix.

## Links — declared relationships

Real foreign keys in your migrations are the FLOOR: Informer reads them
live from the catalog and offers the hop automatically. Declare a link
when the catalog can't see it, or to name it properly:

```yaml
# semantics.yaml
links:
  - from: order_tasks.order_id   # the link's identity — one link per from
    to: orders.id
    label: Order                 # what order_tasks calls the outbound hop
    reverse: Tasks               # what orders calls the incoming set
```

- **Views need links.** A view carries no FK constraints — without a
  declared link its columns can't reach related tables in Explore.
- `label` names the to-one hop from the `from` side; `reverse` names the
  to-many set seen from the target (skip the auto-pluralization guess).
- `from`/`to` are `"table.column"` pairs. Links are key pairings —
  richer join forms (composite keys, driver-specific joins for U2 and
  friends) are reserved future keys, not free-form SQL.
- `hidden: true` on a link suppresses a hop that exists but only confuses
  (noisy self-references, audit shadows).
- Deploy validates endpoints against the live catalog and warns on
  unknowns (the link still deploys — pump drift can add the column
  later); malformed and duplicate `from` entries are dropped with
  warnings.
- Curated multi-table shapes still belong in ordinary views
  (`order_context AS SELECT ... JOIN ...`) — links relate subjects,
  views compose them.

## Internationalizing (graduating to locale files)

When a pack gets serious about i18n, lift the strings into per-locale
overlays. English becomes a peer locale, not a privileged base:

```yaml
# semantics.es-MX.yaml — strings only, SPARSE on purpose
categories:
  operations: { label: Operaciones }     # entity labels localize
tables:
  order_tasks:
    description: Una fila por tarea de flujo de trabajo en una orden
    fields:
      owner:     { label: Responsable }
      status:
        label: Estado
        values: { open: Abierta, hold: En espera, done: Completada, overdue: Vencida }
      due_date:  { label: Vence }
      days_open: { label: Días abiertos }
      # anything omitted falls back: locale file → inline default → auto-title
links:
  - from: order_tasks.order_id           # addressed by from; strings only
    label: Orden
    reverse: Tareas
```

Never put `type`, `unit`, new `values` keys, `color`, `icon`, or a table's
`category` reference in a locale file — deploy ignores structure in
overlays with a warning. Locale files translate; they never define.

Date and number FORMATTING conventions (12/08 vs 08/12) come from the
viewer's locale at render time — never author them.

## Descriptions vs COMMENT ON — two channels, two audiences

- **`description:` in semantics files** — display-facing, localized, shown
  in BI tooltips and detail cards.
- **`COMMENT ON` in your migrations** — engineering-facing, single-locale,
  atomic with the DDL, visible in psql/`\d+`, DBeaver, and AI introspection
  (`col_description()`).

They are different things and nothing syncs them. Write both when they'd
say different things:

```sql
-- migrations/003-task-metrics.sql
ALTER TABLE order_tasks ADD COLUMN days_open numeric;
COMMENT ON COLUMN order_tasks.days_open IS
  'Recomputed nightly by the ingest drain; excludes hold intervals.';
```

## Customer layering (what happens after install)

Customers can overlay your semantics (relabel a column for their org) and
define their own SQL views over your schema — including **shadow views**
that replace a table for their BI users (their column-level security). Two
consequences for you as the vendor:

1. **Your semantics refresh wholesale on every deploy** — they are
   author-owned, like dependency descriptions. Customer overlays ride a
   separate layer and survive your upgrades.
2. **Your app's own server routes are unaffected by customer shadows**
   (they run against the base schema), but expect that the BI surface a
   customer sees may be a projection of yours. Don't fight it — renaming
   and masking are the customization contract working as designed.

A vendor upgrade that drops or renames columns will break customer views
referencing them — their views park as "broken" with the SQL error and
your upgrade proceeds. Be a good citizen: note column removals in your
CHANGELOG so customers can repair quickly.
