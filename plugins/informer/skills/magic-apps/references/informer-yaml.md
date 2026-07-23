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
    target: dataset                                          # one of: dataset, query, datasource, integration, app
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
| `target` | yes | `dataset`, `query`, `datasource`, `integration`, or `app` |
| `description` | no | Author-facing copy shown in the install/rebind UI |
| `runAs` | no | `user` (default) or `owner`. `owner` bypasses the viewing user's permissions — use sparingly |
| `options` | no | Per-target options (e.g. dataset filters), validated against the driver's schema |
| `defaultBinding` | no | A **UUID** the slot binds to automatically on first deploy. UUIDs (not configIds) so the binding survives a bundle export/import and isn't broken by users renaming the underlying resource. Look up the UUID from the resource's list endpoint (e.g. `GET /api/datasets-list`). **Never overwrites a binding the installer has already chosen** — re-deploys won't silently rewire a hand-bound slot. |

> **Legacy note:** You can also use a standalone `data-access.yaml` file (without the `access:` wrapper key). If both files exist, `informer.yaml` takes precedence. New apps should use `informer.yaml` with `dependencies:` since it supports typed slots, raw API allowlists, widgets, and roles in one file.

## `target: app` (app-to-app dependencies)

Bind another installed App to call its server routes. The slot exposes a single method:

- `request({ method, url, params, data })` — invoke one of the target App's `server/` routes (the same axios-shaped options as `integration`; returns the parsed body, a non-2xx upstream throws). Limited to one hop: an App reached through a dependency can't then chain into a third.

App slots bind like every other target — read access to the target App is the bar (same as datasets/queries/datasources/integrations), and a `defaultBinding: <app-uuid>` pre-binds on first deploy. An App can't bind to itself.

Before writing calls against the slot, fetch the target's contract (`GET /api/apps/{owner}:{name}/openapi.json`) and set up typed dev bindings — see `references/app-api.md`. A marketplace-destined consumer should declare `target: pack` (pin by marketplace slug + semver range) instead of `target: app`; the pack form is covered in the **marketplace-publishing** skill.

**To run SQL over another App's data, don't use `target: app`.** Bind that App's **workspace datasource** through a `target: datasource` slot instead: every App has a first-class workspace Datasource, and binding it gives you the standard `query(payload)` surface with the datasource's own ownership and access rules.

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

## `integrations:` (app-sourced integrations)

A `dependencies:` slot with `target: integration` **binds to** an Integration
that already exists in Informer (someone created it out of band; you supply its
UUID as `defaultBinding`). The `integrations:` block **declares one the app
owns**: deploy creates a real Informer Integration and, in the same pass, an
already-bound dependency slot of the same name. No admin has to pre-build a
connection, and no Integration UUID appears in the manifest.

```yaml
integrations:
  wake:
    name: Wake ABC
    apiBaseUri: https://wakeabc.com/
```

That one entry gives handler code `context.wake.request(...)` with nothing else
to wire up. Prefer `integrations:` over a `dependencies: { target: integration }`
slot whenever the app knows the service it needs (which is almost always) —
it's the difference between "the installer must go create a Salesforce
integration first" and "it just works on deploy."

**Rules that hold regardless of auth type:**

- The implicit slot is **deploy-managed**: it never shows as "needs binding" in
  the install panel and can't be rebound by hand. Change the manifest and
  redeploy to change it. (Converting an existing bound `dependencies:` slot to
  an owned `integrations:` entry of the same name re-points it automatically.)
- **Secrets are never literals.** The secret-bearing fields (`apiKey`,
  `clientSecret`) accept ONLY a `$env.KEY` reference, and every referenced key
  must be declared in [`env:`](#env-environment-variables) or the deploy fails.
  The value lives encrypted per-tenant; the installer fills it on the
  Admin → Environment tab.
- Removing an entry from the manifest **deletes** the owned Integration on the
  next deploy (its OAuth connections cascade away with it). Deploy owns the
  definition; every declared field is rewritten each deploy, so a field you
  stop declaring reverts to its default.
- Owned Integrations still go through the same secure proxy as bound ones (one
  auditable gate, host-locked base URL). They also appear in the tenant's
  Integrations admin list, badged with the owning app.

### Fields

| Field | Required | Description |
|-------|----------|-------------|
| `apiBaseUri` | yes | Base URL requests resolve against. `http`/`https` only — or, for `oauth2`, a `$connection.<field>` reference (see OAuth below). |
| `altBaseUris` | no | Extra base URLs absolute request URLs may target, for multi-host APIs (see [Multi-host APIs](#multi-host-apis-altbaseuris)). Server 2026.1.1+ honors values on the Integration record; manifest declaration and `*.` host wildcards require the I5-12803 build. |
| `name` | no | Display name (default: the entry key). Also drives the auto-matched service icon. |
| `description` | no | Author-facing copy for the install panel. |
| `authType` | no | `none` (default), `apiKey`, `basic`, `bearer`, or `oauth2`. |
| `apiKey` | `apiKey`/`bearer` | `$env.KEY` reference to the key. |
| `apiKeyName` / `apiKeyLocation` | no | Key header/param name; `header` (default) or `query`. |
| `clientId` | `basic`/`oauth2` | Client id. May itself be a `$env.KEY` reference. |
| `clientSecret` | `basic` (opt. `oauth2`) | `$env.KEY` reference to the secret. |
| `authUri` / `tokenUri` / `scope` / `revocationUri` / `basicTokenAuth` | `oauth2` | Provider endpoints and scopes. |
| `mode` | no | `per-user` (default) or `shared`. `oauth2` only. |
| `icon` | no | Absolute path/URL → used as-is; a library path (e.g. `icons/wake.svg`) → the file is copied onto the Integration; omitted → auto-matched to a well-known service by `name`. |
| `optional` | no | `true` if the app runs without it. Keeps the slot out of the install panel's "needs binding" count; runtime still throws the typed errors so you can feature-flag. |

### Auth types

```yaml
integrations:
  # Unauthed public host — still host-locked, still a single audited gate.
  wake:
    apiBaseUri: https://wakeabc.com/

  # API key from an $env secret (bearer/basic are the same shape).
  stripe:
    authType: apiKey
    apiBaseUri: https://api.stripe.com/v1
    apiKey: $env.STRIPE_KEY
    apiKeyName: Authorization        # optional; defaults to X-API-Key
    apiKeyLocation: header           # optional; header (default) | query

env:
  STRIPE_KEY:
    description: Stripe secret key
```

Per-authType requirements (deploy rejects violations with a slot-named 400):
`apiKey`/`bearer` need `apiKey`; `basic` needs `clientId` + `clientSecret`;
`none` must declare neither.

### OAuth 2.0

```yaml
integrations:
  sf:
    name: Salesforce
    authType: oauth2
    apiBaseUri: $connection.instance_url   # from the token response
    clientId: $env.SF_CONSUMER_KEY
    clientSecret: $env.SF_CONSUMER_SECRET
    authUri: https://login.salesforce.com/services/oauth2/authorize
    tokenUri: https://login.salesforce.com/services/oauth2/token
    scope: api refresh_token

env:
  SF_CONSUMER_KEY:
    description: Salesforce Connected App consumer key
  SF_CONSUMER_SECRET:
    description: Salesforce Connected App consumer secret
```

- **`$connection.<field>` base URLs.** Some providers return the account's own
  host in the token response (Salesforce returns `instance_url`). Setting
  `apiBaseUri: $connection.instance_url` makes each connection self-configure to
  whichever org its user authenticated against — installers never type an org
  URL. Valid only with `authType: oauth2`.
- **`mode`.** `per-user` (default): every viewer connects their own account and
  sees only what their provider permissions allow; the runtime slot dispatches
  as the viewer. `shared`: one connection, established once by the app owner,
  that every viewer rides; the slot dispatches as the owner.
- **Consent happens in-app.** Users connect from the app's Connections surface;
  you do not build the OAuth handshake. A handler that calls an unconnected
  oauth2 slot gets a typed `integration_not_connected` error to branch on.
- **Client-secret custody.** For a single institution, register your own
  provider app and hold its secret via `$env` (as above); the callback URL to
  register with the provider is your License Manager's `/integration/callback`.
  A `clientId` is required; `clientSecret` may be omitted when the id is an
  alias the License Manager holds the secret for (the marketplace path). Either
  way a plaintext secret can never sit in the manifest.

### Multi-host APIs (`altBaseUris`)

The request proxy pins every absolute URL to the integration's configured
bases — an SSRF guard that also stops a caller from steering the credential at
sibling paths. Some providers legitimately span hosts: Slack serves its API
from `slack.com/api` but file downloads from `files.slack.com`; Zoom serves
its API from `api.zoom.us` but cloud-recording/transcript downloads from
per-account hosts (`{account}.zoom.us`, `us0Xweb.zoom.us`). `altBaseUris`
declares those extra bases:

```yaml
integrations:
  zoom:
    authType: oauth2
    apiBaseUri: https://api.zoom.us/v2
    altBaseUris:
      - https://*.zoom.us        # `*.` host wildcard: apex + any subdomain
    clientId: $env.ZOOM_CLIENT_ID
    authUri: https://zoom.us/oauth/authorize
    tokenUri: https://zoom.us/oauth/token
```

Handler code then passes the provider's absolute download URL straight through
the same credentialed proxy:

```javascript
const rec = await context.zoom.request({
    method: 'GET',
    url: `/meetings/${zoomMeetingId}/recordings`,
    params: { include_fields: 'download_access_token' },
});
const vtt = (rec.recording_files || []).find(f => f.file_type === 'TRANSCRIPT');
const body = await context.zoom.request({
    method: 'GET',
    url: `${vtt.download_url}?access_token=${rec.download_access_token}`,  // absolute, alt host
});
```

Matching rules (each entry is a full base, not just a host):

- An **exact** entry admits only that origin (scheme + host + port), confined
  to the entry's path at a segment boundary — same semantics as `apiBaseUri`.
- A **leading `*.`** makes the host a wildcard: the apex and any subdomain
  match, at a dot boundary only (`evilzoom.us` and `zoom.us.evil.com` do not).
  Scheme and port still pin exactly; path confinement still applies. Only a
  leading `*.` is wildcard syntax — a mid-host asterisk is a literal that
  matches nothing.
- The list is owner-controlled config; a caller can never widen it.

**Version notes:**

- Server **2026.1.1+** honors exact-host `altBaseUris` set on the Integration
  record, but the deploy manifest doesn't accept the key yet. Interim: set it
  directly — `PUT /api/integrations/{id}` with
  `{ "altBaseUris": ["https://myaccount.zoom.us"] }`. Deploys don't manage the
  field on those builds, so the value survives redeploys; it is not one of the
  connection-invalidating columns, so existing OAuth connections survive too.
- Builds with **I5-12803** accept `altBaseUris` in the manifest (deploy-owned:
  dropping it revokes the extra hosts) and add the `*.` wildcard matching.
  Declaring it in the manifest on an older server fails deploy with an
  unknown-key error — comment it out until the server is upgraded.

### When to use which

- **`integrations:`** — the app owns the connection. Default for anything the
  app itself needs to reach.
- **`dependencies: { target: integration }`** — bind to a specific existing
  Integration the installer picks (or you pre-bind by UUID). Use when the app
  should reuse a connection the tenant already manages centrally.

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

The five typed-slot targets and what API surface each one's bound resource exposes:

| `target` | API surface | Slot methods |
|----------|-------------|--------------|
| `dataset` | `_search`, `fields` | `context.<slot>.search(esQuery)` / `.fields()` |
| `query` | `_execute` | `context.<slot>.execute(params)` |
| `datasource` | `_query` | `context.<slot>.query(payload)` |
| `integration` | `request` | `context.<slot>.request({ method, url, params, data })` (axios-shaped: `url` not `path`, `data` is the body) |
| `app` | another App's workspace + `server/` routes | `context.<slot>.query(sql, params)` (read-only SQL) / `.request({ method, url, params, data })` |

### `target: app` (cross-app dependencies)

Binds another installed App, granting two surfaces on it:

```yaml
dependencies:
  kanban:
    target: app
    description: The board whose data this dashboard analyzes
```

- **Binding requires owner/admin of the target — and there is no `defaultBinding`.** A bound App exposes its *entire* workspace through `query()`, so the person binding must be the target App's owner or an admin of the team that owns it; read access alone is rejected with a 403. App slots are bound by the installer through the app's dependency setup (`GET /api/apps-list` finds the App to bind), NOT via a manifest `defaultBinding` — declaring one fails the deploy with "does not support defaultBinding". Leave the slot bare, as above.
- **`query(sql, params)` is read-only and not viewer-scoped.** Cross-app SQL authenticates as a dedicated SELECT-only Postgres role on the target's workspace schema, so writes fail regardless of SQL shape (INSERT, data-modifying CTEs, and multi-statement transaction tricks all fail; a write surfaces as a 400 with `errorCode: 'app_dependency_query_failed'`). It reads the whole workspace and runs identically for every viewer of the consuming App — it does NOT inherit the calling user's permissions, which is why binding is gated to the target's owner/admin.
- **`request()` is limited to one hop.** App A may call App B, but the handler B runs on A's behalf cannot then call App C (or back into A) — a second hop throws 508 with `errorCode: 'app_dependency_depth_exceeded'`.
- **`request()` goes through the target App's own gate.** Dispatch is identical to a direct call: the `runAs` identity must have read access to the target App, the target route's `config.roles` apply, and compute is metered against the target.
- **Self-binding is rejected** at bind time with a 400.
- Unbound/broken slots throw the standard 422 `dependency_unbound` / `dependency_broken` contract.

> **`libraries` is not a typed slot.** Library access lives only in the legacy `access.libraries:` whitelist block (`contents/*`) — there is no `target: library` slot model. Use `access.libraries:` if your app needs to read files from another library; everything else goes under `dependencies:`.

For raw API paths that don't fit the slot model (custom endpoints, AI model routes), use `access.apis:`:

```yaml
# informer.yaml
access:
  apis:
    - POST /api/custom/endpoint
```
