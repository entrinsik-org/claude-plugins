# `informer.yaml` Deep Reference

> **Load this reference when:** writing or modernizing `informer.yaml` — declaring `dependencies:` slot fields (`target`, `runAs`, `options`, `defaultBinding`), wiring row-level security via `$user.*` variables, migrating a legacy `access:` block to typed slots, or deciding when `access.apis:` / `access.libraries:` still apply.
>
> **Not in this file:** how handler code calls the slots (`context.<slot>.method()`) — see SKILL.md "Accessing Your Dependencies". Widget declarations (`widgets:` block) — see `widgets.md`. Agent declarations (`agents:` / `events:` blocks) — see `agents.md`. Custom role definitions (`roles:` block) — see SKILL.md "App Roles".

Apps are configured with an `informer.yaml` file in the project root. This single file declares the app's **data dependencies** (typed slots that get bound at install time), any **raw API allowlist** the app needs, **widgets**, **agents**, and **custom roles**. It's uploaded automatically on deploy.

```yaml
# informer.yaml

# Typed slots the installer binds at first deploy. Slot names are referenced
# from server-side handler code as `context.<slot>.<method>(args)` and from
# frontend code via runtime binding discovery — see SKILL.md "Accessing
# Your Dependencies" for the patterns.
dependencies:
  sales:
    target: dataset                                          # one of: dataset, query, datasource, integration
    description: Sales fact table
    defaultBinding: 7d5a9b1e-0c83-4bde-9e2a-3a4b5c6d7e8f     # UUID — pre-binds on first deploy. Look up via GET /api/datasets-list.
  customers:
    target: dataset
    defaultBinding: 1f2e3d4c-5b6a-7980-1234-56789abcdef0
  monthly_summary:
    target: query
    defaultBinding: 9a8b7c6d-5e4f-3a2b-1c0d-fedcba987654
  salesforce:
    target: integration

# Raw API allowlist for endpoints that don't fit the typed-slot model.
# Coexists with `dependencies:`; both are honored.
access:
  apis:
    - GET /api/apps-list

roles:
  - id: viewer
    name: Viewer
    description: Can view reports but not take actions
  - id: approver
    name: Approver
    description: Can approve or reject requests
```

## Rule of thumb (READ THIS BEFORE WRITING TO informer.yaml)

**For typed resources (dataset / query / datasource / integration): always use `dependencies:` slots. Never `access: datasets:`, `access: queries:`, `access: integrations:`, or `access: datasources:`.**

The legacy `access:` block for typed resources still works at runtime, but:

- It bypasses the install/rebind UI — every change forces a manifest edit + redeploy.
- It doesn't support the typed-proxy dispatch (`context.<slot>.search(...)`) — handlers would have to hand-build URLs.
- `npx informer-init`'s older scaffolds wrote empty `access: { datasets: [] }` blocks; if you find one in an existing `informer.yaml`, **replace it with `dependencies:`** — don't preserve the legacy shape "for consistency with the existing file."

`access:` keeps **one** legitimate use: the `apis:` sub-block for raw API paths that don't fit the typed-slot model (e.g. AI model endpoints, custom server routes). Everything else goes under `dependencies:`.

**Important:** Without either a populated `dependencies:` section or an `access:` declaration, ALL API access is blocked when the app runs in Informer.

## `dependencies:` slot fields

| Field | Required | Description |
|-------|----------|-------------|
| `target` | yes | `dataset`, `query`, `datasource`, or `integration` |
| `description` | no | Author-facing copy shown in the install/rebind UI |
| `runAs` | no | `user` (default) or `owner`. `owner` bypasses the viewing user's permissions — use sparingly |
| `options` | no | Per-target options (e.g. dataset filters), validated against the driver's schema |
| `defaultBinding` | no | A **UUID** the slot binds to automatically on first deploy. UUIDs (not configIds) so the binding survives a bundle export/import and isn't broken by users renaming the underlying resource. Look up the UUID from the resource's list endpoint (e.g. `GET /api/datasets-list`). **Never overwrites a binding the installer has already chosen** — re-deploys won't silently rewire a hand-bound slot. |

> **Legacy note:** You can also use a standalone `data-access.yaml` file (without the `access:` wrapper key). If both files exist, `informer.yaml` takes precedence. New apps should use `informer.yaml` with `dependencies:` since it supports typed slots, raw API allowlists, widgets, and roles in one file.

## Migrating an old `access:` app to `dependencies:`

Older apps declared their data via `access:` blocks. The runtime still extracts those, but they don't surface in the install/rebind UI — every change requires editing the YAML and redeploying. Convert them to `dependencies:` slots so the install panel can re-bind without manifest edits.

**Safety net: a snapshot is taken automatically — but only when there's something to migrate.** When the server-side modernize route finds at least one entry to convert, it snapshots the live app (manifest, library files, workspace data) *before* rewriting anything. If the result is wrong, restore from the returned `snapshotId`. If nothing migratable is found, the route short-circuits with `unchanged: true` *before* snapshotting — no snapshot churn on no-op calls. You can also open a draft first if you'd rather review before applying — drafts still work but aren't required.

The recipe Claude follows when asked to modernize:

1. Read the current `informer.yaml` (or legacy `data-access.yaml`).
2. For each entry under `access.datasets` / `access.queries` / `access.datasources` / `access.integrations`, generate a `dependencies:` slot:
   - **Slot name** — derive from the resource's `naturalId` last segment, snake-cased. `admin:northwind-orders` → `northwind_orders`. Resolve clashes by appending the resource type or a number.
   - **`target`** — singular form of the parent section (`datasets` → `dataset`, etc.).
   - **`defaultBinding`** — the resource's **UUID** (resolve via the matching `*-list` endpoint, e.g. `GET /api/datasets-list`). UUIDs survive bundle round-trips and aren't broken by configId renames; configIds in `defaultBinding` will be rejected at deploy.
   - Carry `filter` / `headers` / `params` / `paths` (when present on a structured access entry) into `options:`.
3. Remove the migrated entries from `access:`. **Keep `access.apis`** — raw paths don't have a slot model.
4. Update any server-side handler code that referenced these resources by `naturalId` to use the slot name instead (`context.northwind_orders.search({...})` etc. — the slot name is a property of `context`, not nested under `context.dependencies`).
5. Deploy the draft. Auto-bind runs through `defaultBinding`. Any unresolvable `defaultBinding` fails the deploy with a slot-named error so the YAML can be fixed.
6. Review via the draft diff, then commit.

```yaml
# Before
access:
  datasets:
    - admin:northwind-orders
    - id: admin:orders
      filter:
        region: $user.custom.region
  queries:
    - admin:daily-summary
  apis:
    - POST /api/models/go_everyday/_object

# After — defaultBinding values are UUIDs resolved from each
# configId via the matching `*-list` endpoint at modernize time.
dependencies:
  northwind_orders:
    target: dataset
    defaultBinding: 7d5a9b1e-0c83-4bde-9e2a-3a4b5c6d7e8f
  orders:
    target: dataset
    defaultBinding: 1f2e3d4c-5b6a-7980-1234-56789abcdef0
    options:
      filter:
        region: $user.custom.region
  daily_summary:
    target: query
    defaultBinding: 9a8b7c6d-5e4f-3a2b-1c0d-fedcba987654
access:
  apis:
    - POST /api/models/go_everyday/_object   # raw API — stays in access
```

## `env:` (environment variables)

Apps declare environment variable **keys** their handlers read at runtime.
Values are NOT stored in `informer.yaml` — they live encrypted in the app's
Environment, set per-tenant via the **Admin → Environment** tab.

```yaml
env:
  STRIPE_KEY:
    description: Stripe secret key for live API calls
  API_BASE_URL:
    description: Base URL of the upstream API the app talks to
  WEBHOOK_SECRET:
    description: HMAC secret for inbound webhook signature verification
```

**What deploy does with this:**

- For each declared key, the deploy seeds an **unset placeholder** row in the
  app's Environment (value `NULL`). The keys appear in the Admin → Environment
  tab as "Not set" so an installer knows exactly which secrets to fill in for
  their tenant.
- Reconciliation is **additive only** — re-deploys sync each row's
  `description` from the manifest but **never touch a value** the installer
  has set, and **never delete** a row whose key was removed from the manifest
  (env rows are user data, not deploy-derived projections).

**Accepted shapes** (all tolerated — pick what reads best in your manifest):

```yaml
env:
  STRIPE_KEY:                   # bare key, no description
  API_URL: Base URL of the API  # bare string is treated as the description
  GREETING:
    description: Friendly app greeting (not secret — safe demo value)
```

**Reading them in handlers** — the `env` bag is injected into every server
route, webhook, and agent tool:

```javascript
// server/charge.js
export async function POST({ env, fetch }) {
    const res = await fetch('https://api.stripe.com/v1/charges', {
        method: 'POST',
        headers: { Authorization: `Bearer ${env.STRIPE_KEY}` },
        // ...
    });
}
```

Only keys with a value present appear in `env` — declared-but-unset keys are
absent, so `env.STRIPE_KEY` is `undefined` until the installer fills it.
Values are **encrypted at rest** and **never returned** by any API; the
Environment tab shows masked previews only.

**Cross-tenant bundles:** when an app is exported and imported into another
tenant, keys + descriptions travel but **values do not** — the receiving
installer fills them per-tenant. (Encryption is tenant-scoped, so values
couldn't be re-used across tenants anyway.)

> **Legacy note:** earlier guidance told app authors to `PUT /api/apps/{id}`
> with `{ defn: { env: { … } } }`. That path is gone — it leaked secrets in
> plaintext through `GET` responses. Use the Environment tab (or declare keys
> in `env:`) instead.

## Basic Data Access Example

```yaml
# informer.yaml
# defaultBinding values are UUIDs from each resource's *-list endpoint
# (GET /api/datasets-list, /api/queries-list, /api/datasources-list,
# /api/integrations-list). configIds like `admin:sales-data` are
# rejected at deploy.
dependencies:
  sales:
    target: dataset
    defaultBinding: 7d5a9b1e-0c83-4bde-9e2a-3a4b5c6d7e8f
  customers:
    target: dataset
    defaultBinding: 1f2e3d4c-5b6a-7980-1234-56789abcdef0
  monthly_summary:
    target: query
    defaultBinding: 9a8b7c6d-5e4f-3a2b-1c0d-fedcba987654
  salesforce:
    target: integration                  # no defaultBinding — installer picks
```

## With Row-Level Security

Restrict data based on the viewing user's profile. Filters live under each slot's `options`:

```yaml
# informer.yaml
dependencies:
  orders:
    target: dataset
    defaultBinding: 1f2e3d4c-5b6a-7980-1234-56789abcdef0
    options:
      filter:
        region: $user.custom.region      # Users only see their region's data
  sales:
    target: dataset
    defaultBinding: 7d5a9b1e-0c83-4bde-9e2a-3a4b5c6d7e8f
    options:
      filter:
        sales_rep: $user.username        # Users only see their own records
```

## Integration with Credentials

Pass user-specific credentials to external APIs via the slot's `options`:

```yaml
# informer.yaml
dependencies:
  partner_api:
    target: integration
    defaultBinding: 5a6b7c8d-9e0f-1234-5678-9abcdef01234
    options:
      headers:
        Authorization: Bearer $user.custom.partnerToken
      params:
        client_id: $tenant.id
```

## Available Variables

| Variable | Description |
|----------|-------------|
| `$user.username` | Login name |
| `$user.email` | Email address |
| `$user.displayName` | Full name |
| `$user.custom.xxx` | Custom user field |
| `$tenant.id` | Tenant ID |
| `$report.id` | App UUID |

## Resource Types

The four typed-slot targets and what API surface each one's bound resource exposes:

| `target` | API surface | Slot methods |
|----------|-------------|--------------|
| `dataset` | `_search`, `fields` | `context.<slot>.search(esQuery)` / `.fields()` |
| `query` | `_execute` | `context.<slot>.execute(params)` |
| `datasource` | `_query` | `context.<slot>.query(payload)` |
| `integration` | `request` | `context.<slot>.request({ method, url, params, data })` (axios-shaped: `url` not `path`, `data` is the body) |

> **`libraries` is not a typed slot.** Library access lives only in the legacy `access.libraries:` whitelist block (`contents/*`) — there is no `target: library` slot model. Use `access.libraries:` if your app needs to read files from another library; everything else goes under `dependencies:`.

For raw API paths that don't fit the slot model (custom endpoints, AI model routes), use `access.apis:`:

```yaml
# informer.yaml
access:
  apis:
    - POST /api/custom/endpoint
```
