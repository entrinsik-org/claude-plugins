# Row & Column Security for an App's Database

> **Load this reference when:** an app's workspace tables will be queried by
> people outside the app (Datasets, Reports, SQL on the app's Datasource) and
> not everyone should see every row or column: declaring `share:` in
> `informer.yaml`, writing row-security policies or masked views in
> migrations, or explaining to an admin how Manage › Data access works.
>
> **Not in this file:** the old dataset-filter RLS for `access.datasets`
> (`informer-yaml.md` "With Row-Level Security"). That filters a Dataset the
> app reads. This file is about who may read the app's OWN tables.
>
> **Availability:** Informer **2026.2.0+**. Masked views and column rules
> also need **PostgreSQL 16+** on the workspace database; below it
> `inf_mask_view` raises and a column rule is reported broken, which closes
> its table to restricted readers. To detect the feature, read the deploy
> result: a server that applies `share:` answers a `share` block. Below the
> floor nothing here is enforced, so do not rely on it: keep sensitive
> tables out of an app whose Datasource will be shared, or publish a
> narrower set of tables for readers.

## The model in one screen

An app with a workspace has a Datasource. An admin shares it with Teams and
Users in **Manage › Data access**. Each of those readers queries through a
Postgres login of their own, so the database knows who is asking.

| Thing | Who makes it | What it does |
|---|---|---|
| **Variable** (`region`) | you declare it; an admin fills it | A named slot for values that decide ROWS |
| **Flag** (`pii`) | you declare it as a role; an admin switches it on | A named switch that decides COLUMNS |
| **Data role** | the admin | A bundle of variable values and flags, granted to Teams and Users |
| **Row rule** | you (`share.rules`) or the admin | "A row of T shows when its column C is one of the reader's values for V" |
| **Column rule** | you (`share.columns`) or the admin | "Column C of T is masked for readers without flag F" |

Your job as the author is the vocabulary and the defaults. The customer's
admin decides who gets what. Rules you declare are listed to the admin as
"From the app" and only a deploy changes them; rules the admin adds sit
beside yours and a deploy never touches them.

**Who is never restricted:** superusers and Admins of the team that owns the
app. Rules and masks do not apply to them. Everyone else, Publishers of the
owning team included, sees only what their data roles allow.

**Your own code is never restricted either.** Route handlers, ETL hooks and
migrations read as the table owner and get raw rows. Security here governs
readers of the Datasource, not `query()` inside the app. If an app page must
show a person only their rows, filter in the handler.

## 1. The declarative path (start here)

Most apps need nothing but this block. No SQL.

```yaml
# informer.yaml
roles:
  - id: pii
    name: Personal data

share:
  variables:
    region: Sales region code        # name: description
  rules:
    - { table: orders, column: region, variable: region }
  columns:
    - { table: customers, column: email, flag: pii, mask: email }
    - { table: customers, column: ssn,   flag: pii }      # mask defaults to blank
```

- **`share.variables`** — lowercase snake_case names. A value may be a
  description string, `{ description: "…" }`, or empty.
- **`share.rules`** — each entry needs `table`, `column`, `variable`, and the
  variable must be declared in `share.variables`.
- **`share.columns`** — each entry needs `table`, `column`, `flag`; the flag
  must be the `id` of an entry in `roles:`. `mask` is `blank` (NULL, the
  default), `email` (`a***@example.com`) or `last4`. `email` and `last4` need
  a text column. A column may be ruled once.
- A reader with **several values** for a variable sees rows matching any of
  them. A reader with **no value** sees none of the ruled rows.

What a deploy does with it:

- A malformed entry, an undeclared variable or an undeclared flag **fails the
  deploy** with a message naming the entry (`share.rules[0].variable "x" is
  missing from share.variables`).
- A rule that cannot be built (the table or column does not exist, a text
  mask on a non-text column) **fails the deploy** and rolls it back.
- Rules are rebuilt inside the same transaction as your migrations, so there
  is no moment when a table is live without its rules. You may freely drop
  or retype a ruled column in a migration: update `share:` in the same
  deploy.

## 2. Hand-written policies (when a rule is not enough)

A row rule is one test: column equals one of the reader's values. For
anything richer (two columns, a join to an assignments table, an OR with a
flag), write the policy yourself in a migration using the helpers Informer
puts in your schema:

| Helper | Returns |
|---|---|
| `inf_unrestricted()` | `true` for superusers and Admins of the owning team |
| `inf_vars('region')` | `text[]` — every value the reader holds for the variable |
| `inf_var('region')` | `text` — the single value, or NULL when the reader holds several |
| `inf_role('finance')` | `true` when a data role switches the flag on for the reader |

```sql
-- migrations/004-sales-security.sql
ALTER TABLE "sales" ENABLE ROW LEVEL SECURITY;
CREATE POLICY "region_scope" ON "sales" FOR SELECT
    USING ((SELECT "inf_unrestricted"())
        OR "region" = ANY((SELECT "inf_vars"('region'))::text[])
        OR (SELECT "inf_role"('finance')));
```

Rules that bite:

- **Wrap every helper in `(SELECT …)`.** Bare `inf_vars('region')` is
  evaluated once per row; the subselect is evaluated once per query. Deploy
  warns about a per-row call.
- **Keep the `::text[]` cast** (or the column's own type). Without it
  Postgres reads the subselect as a set of rows and the policy errors.
- **Always include `inf_unrestricted()`**, or the owning team's Admins lose
  their own data.
- **Declare what you read.** A policy that reads a variable missing from
  `share.variables`, or tests a flag missing from `roles:`, fails the
  deploy: no admin could ever grant it.
- **Do not write `TO some_role` and do not use column-level `GRANT`.** A
  reader's login is not a role you can name, and role names do not travel
  with the app. Deploy warns on both. A policy is for everyone and decides
  with the helpers; a column is hidden with a mask.
- **Prefer `inf_vars` to `inf_var`.** Admins can give a reader several
  values, and `inf_var` then returns NULL, which matches nothing.

Admin row rules are RESTRICTIVE policies layered over yours: they can narrow
what your policies allow, never widen it. A table you closed stays closed.

## 3. Masked views (when a column rule is not enough)

A column rule masks one column by one flag. For a computed mask, a mask
that depends on a variable, or hiding a column outright, declare a masked
view in a migration:

```sql
SELECT "inf_mask_view"('staff', $view$
    SELECT "id", "name", "phone",
           CASE WHEN (SELECT "inf_unrestricted"()) OR (SELECT "inf_role"('finance'))
                THEN "salary" END AS "salary"
    FROM "staff"
$view$);
```

- The view takes the table's place for every reader: same name, resolved
  ahead of the table, and readers lose direct access to the table itself.
- **It needs no WHERE.** The table's row policies still apply inside it, so
  a mask changes columns only.
- Keep every column the table has, in name and type, unless you mean to
  remove one. `inf_mask_email(text)` and `inf_mask_last4(text)` are there to
  use inside the view.
- To change a mask's columns, or before an `ALTER TABLE` on the table,
  drop it first: `SELECT "inf_unmask_view"('staff');` then declare it again.
  Postgres cannot drop or retype a view column in place, and a view blocks
  altering the columns it reads.
- An admin's column rule on the same table stacks on top of your masked
  view: a column you mask and they rule shows only to a reader who passes
  both.

## 4. Traps in your own schema

Deploy reports these as warnings once any table has a policy. Fix them; each
one is a way readers see data the rules say they should not.

- **A table with no row security** is open to every reader the Datasource is
  shared with. New tables are readable by default. If a table is sensitive,
  give it a rule or a policy; the admin's Row rules list shows which tables
  are open.
- **A plain view reads as its owner and ignores policies.** Create views
  over secured tables with `WITH (security_invoker = true)`.
- **A materialized view cannot be filtered by row security at all.** Do not
  put secured rows in a matview readers can reach.
- **A view that selects a masked or ruled column** would show it unmasked.
  While a column rule stands, Informer refuses readers any view of yours
  that shows the column, and tells the admin which views. Leave sensitive
  columns out of convenience views.

## 5. What the admin sees, and what to tell them

- The variables and flags you declare appear in every data role, ready to
  fill. Give variables a real description: it is the admin's only hint about
  what value to type (`region: Two-letter sales region, e.g. NE`).
- A variable no data role fills hides rows; the page warns the admin.
- An admin can bind a value to the reader instead of typing one:
  `$user.username` or `$user.<user field>`. One role ("Own accounts") then
  serves a whole team. Design columns so this works: store the Informer
  username, or a value held in a user field, on the row.
- **Datasets keep what they read.** Rules apply when a query reaches the
  Datasource. A Dataset stores the rows of its last refresh and shows them
  to everyone it is shared with. Say so in your `docs.html` if the data is
  sensitive.

## 6. Checking it works

1. Deploy. Read the deploy result's `share` block: `variables`, `unused`
   (declared but read by nothing: remove it or use it), `warnings`.
2. In Manage › Data access, share the Datasource with a non-admin test user
   and give them a data role with one value and no flags.
3. As that user, query the Datasource: rows narrow, flagged columns are
   masked. Test with your own admin account too, remembering that Admins of
   the owning team see everything, so an admin seeing all rows proves
   nothing.
4. Add the flag to the role and check the column appears.
