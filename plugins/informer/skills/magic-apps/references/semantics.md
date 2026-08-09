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

## Quick development (one file)

Start with inline defaults in `semantics.yaml` and ship nothing else:

```yaml
# semantics.yaml
order_tasks:
  description: One row per workflow task on an order
  fields:
    owner:        { label: Owner }
    status:
      values: { open: Open, hold: On hold, done: Done, overdue: Overdue }
    due_date:     { label: Due, type: date }          # calendar date — no TZ shift
    completed_at: { label: Completed, type: date_tz } # instant — viewer's timezone
    days_open:    { label: Days Open, type: duration, unit: days,
                    description: Business days from creation to completion }
```

- `values:` as a **map** declares the enum keys AND their default labels;
  as a **list** (`[open, hold, done]`) it declares keys only.
- `type` REFINES the pg type, never replaces it (pg says `numeric`, you say
  `currency`). Use Informer datatype vocabulary — the same one `load()`'s
  `columns:` declaration uses — never raw SQL types.

## Curation — category and hidden

Explore's subject picker is a consumer surface: curate it. Two table-level
keys (and one field-level) control what consumers see:

```yaml
# semantics.yaml
order_tasks:
  label: Escrow Tasks
  category: Operations        # groups the subject in Explore's picker
  fields:
    sync_token: { hidden: true }   # plumbing — never reaches Explore
_ingest_cursor:
  hidden: true                # retract the whole table from Explore
```

- `category` is a display string like a label — give it an inline default
  and translate it in locale files (`category: Operaciones`). Subjects
  group under their resolved category; uncategorized ones pool under
  "More".
- `hidden: true` (structure file only — overlays can't hide) retracts a
  table or column from CONSUMER surfaces. The builder-facing Data panel
  always shows the whole schema; hidden is curation, not security.
- Underscore-prefixed tables are already excluded everywhere; `hidden` is
  for plumbing that can't wear a `_` prefix.

## Internationalizing (graduating to locale files)

When a pack gets serious about i18n, lift the strings into per-locale
overlays. English becomes a peer locale, not a privileged base:

```yaml
# semantics.es-MX.yaml — strings only, SPARSE on purpose
order_tasks:
  description: Una fila por tarea de flujo de trabajo en una orden
  category: Operaciones
  fields:
    owner:     { label: Responsable }
    status:
      label: Estado
      values: { open: Abierta, hold: En espera, done: Completada, overdue: Vencida }
    due_date:  { label: Vence }
    days_open: { label: Días abiertos }
    # anything omitted falls back: locale file → inline default → auto-title
```

Never put `type`, `unit`, or new `values` keys in a locale file — deploy
rejects structure in overlays. Locale files translate; they never define.

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

## Links

Declare real foreign keys in your migrations — they ARE the link layer
(Informer reads them live from the catalog). Ship curated join paths as
ordinary views in migrations (`order_context AS SELECT ... JOIN ...`).
There is no separate link declaration to maintain.

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
