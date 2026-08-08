---
name: magic-apps
description: Building Informer Apps with local Vite development. Covers the dev/publish workflow, the centerpiece "Accessing Your Dependencies" model (typed slots + three patterns), and the orientation map for deeper topics (server routes, webhooks, persistence, widgets, copilot sidebar, event-driven AI agents, live broadcast channels over WebSockets, PDF export, informer.yaml schema, app-to-app/pack API integration and openapi.json contracts) — each routes to a reference file under `references/` so the front door stays loadable on every trigger.
---

# Informer App Development

## What is an Informer App?

An Informer App is a custom HTML/JS/CSS application that runs inside Informer. It can:
- Query Informer datasets (Elasticsearch-indexed data)
- Execute saved queries
- Make authenticated requests to external APIs via integrations (Salesforce, etc.)
- **Store and query its own data** in a dedicated Postgres workspace (with SQL migrations)
- **Run server-side JavaScript handlers** in sandboxed V8 isolates (with direct DB access)
- Render charts, tables, and interactive visualizations
- Include a **built-in AI copilot** sidebar that can query your data and answer questions in context
- Define **AI agents** that react to events, execute tools, and chain together for automated workflows
- Push **live updates** to every open page over a WebSocket Informer owns for it (channels — origin-mode servers)

Apps are stored in Informer libraries and served through the Informer UI. (You may see the term "Magic Report" in older documentation — Apps are the current name for the same concept.)

## Reference Index — when to load which file

This file is the orientation layer. Most topics have a dedicated reference under `references/` — load the reference into context the moment the user's request lands in that topic.

| User intent / signal | Load this file |
|---|---|
| Writing handlers under `server/`, working with `query` / `transaction` / `fetch` / `respond` / `notify` / `email` / `log` / `crypto` / base64 / markdown / `env` / `request` / sandbox constraints | `references/server-routes.md` |
| Receiving external callbacks (Stripe, GitHub, Slack, Gmail push) under `webhooks/`, HMAC verification, signed `?token=` URLs | `references/webhooks.md` |
| Storing app data — `migrations/`, dev-workspace lifecycle, `workspace:init` / `:migrate` / `:reset`, CRUD example | `references/persistence.md` |
| Building a WAREHOUSE / ETL app — the sync-route pattern (one atomic entry point; per-table only when safe), the `load()` spec (replace/append/**upsert** with key + prune, multi-table `into` maps for atomic header/line publishes, scoped prune, `dryRun` validation, batch hooks, page walkers, `onComplete`/`onLoaded`/`emit`), run receipts, `automations:` schedules, the run-ledger/SSE surface, what the warehouse's own UI must cover | `references/warehouse-etl.md` |
| Declaring SEMANTICS for a workspace database — `semantics.yaml` (structure: types/units/enum values + quick-dev inline labels), `semantics.<locale>.yaml` strings-only overlays, description-vs-COMMENT channels, FK-as-links, how customer overlays and shadow views layer on top after install | `references/semantics.md` |
| Writing a walker against a SPECIFIC integration (QuickBooks, Salesforce, …) — per-connector traps: hidden inactive rows, pagination quirks, incremental watermark fields, deletion detection | `references/connector-gotchas.md` |
| Declaring `widgets:` in `informer.yaml`, building self-contained HTML cards under `public/widgets/`, iframe quirks | `references/widgets.md` |
| Activating the in-app copilot, `openChat()` / `registerTool()`, AI completion endpoints (`_chat` / `_completion` / `_object`), `useChat` hook patterns | `references/copilot.md` |
| Declaring `agents:` in `informer.yaml`, writing `tools/*.js`, `emit()` chaining, cron, toolkits/assistants integration, agent REST API | `references/agents.md` |
| Live updates to open pages — "real-time" / "push" / "stop polling" / presence / typing; `broadcast(channel, event, payload)` from a handler, the `channels:` relay block, gated channels under `channels/` (`join` / `leave` / `config.roles`), `@user/<username>`, `__INFORMER__.channel(name).on(event, fn)`, `origin_mode_required` | `references/channels.md` |
| Exposing tools to outside AI clients (Claude Code/Desktop, Cursor) — the `mcp/` folder, why the folder is the decision, writing for a caller with no context, the per-app endpoint, the OAuth connect flow, who a tool runs as | `references/mcp.md` |
| Deep `informer.yaml` work — `dependencies:` slot field reference, app-sourced `integrations:` (an app declares and owns an Integration — OAuth, `$env` secrets, icons), RLS via `$user.*`, modernizing a legacy `access:` block, `defaultBinding` lookup, declaring env-var keys with `env:` | `references/informer-yaml.md` |
| App-to-app/pack APIs — fetching a target's contract (`openapi.json`), typed dev bindings (`.informer/app-deps.d.ts`), public-vs-internal routes, and making your own App integratable (`description`/`schema` exports, `config.api = 'public'`, root `API.md`) | `references/app-api.md` |
| In-gallery app docs (`docs.html`), in-app `?` help button, `README.md` fallback | `references/docs-html.md` |
| Looking up the raw API surface behind the typed-slot proxy (still useful when something fails) | `references/api-reference.md` |
| HTML/CSS/JS starter snippets, theme-variable patterns, CSS Modules for React | `references/app-templates.md` |
| Public pages & anonymous API routes (`public: true`, `server/public/**`), the app's OWN sign-up/login (`accounts.issuers.local`, `/_auth/*`), password reset, OIDC/SSO (`/_auth/oidc/{name}`), "Sign in with Informer" (`/_auth/informer`), accepting other apps' users (`accounts.accept`), the unified `request.user` | `references/accounts-and-login.md` |
| Running a WASM library or Web Worker in the sandbox (DuckDB-WASM, sql.js, ffmpeg.wasm, pdf.js, ONNX) — the blob-worker pattern, bundling wasm locally, `new Worker` failing with origin `'null'`, external extension fetches | `references/wasm-workers.md` |

The sections that **stay in this file** are the ones nearly every project touches: bootstrapping, local-dev essentials, the dep-access centerpiece, the small surfaces (App Context, HTML5 routing, App Roles, PDF Export). Everything else is one click away in `references/`.

## Bootstrapping a New Project

When this skill is invoked in a directory that isn't already a Magic App project, drive the setup for the user — they shouldn't have to remember the command sequence. Detect the current state and run only the steps that are missing.

### Detection

Before running anything, inspect the working directory:

| State | Signal |
|---|---|
| **Empty** | No `package.json`, no `vite.config.{js,ts}`, no `informer.yaml` |
| **Vite project, no Informer** | `package.json` exists with `vite` in deps, no `informer.yaml` |
| **Already a Magic App** | `informer.yaml` exists and `@entrinsik/vite-plugin-informer` is in devDependencies |
| **Vite project, partial Informer** | `informer.yaml` missing but plugin is installed, OR vice versa |

### Recipe

For an **empty** directory, ask the user one question and then run the sequence:

> "What should we call this app? (e.g. 'Sales Dashboard'). I'll set up Vite + the Informer plugin + scaffold informer.yaml — should take ~30 seconds."

Then execute, in order (don't ask permission for each — run them all):

```bash
# 1. Scaffold a React Vite project into the current directory.
# --template react skips Vite's interactive framework prompt.
# Use --template react-ts if the user asked for TypeScript, or
# --template vanilla / vue / svelte / etc. if they named a different
# framework. Default to react when the user has no preference.
npm create vite@latest . -- --template react

# 2. Install dependencies including the Informer plugin.
npm install
npm install -D @entrinsik/vite-plugin-informer@2.4.0

# 3. Run the Informer init — creates informer.yaml, .env, .env.example,
#    updates vite.config.js to include informer(), updates .gitignore,
#    adds deploy + workspace:* scripts to package.json.
npx informer-init
```

If `npm create vite@latest .` refuses because the directory has stray files (a README from `git init`, a `.gitignore`, etc.), tell the user which files are in the way and either:
- Move them aside, run vite create, then move them back; or
- Scaffold to a subdirectory and `mv` files up.

For a **Vite project without Informer**, skip step 1 — start from step 2.

For an **already a Magic App** directory, skip the bootstrap entirely and go straight to whatever the user actually asked for (building a widget, adding a route handler, declaring a dependency slot, etc.).

### What `informer-init` produces

After `npx informer-init` you have:

```
my-app/
├── .env                    # Connection settings (gitignored)
├── .env.example            # Template for connection settings
├── informer.yaml           # App configuration — dependencies, roles, agents, events, widgets
├── package.json            # informer section (name, description, id UUID) + deploy/workspace:* scripts
├── vite.config.js          # Includes informer() plugin
├── index.html              # Vite default — replace with your app shell
└── main.js                 # Vite default — replace with your entry
```

Init also:
- Prompts for an app name (used as the `informer.name` display name)
- **Generates a UUID for `informer.id`** and writes it to `package.json` immediately — used by `npm run deploy` to create or address the app on the server. Don't set it manually.
- Updates `.gitignore` to exclude `.env`

The `.env` template includes both API key and basic auth blocks — uncomment the one you want. If the user mentions a specific server, fill it in directly; otherwise leave the placeholder `http://localhost:3000` and tell them to update before running `npm run dev`.

> **`public/favicon.svg` is not created by init.** It's a recommended addition — 512×512, duotone — and gets deployed to the app's library root as the gallery/tab icon. Add it yourself or ask Claude to generate one.

### After bootstrap

Once the project is set up, the typical next moves are:

1. Ask the user what data the app needs (datasets/queries/datasources/integrations) and add `dependencies:` slots to `informer.yaml` — look up `defaultBinding` UUIDs via `GET /api/datasets-list` etc. against the configured `INFORMER_URL`. For an external service the app itself needs (a REST API, Salesforce, and so on), prefer declaring it in the `integrations:` block instead of binding to a pre-existing one — deploy creates the Integration and the slot for you, no UUID and no out-of-band setup. See `references/informer-yaml.md`.
2. Replace Vite's default `index.html` + `main.js` with the app shell.
3. If the app stores its own data, scaffold `migrations/` and add a first migration — load `references/persistence.md`.
   If the data is LOADED from sources on a cadence (a warehouse), load `references/warehouse-etl.md` instead — it layers sync routes, `load()`, and `automations:` schedules on top of plain persistence.
   A warehouse meant for BI consumption should also ship semantics — load `references/semantics.md` when writing informer.yaml's siblings or authoring migrations that add tables/columns.
4. If the app exposes server-side routes, scaffold `server/` — load `references/server-routes.md`.
5. If the app should be usable from an outside AI client (Claude Code/Desktop, Cursor), scaffold `mcp/` with tools written for a context-free caller — load `references/mcp.md`.
6. If open pages should update live when server code changes something (no polling), add a `channels:` relay block and/or `channels/` handlers — load `references/channels.md` (needs an origin-mode server; confirm before building on it).

## Local Development Workflow

### Vite Plugin

Install the Informer Vite plugin as a dev dependency (skip if `npx informer-init` was used — it's already there):

```bash
npm install -D @entrinsik/vite-plugin-informer@2.4.0
```

### Code Splitting

Code splitting is supported. Use Vite's defaults — dynamic `import()` and route-level lazy loading work in published apps with no extra config. Don't override `build.rollupOptions.output`; the server injects an import map at serve time so chunk URLs carry the auth token, and custom chunk paths outside `dist/` will not be served.

### External Scripts & Resources (Approved Resources)

Informer blocks outside hosts by default via CSP. A tenant admin approves external origins under **Informer Admin → Approved Resources**, and the resource *type* decides which CSP directive opens — so match the type to **how the browser loads the thing**:

| You're loading… | how it loads | Approved Resource type | CSP directive |
|---|---|---|---|
| A JS library via `<script src>` | script tag | **Script** (check **ESM** for `.mjs`) | `script-src` |
| A stylesheet | link tag | **Style** | `style-src` |
| An image / font | `<img>` / `@font-face` | **Asset** (image / font) | `img-src` / `font-src` |
| **A `fetch()`/XHR target** (remote data, WASM extension packs, …) | `fetch`/XHR | **Asset, type `data`** | `connect-src` |

The last row is the common gotcha: anything an app *fetches* (not script-tag-loads) — e.g. a DuckDB extension pack pulled from `extensions.duckdb.org` — needs a **`data` asset**, not a Script. A Script entry only opens `script-src` and will **not** authorize the `fetch`. Use the `https://cdn.jsdelivr.net/npm/...` format for the standard CDN.

**Web Workers & WASM — bundle locally, do not point at a CDN.** CDN fetches are blocked by `connect-src` in every serving mode, so bundle the worker/wasm *with your app* (Vite `?url`). On deployments with **per-app origins** (App API v2, Informer 2026.1.2+) the app has a real origin and plain `new Worker(bundledUrl)` works — as do `localStorage`, IndexedDB, and service workers. On path-mode deployments the iframe's origin is opaque and the worker must be constructed from a **blob URL**; that blob recipe works in BOTH modes, making it the portable choice for marketplace apps. (Earlier guidance to point `workerSrc` at a CDN copy is superseded.) See **`references/wasm-workers.md`** for the full recipe (DuckDB-WASM, sql.js, ffmpeg.wasm, pdf.js, ONNX).

### Development Mode (`npm run dev`)

The Vite plugin proxies `/api/*` requests to your Informer server with Basic auth. This means:
- Your code makes fetch calls to `/api/...` (no host needed)
- The plugin adds authentication headers automatically
- You get hot reload while working against real Informer data

Configuration is in `.env`:
```
INFORMER_URL=http://localhost:3000
INFORMER_API_KEY=your-api-key
```

Or use basic auth:
```
INFORMER_URL=http://localhost:3000
INFORMER_USER=admin
INFORMER_PASS=yourpassword
```

If your app uses persistence (see `references/persistence.md`), you'll also have:
```
INFORMER_DEV_WORKSPACE=<workspace-naturalId>     # e.g. admin:my-app-dev
```
This is set automatically by `npm run workspace:init`. When `--mode` is active, it lands in `.env.<mode>` instead of `.env`.

**Multi-environment support:** Use `--mode` to target different servers:
```bash
npm run dev -- --mode test        # loads .env.test
npm run deploy -- --mode production  # loads .env.production
```

Create mode-specific env files (e.g., `.env.test`, `.env.production`) with server-specific credentials. When a mode is active, workspace IDs are saved to the mode-specific file.

**Monorepo support:** The plugin walks up the directory tree to find parent `.env` files as fallback defaults. Place shared credentials in a parent `.env` and app-specific overrides (like `INFORMER_DEV_WORKSPACE`) in each app's local `.env`.

**Proxy options:** Pass `proxy` options to the plugin for SSL/cert issues:
```javascript
informer({ proxy: { secure: false } })
```

**Blank white page after concurrent edits?** Vite's HMR cache can wedge when two editors (or an editor and an AI agent) modify the same module graph at the same time. Symptoms: blank page, console errors about stale modules or `TypeError`s on previously-working imports. Fix: kill the dev server, `rm -rf node_modules/.vite`, restart. Not Informer-specific — it's a Vite quirk — but worth knowing because the symptom is silent.

### Deploying (`npm run deploy`)

Builds your project and uploads to Informer:
1. Creates/finds an App via the `/api/apps` endpoint (falls back to legacy `/api/reports` on older servers)
2. Snapshots the library for rollback
3. Clears existing files
4. Uploads all built assets from `dist/`
5. Uploads `informer.yaml` and `data-access.yaml` from project root (if they exist)
6. Uploads `migrations/` directory (if it exists)
7. Uploads `tools/` and `mcp/` directories (if they exist)
8. Uploads `server/` directory (if it exists)
9. Uploads `webhooks/` directory (if it exists)
10. Uploads `channels/` directory (if it exists)
11. Runs deploy: pending SQL migrations + server-route scanning + webhook scanning + channel scanning (`channels/` handlers + the `channels:` relay block) + handler bundling + tool bundling (`tools/` + `mcp/`) + resource reference validation + agent upsert from `informer.yaml`
    - **Resource refs are validated**: all datasets, queries, datasources, integrations, and toolkits declared in `informer.yaml` must exist — deploy fails with a clear error if any are missing
    - **Channels need origin mode**: a `channels:` block or `channels/` directory on a path-mode server still deploys, with a non-fatal `channels_require_origin_mode` warning — see `references/channels.md`
12. App is viewable at `/api/apps/{owner}:{slug}/view`

### Package.json Configuration

The `informer` section in `package.json` controls deploy metadata:

```json
{
  "informer": {
    "name": "Sales Dashboard",
    "description": "Regional sales performance overview"
  }
}
```

| Field | Description |
|-------|-------------|
| `name` | Display name in Informer (falls back to package `name`) |
| `description` | App description |
| `id` | App UUID — **do not set manually**. `npx informer-init` generates the UUID and writes it to `package.json` at scaffold time. `npm run deploy` then uses that UUID to create the app on the server on first run. |

### App Icon (favicon.svg)

Place a `favicon.svg` in your `public/` directory. It will be deployed to the app's library root and used as:
- **App gallery icon** — shown as the app's tile in the desktop and mobile app galleries
- **Browser tab favicon** — shown when the app is viewed in a browser tab

**Recommended style: duotone** — one hue, two opacity levels.

```svg
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512">
  <!-- Background with rounded corners -->
  <rect width="512" height="512" rx="96" fill="#064e3b"/>
  <!-- Secondary elements at 35% opacity -->
  <rect x="96" y="240" width="64" height="152" rx="10" fill="#6ee7b7" opacity="0.35"/>
  <!-- Primary elements at full opacity -->
  <rect x="176" y="160" width="64" height="232" rx="10" fill="#6ee7b7"/>
</svg>
```

Guidelines:
- **512x512 viewBox**, square (1:1 aspect ratio)
- **Self-contained background** — bake the background color into the SVG with rounded corners (`rx="96"`)
- **Single hue** with full opacity for primary shapes, ~35% for secondary
- **Bold, simple shapes** that are recognizable at 70px (mobile icon size)
- Design should visually represent the app's content (bars for dashboards, document for invoices, etc.)

## App Documentation (`docs.html`)

Apps can include a `docs.html` page in `public/` that opens from the app gallery's book-icon badge — and a `?` help button inside the app can iframe-open the same file. Full guidance — gallery integration, structure template, in-app help button code, the `README.md` fallback — lives in `references/docs-html.md`. Load that reference when adding or restyling docs.

## Accessing Your Dependencies

This is the most important section of this skill. Read it before writing any code that touches a dataset, query, datasource, integration, or another App's data. The single biggest source of broken Magic Apps is code that hardcodes resource IDs in the frontend.

### The runtime model

An Informer App has **two** JavaScript runtimes, and they access dependencies differently:

| Runtime | Where it runs | How it talks to deps |
|---|---|---|
| **Server handler** | V8 isolate inside the Informer server (files in `server/`, `tools/`, `webhooks/`, `channels/`, or `agents:`) | `context.<slot>.<method>(args)` — typed proxy, no UUIDs in code |
| **Frontend** | Browser (your `main.js` / React components / etc.) | Has to make HTTP calls. **Does NOT have `context`.** |

`context` is a property the V8 isolate runtime injects into the handler argument. It does not exist in the browser. Trying to use `context.<slot>` in a React component will throw `ReferenceError: context is not defined`.

### The three patterns, ranked

Every dep access uses one of three patterns. Pick the highest-numbered one you can:

1. **Pattern A — Frontend → your server handler → `context.<slot>`** (preferred for any app touching deps)
2. **Pattern B — Frontend with runtime binding discovery** (acceptable for SPAs without server handlers)
3. **Pattern C — Hardcoded UUIDs in frontend code** (forbidden — breaks the slot's value)

The ranking matters: **default to Pattern A.** Pattern B is acceptable when the app has no server-side surface at all. Pattern C looks like it works during dev and silently breaks when the installer rebinds a slot, the underlying resource is renamed, or the bundle is imported into another tenant.

### Pattern A — Server handler with `context.<slot>`

The handler receives a `context` object where each `dependencies:` slot is a property named after the slot. Methods depend on the slot's `target`:

| target | Methods | What they hit |
|---|---|---|
| `dataset` | `search(esQuery)` / `fields()` | `POST /api/datasets/<uuid>/_search` / `GET /api/datasets/<uuid>/fields` |
| `query` | `execute(params)` | `POST /api/queries/<uuid>/_execute` |
| `datasource` | `query(payload)` | `POST /api/datasources/<uuid>/_query` |
| `integration` | `request({ method, url, params, data })` | `POST /api/integrations/<uuid>/request` |
| `app` | `request({ method, url, params, data })` | `<method> /api/apps/<uuid>/view/_/<url>` |

`target: app` binds another installed App and exposes only `request()` — it invokes one of the target App's `server/` routes (one hop, no chaining), with the same axios-shaped options as `integration`. It binds like every other target (read access to the target App, optional `defaultBinding: <app-uuid>`). **Before writing `request()` calls, fetch the target's contract** — `GET /api/apps/{owner}:{name}/openapi.json` documents its routes, params, roles, and public surface, and `devBindings` turns it into typed calls in dev (see `references/app-api.md`; a marketplace-destined consumer declares `target: pack` instead — same file). **To run SQL over another App's data, don't use `target: app` — bind that App's workspace datasource via a `target: datasource` slot** (see `references/informer-yaml.md`).

A worked example covering the four data target types:

```yaml
# informer.yaml
dependencies:
  orders:
    target: dataset
    defaultBinding: 7d5a9b1e-0c83-4bde-9e2a-3a4b5c6d7e8f
  monthly_summary:
    target: query
    defaultBinding: 9a8b7c6d-5e4f-3a2b-1c0d-fedcba987654
  analytics:
    target: datasource
    defaultBinding: 3e4f5a6b-7c8d-9e0f-1234-567890abcdef
  salesforce:
    target: integration
    defaultBinding: 5a6b7c8d-9e0f-1234-5678-9abcdef01234
  kanban:
    target: app                          # another installed App; defaultBinding optional
```

```javascript
// server/dashboard.js
export async function GET({ context, request }) {
    // dataset → search returns Elasticsearch hits envelope
    const hits = await context.orders.search({
        query: { range: { total: { gte: 100 } } },
        size: 50,
        aggs: { revenue: { sum: { field: 'total' } } }
    });

    // dataset → fields returns the index field metadata
    const fields = await context.orders.fields();

    // query → execute runs the saved query with optional parameters
    const summary = await context.monthly_summary.execute({ month: '2026-05' });

    // datasource → query runs SQL against the underlying connection
    const events = await context.analytics.query({
        sql: 'SELECT type, COUNT(*) AS n FROM events WHERE day = $1 GROUP BY type',
        params: ['2026-05-12']
    });

    // integration → request proxies to the external service. The options are
    // axios-shaped: `url` (the path — NOT `path`), `method`, `params` for the
    // query string, `data` for the request body (POST/PUT/PATCH), `headers`.
    // It returns the parsed upstream body DIRECTLY (not a { status, body }
    // wrapper); a non-2xx upstream throws (see Error handling below).
    // `url` may also be ABSOLUTE, but only to the integration's configured
    // bases (apiBaseUri + altBaseUris) — anything else is rejected as SSRF.
    // Multi-host providers (Zoom download hosts, files.slack.com) need
    // altBaseUris: see references/informer-yaml.md → "Multi-host APIs".
    const accounts = await context.salesforce.request({
        method: 'GET',
        url: '/services/data/v59.0/query',
        params: { q: "SELECT Id, Name FROM Account WHERE Industry = 'Banking'" }
    });

    // app → request invokes the target App's own server/ routes.
    // request() is the ONLY surface — there is no cross-app SQL.
    const stats = await context.kanban.request({ method: 'GET', url: '/stats/summary' });

    return { hits, fields, summary, events, accounts, stats };
}
```

**`target: app` rules.**
- **Binds like every other target — read access, `defaultBinding` supported.** Whoever binds the slot needs read access to the target App (the same bar as datasets/queries/datasources/integrations), and the manifest may pre-bind with `defaultBinding: <app-uuid>` (look it up via `GET /api/apps-list`). An unresolvable `defaultBinding` doesn't fail the deploy — it logs a warning, and a required slot surfaces a `default_binding_unresolved` warning telling the admin the app won't run until it's bound in Settings. Author errors (a non-UUID value, a target type that doesn't support `defaultBinding`) are still fatal.
- **`request()` is the only surface — there is no cross-app SQL.** To run SQL over another App's data, bind that App's workspace datasource through a `target: datasource` slot.
- **`request()` is limited to ONE hop** (A→B ok; B cannot then call C or back into A — a second hop throws 508 `app_dependency_depth_exceeded`), and it runs through the target App's own read access, `config.roles`, and compute budget under the slot's `runAs` identity.
- **An App can never bind to itself** (rejected with a 400 — including a self-referencing `defaultBinding` at deploy).

**Error handling.** If the installer hasn't bound a slot yet, or the bound target was deleted, the proxy throws a structured boom 422:

```javascript
export async function GET({ context }) {
    try {
        return await context.orders.search({ query: { match_all: {} } });
    } catch (err) {
        // err.output.statusCode === 422
        // err.output.payload.data carries:
        //   { errorCode, dependencyName, resourceType }
        // errorCode is one of:
        //   'dependency_unbound' — installer hasn't picked a target
        //   'dependency_broken'  — bound target was deleted
        const code = err.output?.payload?.data?.errorCode;
        if (code === 'dependency_unbound') {
            return { status: 503, body: { error: 'This app needs setup — open the install panel and bind the orders dataset.' } };
        }
        if (code === 'dependency_broken') {
            return { status: 503, body: { error: 'The orders dataset was deleted. Rebind via the install panel.' } };
        }
        throw err;
    }
}
```

**Frontend calls the handler:**

```jsx
// src/App.jsx
function Dashboard() {
    const [data, setData] = useState(null);
    useEffect(() => {
        fetch('/api/dashboard')
            .then(r => r.json())
            .then(setData);
    }, []);
    return data ? <Charts {...data} /> : <Spinner />;
}
```

The frontend never sees a single UUID. Installer rebinds, resource renames, bundle export/import — none of it touches your frontend code. The slot does its job.

See `references/server-routes.md` for the full file-convention and handler shape.

### Pattern B — Frontend with runtime binding discovery

If you really want a pure SPA (no `server/` directory), the frontend can discover bindings at runtime by hitting the app's own `/dependencies` endpoint, then use the resolved UUIDs for subsequent calls.

**This requires whitelisting the discovery endpoint** in `informer.yaml`:

```yaml
# informer.yaml
dependencies:
  orders:
    target: dataset
    defaultBinding: 7d5a9b1e-0c83-4bde-9e2a-3a4b5c6d7e8f

access:
  apis:
    # Required for Pattern B — frontend reads bindings at startup
    - GET /api/apps/*/dependencies
```

Frontend code:

```jsx
// src/App.jsx — pure SPA, no server handlers
import { useEffect, useState } from 'react';

function useDependencyBindings() {
    const [bindings, setBindings] = useState(null);
    const [error, setError] = useState(null);

    useEffect(() => {
        const appId = window.__INFORMER__?.report?.id;
        if (!appId) return;
        fetch(`/api/apps/${appId}/dependencies`)
            .then(r => r.json())
            .then(({ items }) => {
                // items: [{ name, target, targetId, targetName, bound, ... }]
                // Reshape to { slotName: targetUuid } for easy lookup.
                const map = Object.fromEntries(items.map(i => [i.name, i.targetId]));
                setBindings(map);
            })
            .catch(setError);
    }, []);

    return { bindings, error };
}

function Dashboard() {
    const { bindings } = useDependencyBindings();
    const [hits, setHits] = useState(null);

    useEffect(() => {
        if (!bindings?.orders) return;
        fetch(`/api/datasets/${bindings.orders}/_search`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ query: { match_all: {} }, size: 50 })
        })
            .then(r => r.json())
            .then(setHits);
    }, [bindings?.orders]);

    if (bindings && !bindings.orders) {
        return <p>This app needs setup — bind the orders dataset.</p>;
    }
    return hits ? <Table hits={hits} /> : <Spinner />;
}
```

The whitelist check passes because the slot's bound UUID was materialized into the app's allowed paths at deploy time.

**Trade-offs vs Pattern A:**

- ✓ No server-side directory needed
- ✗ Extra round trip on every cold load
- ✗ Frontend must handle the "binding not yet loaded" state in every dep-using component
- ✗ Local-dev mocks are harder — the dev plugin doesn't have real bindings to return
- ✗ The discovery endpoint has to be in `access.apis` — one more thing to remember

If you're at this point, consider whether adding a single `server/<route>.js` handler that wraps the dep call wouldn't be cleaner. Usually it is.

### Pattern C (forbidden) — Hardcoded UUIDs in frontend code

```jsx
// DON'T do this — even if the UUID matches the manifest's defaultBinding
const hits = await fetch('/api/datasets/7d5a9b1e-0c83-4bde-9e2a-3a4b5c6d7e8f/_search', {...});

// And don't do this — configIds in URL paths get rejected once the
// installer rebinds, and even before that the configId can be renamed.
const hits = await fetch('/api/datasets/admin:northwind-orders/_search', {...});
```

The whole point of declaring a slot was to make the binding an **installation choice**, not a hardcoded value. Hardcoded UUIDs/configIds:

- Break silently when the installer rebinds the slot to a different resource — new UUID is in the whitelist, your hardcoded one isn't, request gets 403'd
- Break on bundle export/import to a different tenant — UUIDs survive, but if the manifest is re-deployed against a different resource (likely if the publisher updates the app) you're still pointing at the old one
- Break when the underlying resource is renamed (configIds) or deleted

**If Claude finds itself writing `/api/datasets/<some-id>/_search` in frontend code, stop and pick Pattern A or B.**

### Decision tree

```
Does the app have (or could it have) a server/ directory?
├── Yes  → Pattern A (server handler with context.<slot>)
└── No
    └── Is the dep access happening from a widget HTML file,
        or a frontend component, or both?
        ├── Either   → Pattern B (runtime binding discovery)
        │             Add the dependencies endpoint to access.apis.
        └── Neither  → You don't have a dep access; this section
                       doesn't apply.
```

For most apps, Pattern A is the right answer. If the user asks for "a quick SPA dashboard" with no server-side code, gently push toward adding a single server route — the future-you who has to debug a 403 after an installer rebind will thank present-you.

### Author lookup endpoints (for filling in `defaultBinding`)

These are the endpoints **app authors** hit (via curl or Claude with `.env` configured) to find UUIDs to drop into `defaultBinding`. They are NOT the right way to access deps at runtime — that's what the patterns above are for.

| Endpoint | Returns | Use when filling in |
|---|---|---|
| `GET /api/datasets-list` | `[{ id (UUID), name, configId, ... }]` | `target: dataset` slots |
| `GET /api/queries-list` | `[{ id (UUID), name, configId, ... }]` | `target: query` slots |
| `GET /api/datasources-list` | `[{ id (UUID), name, configId, ... }]` | `target: datasource` slots |
| `GET /api/integrations-list` | `[{ id (UUID), name, slug, ... }]` | `target: integration` slots |
| `GET /api/apps-list` | `[{ id (UUID), name, naturalId, ... }]` | `target: app` slots |
| `GET /api/apps/{owner}:{name}/openapi.json` | The App's API contract (routes, params, roles, public surface) | Writing `context.<slot>.request()` calls against an `app`/`pack` slot (see `references/app-api.md`) |

(`GET /api/apps-list` is how you find the target App's UUID for a `target: app` slot's `defaultBinding`, and how the installer finds the App when binding through the app's dependency setup.)

Example: ask Claude to "find the UUID for the northwind-orders dataset" — Claude curls `$INFORMER_URL/api/datasets-list` against the configured `.env` credentials, finds the matching `configId`, and copies the `id` into `defaultBinding`.

### Common ES query patterns (for `context.<dataset>.search()`)

These shapes go into the `esQuery` argument of `context.<slot>.search()`:

```javascript
// Filter by exact value
{ query: { bool: { filter: [{ term: { status: 'active' } }] } } }

// Filter by range
{ query: { bool: { filter: [{ range: { amount: { gte: 1000 } } }] } } }

// Date range
{ query: { bool: { filter: [{ range: { date: { gte: '2026-01-01', lte: '2026-12-31' } } }] } } }

// Multiple filters (AND)
{ query: { bool: { filter: [
    { term: { region: 'North' } },
    { range: { amount: { gte: 1000 } } }
] } } }

// Sum / avg / min / max
{ aggs: { total: { sum: { field: 'amount' } } } }

// Group by field
{ aggs: { by_region: { terms: { field: 'region', size: 50 } } } }

// Group with nested metric
{ aggs: {
    by_region: {
        terms: { field: 'region', size: 50 },
        aggs: { total: { sum: { field: 'amount' } } }
    }
} }

// Date histogram
{ aggs: {
    by_month: {
        date_histogram: { field: 'date', calendar_interval: 'month' },
        aggs: { total: { sum: { field: 'amount' } } }
    }
} }
```

Returned shape:
- `result.hits.total` — total matching records
- `result.hits.hits` — array of `{ _source: { field1, field2, ... } }`
- `result.aggregations` — aggregation results (if requested)

## App Configuration (`informer.yaml`) — rule of thumb

Apps are configured with an `informer.yaml` file in the project root. It declares the app's **data dependencies** (typed slots bound at install time), any **raw API allowlist**, **widgets**, **agents**, **live channel relays** (`channels:`), and **custom roles**. It's uploaded automatically on deploy.

**Rule of thumb — read this before writing to informer.yaml:**

> **For typed resources (dataset / query / datasource / integration): always use `dependencies:` slots. Never `access: datasets:`, `access: queries:`, `access: integrations:`, or `access: datasources:`.**

The legacy `access:` block for typed resources still works at runtime, but it bypasses the install/rebind UI, doesn't support the typed-proxy dispatch (`context.<slot>.search(...)`), and silently breaks the install flow. `access:` keeps one legitimate use: the `apis:` sub-block for raw API paths that don't fit the typed-slot model (e.g. AI model endpoints).

**Without either a populated `dependencies:` section or an `access:` declaration, ALL API access is blocked when the app runs in Informer.**

Minimal shape:

```yaml
# informer.yaml
dependencies:
  sales:
    target: dataset
    defaultBinding: 7d5a9b1e-0c83-4bde-9e2a-3a4b5c6d7e8f
  monthly_summary:
    target: query
    defaultBinding: 9a8b7c6d-5e4f-3a2b-1c0d-fedcba987654

access:
  apis:
    - GET /api/apps-list

roles:
  - id: viewer
    name: Viewer
```

For the full schema — slot field reference (`target` / `runAs` / `options` / `defaultBinding`), row-level security with `$user.*` variables, the modernization recipe for converting a legacy `access:` block to `dependencies:`, integration credential injection, the `libraries:` legacy carve-out, and declaring env-var keys with `env:` (encrypted per-tenant values configured in Admin → Environment) — load `references/informer-yaml.md`.

## Widgets — overview

Apps can expose **widgets**: small, self-contained HTML cards (declared in `informer.yaml`, served from `public/widgets/`) that render inside Informer's widget gallery as iframes at fixed grid sizes. Good for at-a-glance KPIs, sparklines, status indicators.

```yaml
# informer.yaml — widget declaration
widgets:
  cash-balance:
    entry: widgets/cash-balance.html
    label: Cash Balance
    size: { w: 2, h: 1 }
    refresh: 300
```

Widgets are **frontend code** — they access deps via the same three patterns as the main app, and Pattern A (server handler with `context.<slot>`) is strongly preferred because widgets reload on every refresh and the extra Pattern B round-trip shows up visibly.

Load `references/widgets.md` for: full widget HTML template (with theme, loading/error/ready states), SVG charts without libraries (Catmull-Rom spline), iframe constraints (no tooltip overflow, no external stylesheets), hover/filter patterns, project structure example.

## Persistence (App Workspace) — overview

Apps can opt into a **dedicated Postgres schema** by adding a `migrations/` directory with numbered `.sql` files. Informer provisions the schema lazily, isolates it per tenant, and drops it when the app is deleted. All app data access goes through server-side route handlers (`query()` callback) — published apps don't query the workspace from the browser.

```
my-app/
  migrations/
    001-create-orders.sql
    002-add-line-items.sql
```

In dev mode, the Vite plugin auto-provisions a `{slug}-dev` workspace and runs migrations on first start. Manual lifecycle via `npm run workspace:migrate` / `:reset`.

Load `references/persistence.md` for: migration file rules (append-only, alphabetic order, exact-once via `_migrations` table), dev workspace flow, `INFORMER_DEV_WORKSPACE` mechanics, full CRUD example.

## Server-Side Routes — overview

Apps can include **server-side handler files** under `server/` that run in sandboxed V8 isolates on the Informer server. File-convention routing (Next.js-style) maps `server/orders/[id].js` to `/api/orders/:id`.

`/api/{path}` is one namespace with manifest-driven precedence: an Informer platform API declared on your `access:`/`dependencies:` surface **occupies** its path (that method+path always proxies to the platform); every other path dispatches your app's own routes. Occupation is per-method — a `GET /api/tags` declaration leaves `POST /api/tags` to your routes. Don't name a route after a declared platform API: the declaration wins and the route becomes unreachable at that spelling (deploy warns about the collision).

> **Older servers (before Informer 2026.1.2):** app routes answer only at `/api/_server/{path}`. That legacy spelling remains routable on every version, but new apps should write the bare form.

```javascript
// server/orders/index.js
export async function GET({ query, context, request }) {
    const orders = await query('SELECT * FROM orders ORDER BY created_at DESC LIMIT 50');
    return orders;
}

export async function POST({ query, request }) {
    const { customer, total } = request.body;
    const [order] = await query(
        'INSERT INTO orders (customer, total) VALUES ($1, $2) RETURNING *',
        [customer, total]
    );
    return { status: 201, body: order };
}
```

Handlers receive a single argument with the sandbox helpers (`query`, `transaction`, `fetch`, `context`, `respond`, `emit`, `broadcast`, `notify`, `email`, `log`, `crypto`, `env`, `request`). Globals available without destructuring: `markdown`, `base64Encode` / `base64Decode` / `base64UrlEncode` / `base64UrlDecode`, `atob` / `btoa`.

Sandbox constraints: no Node APIs, no filesystem, no direct network — all I/O is through the injected callbacks. 128 MB memory, 30s default wall-clock timeout (configurable via `config.timeout`).

Load `references/server-routes.md` for: full file-convention routing rules, every sandbox helper's calling shape and edge cases, return-value semantics, `respond()` early-ack pattern, `log()` levels and behavior, `notify()` / `email()` (single + bulk), `config.timeout` / `config.roles`, the full orders-API worked example.

## Webhooks — overview

Apps can expose **token-gated external endpoints** under `webhooks/` for receiving callbacks from external services (Stripe, GitHub, Slack, Gmail push). Each URL embeds a signed `?token=` query parameter — unguessable, not anonymous. Handlers run as the app owner.

```javascript
// webhooks/github.js
export async function POST({ crypto, request, env, query }) {
    // GitHub sends `x-hub-signature-256: sha256=<hex>`
    const signature = (request.headers['x-hub-signature-256'] || '').replace(/^sha256=/, '');
    // verifyHmac computes the HMAC and constant-time-compares — no `===` timing leak
    const ok = await crypto.verifyHmac('sha256', env.GITHUB_WEBHOOK_SECRET, request.rawBody, signature);
    if (!ok) {
        return { status: 401, body: { error: 'Invalid signature' } };
    }
    // ...process the event
}
```

Webhook handlers receive the **same bag as server routes** — `query`, `transaction`, `fetch`, `context`, `respond`, `emit`, `broadcast`, `notify`, `email`, `crypto`, `markdown`, `log`, `env`, plus the base64 globals and `request.rawBody` (for HMAC verification). `notify()` and `email()` **are** available (handlers run as the app owner). The only differences are inbound identity: `request.user` is `null` (no user session) and `request.roles` is `[]` — the handler still *runs as* the app owner, so `fetch()`, `notify()`, and `email()` use owner credentials.

Load `references/webhooks.md` for: file-convention routing, the `?token=` issuance/verification flow, full HMAC verification examples (GitHub, Stripe, shared-secret), and reading per-app secrets via the `env` bag (configured in **Admin → Environment** or declared as keys in `informer.yaml` `env:`).

## Channels — overview

Apps can push **live updates to every open page** over a WebSocket Informer owns for them. Name a channel (a relay of events you already `emit()`, or a gated one under `channels/`), subscribe on the page, and `broadcast()` from any server-side handler — no socket code, no credentials, no Redis in the App. **Requires an origin-mode server** (`app.appsBaseUrl`); on a path-mode server the deploy warns (`channels_require_origin_mode`) and `__INFORMER__.channel()` throws `origin_mode_required`.

```yaml
# informer.yaml — every emit('order_created') is also broadcast to `orders`
channels:
  orders:
    description: Live order activity
    on: [order_created, order_shipped]
```

```javascript
// server/orders/[id]/approve.js — broadcast is in every handler bag (routes, webhooks, tools, channel handlers)
export async function POST({ query, request, broadcast }) {
    const [order] = await query(`UPDATE orders SET status = 'approved' WHERE id = $1 RETURNING *`, [request.params.id]);
    await broadcast(`orders/${order.region}`, 'approved', order);   // fire-and-forget, at-most-once, no DB row
    return order;
}
```

```javascript
// on the page — lazy: nothing connects until the first on()
__INFORMER__.channel('orders/east').on('approved', (order, frame) => refreshRow(order));
```

Rule of thumb: **if you'd be upset it was lost, `emit`; if it'd be stale in a second anyway, `broadcast`.** A channel with no `channels/` file is open to every viewer of the App; `@user/<username>` is private to that user with no file needed.

Load `references/channels.md` for: the harness/App ownership model and the origin-mode requirement, the `channels:` field reference and relay rules, `channels/` handlers (`config.roles`, `join` must return exactly `true`, `leave` never throws, the bag carries `channel` + `payload` + `request` and no `respond`), the `broadcast()` error table, the full client API (error codes `join_refused` / `rate_limited` / `disconnected` / `origin_mode_required` / `not_supported`, auto-reconnect with backoff), the React hook, limits, what dev mode does and doesn't enforce, and the phase-2 `send()` note.

## App Context

When running inside Informer (not dev mode), the app receives context:

```javascript
const appId = window.__INFORMER__?.report?.id;
const appName = window.__INFORMER__?.report?.name;
const theme = window.__INFORMER__?.theme; // 'light' or 'dark'
const roles = window.__INFORMER__?.roles; // string[] of assigned role IDs
const user = window.__INFORMER__?.user;   // { username, displayName } of the signed-in viewer
```

`user` is present on every render (main app and widgets). Its main job is naming the viewer's private channel — `` `@user/${__INFORMER__.user.username}` `` — see `references/channels.md`.

When the page is rendering a **widget entry** (not the main app), the context object also carries widget metadata:

```javascript
const widget = window.__INFORMER__?.widget; // { id, label } when rendering a widget; undefined otherwise
```

Use this to branch behavior between the main app surface and a widget render (different fetch URLs, different DOM layout, etc.).

In dev mode, the Vite plugin mocks this with placeholder values (theme defaults to `'light'`, roles defaults to `[]`, user defaults to `{ username: 'dev', displayName: 'Local Developer' }` — override with `mock.user` — no widget context).

### Responding to theme

Use the theme value to adapt your app's appearance:

```javascript
const theme = window.__INFORMER__?.theme || 'light';
document.documentElement.setAttribute('data-theme', theme);
```

```css
:root { --bg: #ffffff; --text: #1a1a1a; }
[data-theme="dark"] { --bg: #1e1e1e; --text: #e0e0e0; }
body { background: var(--bg); color: var(--text); }
```

To override the theme in dev mode, pass `mock.theme` in `vite.config.js`:

```javascript
import informer from '@entrinsik/vite-plugin-informer';

export default {
    plugins: [informer({ mock: { theme: 'dark' } })]
};
```

## HTML5 Client-Side Routing

Apps can use client-side routers (React Router, Vue Router, vanilla `history.pushState`) with HTML5 history mode. Use HTML5 routing — not hash routing — for cleaner URLs and shareable deep links. Hash routing also works but offers no benefit since the server fully supports history routing.

**How it works:** The server injects `<base href="/api/apps/{naturalId}/view/-/">` on every render, so all of your relative URLs (assets, router routes, anchor `href`s) resolve under `/-/`. The `/-/{path*}` route serves a real library file when one matches, and otherwise — for top-level HTML navigations (`Accept: text/html`) — falls through to the host `index.html`. That fall-through is what lets a hard refresh of `/-/orders/123` come back with the SPA shell instead of a 404. Asset requests (`<script src>`, `<link href>`, JSON `fetch()`) keep getting real 404s when their file is missing, so broken-asset bugs aren't masked.

**Best practices:**

- **Use relative paths everywhere.** Because the server sets `<base href>`, write `<a href="orders/123">` and `pushState({}, '', 'orders/123')` — never hard-code `/api/apps/...`. The same code works in dev (where there is no `<base>`) and production.
- **Derive the router `basename` from the `<base>` tag.** This makes it work in both prod (where the base is the full app-view path) and dev (where there is no `<base>` tag and routes live at the root).
- **Set explicit `Accept` on programmatic fetches that expect non-HTML responses.** The server uses `Accept: text/html` to choose between a real 404 and the SPA fallback, so an explicit `Accept: application/json` is the safest signal that you want a 404 if the file is missing.

### Setup with React Router

```jsx
import { createBrowserRouter, RouterProvider } from 'react-router-dom';

// In production, <base href> is set to /api/apps/{naturalId}/view/-/
// In dev mode (vite), there's no <base> tag — fall back to '/'.
const baseEl = document.querySelector('base');
const basename = baseEl ? new URL(baseEl.href).pathname : '/';

const router = createBrowserRouter(
    [
        { path: '/', element: <Home /> },
        { path: '/settings', element: <Settings /> },
        { path: '/dashboard/:id', element: <Dashboard /> }
    ],
    { basename }
);

function App() {
    return <RouterProvider router={router} />;
}
```

### Setup with Vue Router

```javascript
import { createRouter, createWebHistory } from 'vue-router';

const baseEl = document.querySelector('base');
const basename = baseEl ? new URL(baseEl.href).pathname : '/';

const router = createRouter({
    history: createWebHistory(basename),
    routes: [
        { path: '/', component: Home },
        { path: '/settings', component: Settings },
        { path: '/dashboard/:id', component: Dashboard }
    ]
});
```

### Vanilla `history.pushState`

```javascript
function getBase() {
    const baseEl = document.querySelector('base');
    return baseEl ? new URL(baseEl.href).pathname : '/';
}

// Navigate — pass a path relative to the base href.
function navigate(path) {
    history.pushState({}, '', getBase() + path.replace(/^\/+/, ''));
    render();
}

window.addEventListener('popstate', render);
```

### Dev Mode

In local development, Vite's dev server handles HTML5 fallback automatically — no extra configuration needed. Because the basename derivation above checks for the `<base>` tag (which Vite does not inject), routes resolve at the root in dev and under `/api/apps/{naturalId}/view/-/` in production with no environment-specific code.

### Important Notes

- **Asset 404s still fire when expected.** A `<script src="missing.js">` or `fetch('data.json')` for a file that isn't in the library returns a real 404 — the SPA fallback only triggers on `Accept: text/html` requests.
- **API routes are unaffected.** Requests to `/view/api/...` still proxy to the Informer API.
- **Empty path lands on the SPA root.** A request to `/api/apps/{id}/view/-/` (no path) serves the host page, so `<a href="">` or programmatic navigation to the base href works as expected.

## App Roles

Apps can define custom roles that publishers assign when sharing. This enables role-based UIs — showing or hiding features based on the viewer's role.

### Defining Roles

Add a `roles:` section to your `informer.yaml`:

```yaml
# informer.yaml
roles:
  - id: viewer
    name: Viewer
    description: Can view reports but not take actions
  - id: approver
    name: Approver
    description: Can approve or reject requests
  - id: manager
    name: Manager
    description: Full management access
```

Each role has:
- `id` (required) — string identifier used in code
- `name` (required) — display name shown in share dialogs
- `description` (optional) — help text shown in share dialogs

### Reading Roles in App Code

```javascript
const roles = window.__INFORMER__?.roles || [];

if (roles.includes('approver')) {
    showApprovalPanel();
}

if (roles.includes('manager')) {
    showAdminSettings();
}
```

`roles` is a flat `string[]` of role IDs. It's always an array (empty if no roles are defined or assigned).

### How Role Assignment Works

- **Internal shares** — when a Publisher shares the app with a team/user, they can select which roles to assign via checkboxes in the share dialog
- **External links** — when creating an external share link, the Publisher selects roles in the Configure step; those roles are baked into the token
- **Publisher+ on the owning team** — automatically receives all defined roles (admin override)
- **No `roles:` section** — if `informer.yaml` has no `roles:` key, `window.__INFORMER__.roles` is `[]` (binary access, no role-based features)
- **Removed roles** — if a role is removed from `informer.yaml`, it silently disappears from users' role arrays; existing shares retain the stale role ID but it's filtered out at view time

### Mock Roles in Dev Mode

Configure mock roles in `vite.config.js`:

```javascript
import informer from '@entrinsik/vite-plugin-informer';

export default {
    plugins: [informer({ mock: { roles: ['approver', 'manager'] } })]
};
```

## App Accounts & Public Serving — overview

On deployments with per-app origins, an app can face the WORLD, not just
Informer users: `public: true` serves the page + assets anonymously,
`server/public/**` handlers dispatch with no session (`/api/public/...`,
`request.user = null`), and `accounts.issuers` gives the app its OWN
sign-up/login (`/_auth/signup|login|logout|reset`) with platform-held
credentials — plus OIDC (`/_auth/oidc/{name}`), a ready-made
"Sign in with Informer" link (`/_auth/informer`), and acceptance of other
apps' users (`accounts.accept`). Every door yields one unified
`request.user` (`{ id, issuer, subject, email, name, claims }`; Informer
viewers also keep `username`/`displayName`), and `request.roles` combines
the issuer's default with Users-tab grants. Account sessions can never call
platform APIs — the app's own routes are their surface.

Load `references/accounts-and-login.md` for the full route table, manifest
shapes, and limits before building any of this.

## Built-in App Copilot — overview

Every Informer App gets a **built-in AI copilot sidebar** — a chat panel that slides in from the right side of the app window. Hidden by default; activates automatically when the app calls `registerTool()`, or explicitly via `showCopilot()`, or via a paint-your-own button that calls `openChat({ prompt, context, instructions })`.

```javascript
__INFORMER__.openChat({
    prompt: 'Why did revenue spike in Q4?',
    context: { revenue: 1250000, quarter: 'Q4' },
    instructions: 'Use the Informer API to query the sales-data dataset for year-over-year Q4 trends.'
});
```

Apps can also call Informer's AI directly via three endpoints (use the `go_everyday` model slug): `_chat` (SSE stream, supports tools), `_completion` (SSE stream, simple text), `_object` (JSON, structured output). All three accept `outputSize` (`small` / `medium` / `large`) on current servers.

Load `references/copilot.md` for: full `openChat()` / `showCopilot()` / `registerTool()` reference, the report-bridge bidirectional pattern, AI SDK UIMessage format (parts arrays, not OpenAI), the inline tools object-keyed-by-name format, SSE event types and stream parsing, the `useChat` React hook pattern with `addToolOutputRef`, defensive parsing for `_object` Haiku drift, dev-mode mocks.

## Agents — overview

Apps can declare **agents** in `informer.yaml` — AI-powered workflows that listen for events, execute tools defined in `tools/*.js`, and chain together to automate complex tasks. Two trigger paths: event-driven (via `emit()`) and cron-scheduled. Declare `onFailure: <event>` on an agent to emit an error event when a run terminally fails, so the workflow branches to a handler instead of stalling.

```yaml
# informer.yaml
agents:
  validate-order:
    description: "Validates new orders and checks inventory"
    instructions: |
      When an order_created event arrives, use check_inventory for each item.
      If all in stock, use update_status to confirm. Otherwise mark backordered.
    tools:
      - check_inventory
      - update_status
    on: order_created

  daily-digest:
    description: "Daily activity summary"
    instructions: |
      Query today's orders and send a notification.
    tools:
      - send_notification
    cron: "0 8 * * 1-5"
```

Tools live in `tools/` and share the same V8 sandbox as server route handlers. A tool exports a named `handler` that receives a **single bag** with the same service surface as routes/webhooks — `context` (typed deps), `query`, `transaction`, `fetch`, `emit`, `broadcast`, `notify`, `email`, `crypto`, `markdown`, `log`, `env` — plus `args` (the AI tool input) and `run` (`{ appId, agentId, runId, trigger }`):

```javascript
// tools/notifications/send_email.js
export const description = 'Email a user';
export const schema = { properties: { to: { type: 'string' } }, required: ['to'] };
export async function handler({ args, email }) {
    return await email(args.to, { subject: 'Hi', html: '<p>Hello</p>' });
}
```

Tool names mirror the file path with underscores: `tools/notifications/send_email.js` → `notifications_send_email`.

Load `references/agents.md` for: full `agents:` field reference (`tools` / `toolkits` / `assistants` / `on` / `cron` / `webSearch` / `onFailure` / `model`), tool file structure, event emission (server routes + agent chaining via `emit()`), the `onFailure` error-transition pattern (emit-on-terminal-failure with envelope + loop guard), toolkit integration (system-level + deploy validation), assistant prompt merging, cron lifecycle (separate `app_automation` table, bypasses event queue), agent REST API, local dev with `/api/_agent/{name}/_trigger`, full order-processing pipeline example.

## MCP server — overview

An app with an **`mcp/` directory** is an MCP server: outside AI clients (Claude Code, Claude Desktop, Cursor) connect to a per-app endpoint, the user signs in through Informer, and the client can call the app's exposed tools. Deploy scans `mcp/` alongside `tools/`, so `npm run deploy` is the whole setup — **the folder is the declaration**, no manifest block or flag.

`mcp/` and `tools/` share the file contract (`description`, `schema`, `handler`), the sandbox, and the service bag. The only difference is who may call them, and it is load-bearing:

- **`tools/`** — the app's own agents call these. An agent tool is safe *because* its `instructions` (which you wrote) decide when it fires and with what.
- **`mcp/`** — any MCP client the app is shared with can call these, and so can the app's agents. A stranger's model picks the moment and the arguments, from your `description` and `schema` alone.

So a tool goes in `mcp/` only when it was **written knowing a stranger's LLM will call it**: narrow, self-describing, no assumption of surrounding context. Don't move an agent tool into `mcp/` to reuse it without re-reading it that way. Names live in one namespace across both folders (a duplicate fails the deploy); agents may reference `mcp/` tools, never the reverse.

```javascript
// mcp/find_order.js — the description IS the API doc; the calling model
// sees nothing else. Runs as the signed-in user (run.user / run.roles),
// run.trigger === 'mcp'.
export const description = 'Look up an order by customer name or number, with its shipment if it has one';
export const schema = {
    type: 'object',
    properties: { customer: { type: 'string' }, id: { type: 'integer' } },
    additionalProperties: false,
};
export async function handler({ args, query, run }) {
    const orders = await query('SELECT * FROM orders WHERE customer ILIKE $1 LIMIT 20', [`%${args.customer}%`]);
    return { found: orders.length, orders };
}
```

Connect with `claude mcp add --transport http my-app <endpoint>` (the endpoint is the `inf:app-mcp` rel and the admin panel's **MCP** tab; never hand-build it). First tool use pops a browser: RFC 9728 discovery → self-registration → PKCE → a token bound to that one app. Self-registration needs a tenant admin to enable it (Admin → Settings → Security); while it's off, clients connect with an API-token header instead.

Load `references/mcp.md` for: the `mcp/` vs `tools/` decision in depth (including the `emit()`-tool trap), writing tools for a context-free caller (descriptions as API docs, self-describing returns, no guessing), the identity model (`runAs` slots, `run.user`/`run.roles`, and why the app's own workspace is not per-caller so **the tool is the access control**), the full OAuth/discovery/DCR flow, curl-testing the endpoint, observability, and gotchas.

## PDF Export

Apps can be exported to PDF via `POST /api/apps/{id}/_print`.

### How it works

1. Informer opens your app in a headless browser (Puppeteer)
2. Waits for network requests to complete
3. Waits for `window.informerReady !== false` — undefined / null / unset all pass immediately; only an explicit `false` blocks until timeout. Set it to `false` early in your app shell, then to `true` once data is loaded.
4. Adds `.print` class to `<html>`
5. Captures the page as PDF using print media

### Signal when ready

Set `window.informerReady` to signal when your app is fully rendered:

```javascript
// Start of app
window.informerReady = false;

// After all charts/content rendered
window.informerReady = true;
```

### Rendering details

- **Print media is used** - Standard `@media print` CSS rules apply
- **`.print` class added** - Informer adds a `.print` class to `<html>` for additional targeting
- **Viewport is 1200px** by default (configurable via `viewportWidth` option)
- **Box shadows are removed** - They render as grey boxes in PDFs
- **Colors are preserved** - `print-color-adjust: exact` is applied automatically

### Print CSS

Use standard `@media print` rules or the `.print` class:

```css
/* Standard print media query */
@media print {
    body {
        background: white;
        color: black;
    }

    .no-print {
        display: none;
    }
}

/* Or use the .print class (added by Informer) */
.print .no-print {
    display: none;
}

/* Avoid page breaks inside elements */
.chart-container {
    break-inside: avoid;
}
```

### Print API options

```javascript
await fetch(`/api/apps/${appId}/_print`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        format: 'Letter',        // Letter, Legal, Tabloid, A3, A4, A5
        landscape: false,
        viewportWidth: 1200,     // 400-2400, affects responsive layouts
        waitForReady: true,      // Wait for window.informerReady
        save: false              // true = save to downloads, false = return PDF
    })
});
```

## Reference Files

The orientation above points to each file; this is the canonical list of what's available under `references/`:

| File | Covers |
|---|---|
| `references/server-routes.md` | `server/` handlers, full sandbox-helper reference (`query`, `transaction`, `fetch`, `respond`, `notify`, `email`, `log`, `crypto`, base64/markdown globals), `config.timeout` / `config.roles`, worked CRUD example |
| `references/webhooks.md` | `webhooks/` handlers, signed `?token=` flow, HMAC verification (`crypto.verifyHmac`), how webhooks differ from server routes (inbound identity only — same handler bag) |
| `references/persistence.md` | `migrations/`, dev workspace lifecycle, CRUD worked example |
| `references/widgets.md` | `widgets:` declaration, self-contained HTML template, iframe constraints, SVG charts without libraries |
| `references/copilot.md` | `openChat()` / `showCopilot()` / `registerTool()`, AI completion endpoints (`_chat` / `_completion` / `_object`), `useChat` hook pattern, defensive `_object` parsing |
| `references/agents.md` | `agents:` declaration, `tools/*.js`, event chaining via `emit()`, cron lifecycle, toolkits/assistants, agent REST API |
| `references/channels.md` | Live broadcast to open pages — origin-mode requirement, `channels:` relay block, `channels/` handlers (`config` / `join` / `leave`, the channel bag), `broadcast()` + error table, `@user/<username>`, the `__INFORMER__.channel()` client API (error codes, reconnect), `broadcast()` vs `emit()`, limits, dev-mode coverage, phase-2 `send()` |
| `references/mcp.md` | The `mcp/` folder, `mcp/` vs `tools/` split, writing tools for a context-free caller, identity (`runAs` / `run.user` / `run.roles`, workspace-not-per-caller), the per-app endpoint, OAuth discovery + DCR connect flow, curl testing, observability |
| `references/informer-yaml.md` | Full `informer.yaml` schema deep dive — slot fields, `$user.*` variables, modernizing legacy `access:` blocks, declaring env-var keys with `env:` |
| `references/docs-html.md` | In-gallery `docs.html` page, in-app `?` help button, `README.md` fallback |
| `references/api-reference.md` | Raw API surface behind the typed-slot proxy (useful for diagnostics) |
| `references/app-templates.md` | HTML/CSS/JS starter snippets — charts, layouts |
| `references/wasm-workers.md` | Running WASM / Web-Worker libs in the sandbox — why `new Worker(url)` fails on the opaque origin, the local-bundle + blob-worker pattern, handing wasm to the worker as a blob URL, external fetch targets as `data` Approved Resources, loading Informer data into the engine |

## Terminology Note

Informer Apps were previously called "Magic Reports". The underlying technology is the same — the rename reflects their broader role as full applications with built-in AI copilots, not just static reports. The deploy tool automatically detects which API your server supports (`/api/apps` or the legacy `/api/reports`) and uses the correct one.
