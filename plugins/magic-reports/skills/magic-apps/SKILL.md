---
name: magic-apps
description: Building Informer Apps with local Vite development. Covers the dev/publish workflow, key Informer APIs, app persistence (SQL workspace + migrations), server-side route handlers, and the built-in AI copilot sidebar.
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

Apps are stored in Informer libraries and served through the Informer UI. (You may see the term "Magic Report" in older documentation — Apps are the current name for the same concept.)

## Local Development Workflow

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

If your app uses persistence (see [Persistence](#persistence-app-workspace)), you'll also have:
```
INFORMER_DEV_WORKSPACE=admin:my-app-dev
```
This is set automatically by `npm run workspace:init`.

### Deploying (`npm run deploy`)

Builds your project and uploads to Informer:
1. Creates/finds an App via the `/api/apps` endpoint (falls back to legacy `/api/reports` on older servers)
2. Snapshots the library for rollback
3. Clears existing files
4. Uploads all built assets from `dist/`
5. Uploads `informer.yaml` and `data-access.yaml` from project root (if they exist)
6. Uploads `migrations/` directory (if it exists)
7. Uploads `server/` directory (if it exists)
8. Runs deploy: pending SQL migrations + server-route scanning + handler bundling
9. App is viewable at `/api/apps/{owner}:{slug}/view`

### Package.json Configuration

The `informer` section in `package.json` controls deploy metadata:

```json
{
  "informer": {
    "name": "Sales Dashboard",
    "description": "Regional sales performance overview",
    "id": "a1b2c3d4-..."
  }
}
```

| Field | Description |
|-------|-------------|
| `name` | Display name in Informer (falls back to package `name`) |
| `description` | App description |
| `id` | App UUID (auto-saved after first deploy) |

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

## Discovering Resources

Once `.env` is configured, Claude can query the Informer API directly to help you find available resources. Ask Claude to look up:

- **Integrations**: `curl -u $USER:$PASS "$INFORMER_URL/api/integrations"` - Find integration slugs for QuickBooks, Salesforce, etc.
- **Datasets**: `curl -u $USER:$PASS "$INFORMER_URL/api/datasets-list"` - Find dataset IDs and field names
- **Queries**: `curl -u $USER:$PASS "$INFORMER_URL/api/queries-list"` - Find saved query IDs
- **Datasources**: `curl -u $USER:$PASS "$INFORMER_URL/api/datasources"` - Find SQL datasource IDs

This helps you find the correct IDs/slugs to use in your code and `data-access.yaml`. Just ask Claude to "show me available integrations" or "find the QuickBooks integration slug".

## Key APIs

All endpoints are relative to `/api`. In dev mode, the Vite proxy handles auth.

### List Datasets

```javascript
const response = await fetch('/api/datasets-list');
const datasets = await response.json();
// Returns: [{ id, name, description, records, size, ... }, ...]
```

Use this to discover available datasets. Each dataset has:
- `id` - UUID or natural ID like `admin:sales-data`
- `name` - Display name
- `records` - Approximate record count

### Search Dataset (Elasticsearch)

```javascript
const response = await fetch(`/api/datasets/${datasetId}/_search`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        query: { match_all: {} },
        size: 100,
        from: 0,
        _source: ['field1', 'field2'],  // Optional: limit fields returned
        sort: [{ field1: 'desc' }],      // Optional: sort order
        aggs: {                          // Optional: aggregations
            total: { sum: { field: 'amount' } }
        }
    })
});
const result = await response.json();

// Response structure:
// result.hits.total - total matching records
// result.hits.hits - array of { _source: { field1, field2, ... } }
// result.aggregations - aggregation results (if requested)
```

**Common query patterns:**

```javascript
// Filter by exact value
{ query: { bool: { filter: [{ term: { status: 'active' } }] } } }

// Filter by range
{ query: { bool: { filter: [{ range: { amount: { gte: 1000 } } }] } } }

// Date range
{ query: { bool: { filter: [{ range: { date: { gte: '2024-01-01', lte: '2024-12-31' } } }] } } }

// Multiple filters (AND)
{ query: { bool: { filter: [
    { term: { region: 'North' } },
    { range: { amount: { gte: 1000 } } }
] } } }
```

**Common aggregations:**

```javascript
// Sum, avg, min, max
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

### List Queries

```javascript
const response = await fetch('/api/queries-list');
const queries = await response.json();
// Returns: [{ id, name, description, ... }, ...]
```

### Execute Query

```javascript
const response = await fetch(`/api/queries/${queryId}/_execute`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        parameters: { param1: 'value1' }  // Optional query parameters
    })
});
const result = await response.json();
```

### List Integrations

```javascript
const response = await fetch('/api/integrations');
const result = await response.json();
// result.items = [{ id, name, slug, type, ... }, ...]
```

Integrations are authenticated connections to external APIs (Salesforce, REST APIs, etc.).

### Make Integration Request

```javascript
const response = await fetch(`/api/integrations/${slugOrId}/request`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        url: '/data/v59.0/query',           // Path relative to integration's base URL
        method: 'GET',                       // HTTP method
        params: { q: 'SELECT Id FROM Account' },  // Query params
        data: { /* body for POST/PUT */ },   // Request body
        headers: { /* extra headers */ }     // Additional headers
    })
});
const result = await response.json();

// Response structure:
// result.status - HTTP status code
// result.data - response body from the external API
// result.error - true if upstream returned an error status
```

**Salesforce example:**
```javascript
const response = await fetch('/api/integrations/salesforce/request', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        url: '/data/v59.0/query',
        method: 'GET',
        params: {
            q: "SELECT Id, Name, Amount FROM Opportunity WHERE StageName = 'Closed Won'"
        }
    })
});
const result = await response.json();
const records = result.data.records;
```

## App Configuration (`informer.yaml`)

Apps are configured with an `informer.yaml` file in the project root. This single file declares **data access** (which APIs the app can call), **roles** (for role-based UIs), and other app-level settings. It's uploaded automatically on deploy.

```yaml
# informer.yaml

access:
  datasets:
    - admin:sales-data
    - admin:customers
  queries:
    - admin:monthly-summary
  integrations:
    - salesforce

roles:
  - id: viewer
    name: Viewer
    description: Can view reports but not take actions
  - id: approver
    name: Approver
    description: Can approve or reject requests
```

The `access:` section controls which APIs the app can call when shared. The `roles:` section defines custom roles for role-based UI (see [App Roles](#app-roles)).

**Important:** Without an `access:` section (or a standalone `data-access.yaml`), all API access is blocked when the app runs in Informer.

> **Legacy note:** You can also use a standalone `data-access.yaml` file (without the `access:` wrapper key). If both files exist, `informer.yaml` takes precedence. New apps should use `informer.yaml` since it supports both access and roles in one file.

### Basic Data Access Example

```yaml
# informer.yaml
access:
  datasets:
    - admin:sales-data
    - admin:customers

  queries:
    - admin:monthly-summary

  integrations:
    - salesforce
```

### With Row-Level Security

Restrict data based on the viewing user's profile:

```yaml
# informer.yaml
access:
  datasets:
    # Users only see their region's data
    - id: admin:orders
      filter:
        region: $user.custom.region

    # Users only see their own records
    - id: admin:sales
      filter:
        sales_rep: $user.username
```

### Integration with Credentials

Pass user-specific credentials to external APIs:

```yaml
# informer.yaml
access:
  integrations:
    - id: partner-api
      headers:
        Authorization: Bearer $user.custom.partnerToken
      params:
        client_id: $tenant.id
```

### Available Variables

| Variable | Description |
|----------|-------------|
| `$user.username` | Login name |
| `$user.email` | Email address |
| `$user.displayName` | Full name |
| `$user.custom.xxx` | Custom user field |
| `$tenant.id` | Tenant ID |
| `$report.id` | App UUID |

### Resource Types

| Type | API Access Granted |
|------|-------------------|
| `datasets` | `_search`, `fields` |
| `queries` | `_execute` |
| `datasources` | `_query` |
| `integrations` | `request` |
| `libraries` | `contents/*` |

For edge cases, you can also whitelist raw API paths:

```yaml
# informer.yaml
access:
  apis:
    - POST /api/custom/endpoint
```

## Persistence (App Workspace)

Apps can opt into a **dedicated Postgres schema** for storing and querying custom data. This is ideal for apps that need CRUD operations, form submissions, workflow state, or any data that belongs to the app itself rather than coming from external datasources or datasets.

### How It Works

When your project has a `migrations/` directory containing `.sql` files, Informer provisions a dedicated Postgres schema for the app. The schema is:
- **Tenant-isolated** — owned by the tenant role, inaccessible to other tenants
- **Lazily provisioned** — created on first query or explicit migration
- **Automatically cleaned up** — dropped when the app is deleted

### Migration Files

Create a `migrations/` directory in your project root. Add numbered `.sql` files that run in alphabetical order:

```
my-app/
  migrations/
    001-create-orders.sql
    002-add-status-column.sql
    003-add-indexes.sql
  src/
    main.js
  index.html
  package.json
```

Each migration file contains standard SQL:

```sql
-- migrations/001-create-orders.sql
CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    customer TEXT NOT NULL,
    total NUMERIC(10,2) DEFAULT 0,
    status TEXT DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

```sql
-- migrations/002-add-line-items.sql
CREATE TABLE line_items (
    id SERIAL PRIMARY KEY,
    order_id INTEGER REFERENCES orders(id) ON DELETE CASCADE,
    product TEXT NOT NULL,
    quantity INTEGER DEFAULT 1,
    price NUMERIC(10,2) NOT NULL
);

CREATE INDEX line_items_order_idx ON line_items (order_id);
```

**Rules:**
- Files must end in `.sql` and are sorted alphabetically (use numeric prefixes)
- Each migration runs exactly once — Informer tracks completed migrations in a `_migrations` table
- Migrations are **append-only** — never modify a migration that has already been deployed. Add a new file instead.
- Each migration runs in its own transaction

### Querying the Workspace

All database access goes through [server-side route handlers](#server-side-routes). The `query()` callback in server handlers executes SQL against the app's workspace — see [Using `query()`](#using-query) for details.

There is no client-side query endpoint. Client code calls server routes via `fetch('/api/_server/...')`, and server handlers use `query()` for database access.

### Local Development with Workspaces

In dev mode, the Vite plugin automatically provisions a **dev workspace** — a separate Postgres schema on the Informer server. This keeps development completely isolated from the deployed app's production data.

**Auto-provisioning:** When your project has a `migrations/` directory and `.env` is configured with `INFORMER_URL`, the Vite plugin:
1. Creates a workspace datasource `{slug}-dev` on the server (first run)
2. Runs all pending `migrations/*.sql` files
3. Saves `INFORMER_DEV_WORKSPACE=admin:{slug}-dev` to `.env`

Server route `query()` calls use this dev workspace automatically during local development.

**Manual workspace management:**

```bash
# Re-run pending migrations
npm run workspace:migrate

# Start fresh (drop all tables, re-run all migrations)
npm run workspace:reset
```

**Add these scripts to `package.json`:**

```json
{
    "scripts": {
        "workspace:init": "informer-workspace init",
        "workspace:migrate": "informer-workspace migrate",
        "workspace:reset": "informer-workspace reset"
    }
}
```

These scripts are added automatically if you run `informer-init`.

### Full Example: CRUD App

```
my-order-tracker/
  migrations/
    001-create-orders.sql
    002-create-line-items.sql
  server/
    orders/
      index.js           → GET,POST /orders
      [id].js            → GET,PUT,DELETE /orders/:id
  public/
    favicon.svg
  src/
    main.js
  informer.yaml
  index.html
  package.json
  .env
```

```javascript
// src/main.js

// Load orders
async function loadOrders() {
    const response = await fetch('/api/_server/orders');
    const orders = await response.json();
    renderOrderTable(orders);
}

// Create order
async function createOrder(customer, total) {
    const response = await fetch('/api/_server/orders', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ customer, total })
    });
    if (!response.ok) {
        const err = await response.json();
        alert(err.error);
        return;
    }
    loadOrders(); // refresh
}

// Delete order
async function deleteOrder(id) {
    await fetch(`/api/_server/orders/${id}`, { method: 'DELETE' });
    loadOrders(); // refresh
}

loadOrders();
```

## Server-Side Routes

Apps can include **server-side JavaScript handlers** that run on the Informer server in sandboxed V8 isolates. These handlers have direct access to the app's Postgres workspace and can make authenticated API calls — ideal for business logic, data transformations, webhooks, or anything that shouldn't run in the browser.

### How It Works

1. Create a `server/` directory in your project root
2. Add `.js` handler files using file-convention routing (like Next.js)
3. Run `npm run deploy` — Informer scans, bundles, and registers routes automatically
4. Your app calls server routes via `fetch('/api/_server/...')`

Handler code runs in an **isolated-vm V8 isolate** — a separate V8 heap with no access to Node.js APIs, the filesystem, or the network. All I/O goes through injected callbacks (`query` and `fetch`).

### File-Convention Routing

File paths under `server/` map to URL routes:

| File | Route | Example URL |
|------|-------|-------------|
| `server/index.js` | `/` | `/api/_server/` |
| `server/orders/index.js` | `/orders` | `/api/_server/orders` |
| `server/orders/[id].js` | `/orders/:id` | `/api/_server/orders/abc123` |
| `server/orders/[id]/approve.js` | `/orders/:id/approve` | `/api/_server/orders/abc123/approve` |

- `[param]` segments become dynamic route parameters (available as `request.params.param`)
- `index.js` files map to the parent directory path

### Handler Structure

Each handler file exports **named functions** for each HTTP method it supports:

```javascript
// server/orders/index.js

export async function GET({ query, request }) {
    const rows = await query('SELECT * FROM orders ORDER BY created_at DESC LIMIT 50');
    return rows;
}

export async function POST({ query, request }) {
    const { customer, total } = request.body;
    const rows = await query(
        'INSERT INTO orders (customer, total) VALUES ($1, $2) RETURNING *',
        [customer, total]
    );
    return { status: 201, body: rows[0] };
}
```

**Supported methods:** `GET`, `POST`, `PUT`, `PATCH`, `DELETE`

Each handler function receives a single context object with these properties:

| Property | Type | Description |
|----------|------|-------------|
| `query` | `async (sql, params?) => rows` | Execute SQL against the app's workspace. Returns an array of row objects. |
| `fetch` | `async (path, options?) => { status, body }` | Make an authenticated API call through Informer (subject to the app's whitelist). |
| `env` | `object` | App environment variables (from app settings). |
| `request` | `object` | The incoming request (see below). |

**`request` object:**

| Property | Type | Description |
|----------|------|-------------|
| `request.method` | `string` | HTTP method (`GET`, `POST`, etc.) |
| `request.path` | `string` | Matched route path (e.g. `/orders/:id`) |
| `request.params` | `object` | Route parameters (e.g. `{ id: 'abc123' }`) |
| `request.query` | `object` | Query string parameters |
| `request.body` | `any` | Request body (parsed JSON for POST/PUT/PATCH) |
| `request.headers` | `object` | Request headers |
| `request.roles` | `string[]` | The viewer's assigned role IDs (see [App Roles](#app-roles)) |

### Return Values

Handlers can return values in two formats:

**Simple value** — automatically wrapped as a 200 JSON response:
```javascript
export async function GET({ query }) {
    const rows = await query('SELECT * FROM orders');
    return rows; // → 200, Content-Type: application/json
}
```

**Response object** — full control over status, headers, and body:
```javascript
export async function POST({ query, request }) {
    const { customer } = request.body;
    if (!customer) {
        return { status: 400, body: { error: 'Customer is required' } };
    }

    const rows = await query(
        'INSERT INTO orders (customer) VALUES ($1) RETURNING *',
        [customer]
    );
    return { status: 201, body: rows[0] };
}
```

**No return value** — returns 204 No Content:
```javascript
export async function DELETE({ query, request }) {
    await query('DELETE FROM orders WHERE id = $1', [request.params.id]);
    // implicit 204
}
```

### Using `query()`

The `query` callback executes SQL against the app's Postgres workspace — the same schema managed by `migrations/`. It takes a SQL string and an optional params array, and returns the result rows directly.

```javascript
export async function GET({ query, request }) {
    // Parameterized query (always use $1, $2, etc.)
    const orders = await query(
        'SELECT * FROM orders WHERE status = $1 ORDER BY created_at DESC',
        [request.query.status || 'pending']
    );

    // Aggregation
    const [stats] = await query(`
        SELECT COUNT(*) as count, SUM(total) as revenue
        FROM orders WHERE status = 'completed'
    `);

    return { orders, stats };
}
```

All `query()` calls within a single request share the same database connection, which is automatically closed when the handler completes.

### Using `fetch()`

The `fetch` callback makes authenticated API calls through Informer, using the viewer's credentials. It goes through the same whitelist as client-side API calls, so the endpoint must be allowed in `informer.yaml`.

```javascript
export async function GET({ fetch }) {
    // Fetch data from a dataset
    const result = await fetch('datasets/admin:sales-data/_search', {
        method: 'POST',
        body: { query: { match_all: {} }, size: 100 }
    });

    return result.body.hits.hits.map(h => h._source);
}

export async function POST({ fetch, request }) {
    // Call an integration
    const result = await fetch('integrations/salesforce/request', {
        method: 'POST',
        body: {
            url: '/data/v59.0/sobjects/Contact',
            method: 'POST',
            data: request.body
        }
    });

    return { status: result.status, body: result.body };
}
```

The `path` argument is relative to `/api/` — pass `'datasets/admin:sales-data/_search'`, not `'/api/datasets/...'`.

### Handler Config

Handlers can export a `config` object to customize behavior:

```javascript
// server/webhooks/stripe.js

export const config = {
    timeout: 60000,            // Wall-clock timeout in ms (default: 30000)
    roles: ['admin', 'manager'] // Restrict to specific roles (see App Roles)
};

export async function POST({ query, request }) {
    // Only users with 'admin' or 'manager' role can reach this handler
    const event = request.body;
    await query('INSERT INTO webhook_events (type, payload) VALUES ($1, $2)', [
        event.type,
        JSON.stringify(event)
    ]);
    return { status: 200, body: { received: true } };
}
```

| Config | Type | Default | Description |
|--------|------|---------|-------------|
| `timeout` | `number` | `30000` | Wall-clock timeout in ms. Handler is killed if it exceeds this. |
| `roles` | `string[]` | `[]` (open) | If set, only viewers with at least one matching role can call this route. Returns 403 otherwise. |

### Sandbox Constraints

Server handlers run in a sandboxed V8 isolate. This means:

- **No Node.js APIs** — no `require()`, `fs`, `http`, `process`, `Buffer`, etc.
- **No network access** — all external calls must go through `fetch()` (which enforces the whitelist)
- **No filesystem** — use `query()` for persistence
- **128 MB memory limit** — the isolate is killed if it exceeds this
- **Wall-clock timeout** — defaults to 30s, configurable via `config.timeout`
- **Ephemeral** — a fresh isolate is created for each request; no state persists between calls

### Calling Server Routes from App Code

Server routes are accessed through the app's view API proxy at `/api/_server/`:

```javascript
// GET /api/_server/orders
const response = await fetch('/api/_server/orders');
const orders = await response.json();

// POST /api/_server/orders
const response = await fetch('/api/_server/orders', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ customer: 'Acme Corp', total: 1500 })
});
const newOrder = await response.json();

// GET /api/_server/orders/abc123
const response = await fetch('/api/_server/orders/abc123');
const order = await response.json();

// POST /api/_server/orders/abc123/approve
const response = await fetch('/api/_server/orders/abc123/approve', {
    method: 'POST'
});
```

Server routes use the same authentication as the rest of the app's API proxy — the view token cookie is automatically included.

### Project Structure with Server Routes

```
my-app/
  migrations/
    001-create-orders.sql
    002-create-line-items.sql
  server/
    index.js              → GET /
    orders/
      index.js            → GET,POST /orders
      [id].js             → GET,PUT,DELETE /orders/:id
      [id]/
        approve.js        → POST /orders/:id/approve
        line-items.js     → GET,POST /orders/:id/line-items
  public/
    favicon.svg
  src/
    main.js
  informer.yaml
  index.html
  package.json
  .env
```

### Full Example: Orders API

**Migration:**
```sql
-- migrations/001-create-orders.sql
CREATE TABLE orders (
    id SERIAL PRIMARY KEY,
    customer TEXT NOT NULL,
    total NUMERIC(10,2) DEFAULT 0,
    status TEXT DEFAULT 'pending',
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

**Server handlers:**
```javascript
// server/orders/index.js

export async function GET({ query, request }) {
    const status = request.query.status;
    if (status) {
        return await query('SELECT * FROM orders WHERE status = $1 ORDER BY created_at DESC', [status]);
    }
    return await query('SELECT * FROM orders ORDER BY created_at DESC LIMIT 100');
}

export async function POST({ query, request }) {
    const { customer, total } = request.body;
    if (!customer) {
        return { status: 400, body: { error: 'Customer is required' } };
    }
    const [order] = await query(
        'INSERT INTO orders (customer, total) VALUES ($1, $2) RETURNING *',
        [customer, total || 0]
    );
    return { status: 201, body: order };
}
```

```javascript
// server/orders/[id].js

export async function GET({ query, request }) {
    const [order] = await query('SELECT * FROM orders WHERE id = $1', [request.params.id]);
    if (!order) return { status: 404, body: { error: 'Order not found' } };
    return order;
}

export async function PUT({ query, request }) {
    const { customer, total, status } = request.body;
    const [order] = await query(
        'UPDATE orders SET customer = COALESCE($1, customer), total = COALESCE($2, total), status = COALESCE($3, status) WHERE id = $4 RETURNING *',
        [customer, total, status, request.params.id]
    );
    if (!order) return { status: 404, body: { error: 'Order not found' } };
    return order;
}

export async function DELETE({ query, request }) {
    const [order] = await query('DELETE FROM orders WHERE id = $1 RETURNING id', [request.params.id]);
    if (!order) return { status: 404, body: { error: 'Order not found' } };
}
```

**Client code:**
```javascript
// src/main.js

async function loadOrders() {
    const response = await fetch('/api/_server/orders');
    const orders = await response.json();
    renderTable(orders);
}

async function createOrder(customer, total) {
    const response = await fetch('/api/_server/orders', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ customer, total })
    });
    if (!response.ok) {
        const err = await response.json();
        alert(err.error);
        return;
    }
    loadOrders();
}
```

### Local Development

Server routes run locally during `npm run dev` via Vite's `ssrLoadModule()`. The Vite plugin:
1. Detects a `server/` directory in your project
2. Mounts middleware at `/api/_server` that loads and executes your handler files
3. Passes the dev workspace connection to `query()` and proxies `fetch()` to the Informer server
4. Supports HMR — editing a server handler file takes effect immediately without restarting

No extra configuration is needed beyond having `.env` set up with `INFORMER_URL` and credentials. If your handlers use `query()`, ensure `migrations/` exists so the workspace is auto-provisioned (see [Local Development with Workspaces](#local-development-with-workspaces)).

## App Context

When running inside Informer (not dev mode), the app receives context:

```javascript
const appId = window.__INFORMER__?.report?.id;
const appName = window.__INFORMER__?.report?.name;
const theme = window.__INFORMER__?.theme; // 'light' or 'dark'
const roles = window.__INFORMER__?.roles; // string[] of assigned role IDs
```

In dev mode, the Vite plugin mocks this with placeholder values (theme defaults to `'light'`, roles defaults to `[]`).

## App Roles

Apps can define custom roles that publishers assign when sharing. This enables role-based UIs — showing or hiding features based on the viewer's role.

### Defining Roles

Add a `roles:` section to your `informer.yaml` (see [App Configuration](#app-configuration-informeryaml)):

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
import informer from 'vite-plugin-informer';

export default {
    plugins: [informer({ mock: { roles: ['approver', 'manager'] } })]
};
```

## Built-in App Copilot

Every Informer App gets a **built-in AI copilot sidebar** — a chat panel that slides in from the right side of the app window. Users open it via a floating chat button and can ask questions about the data they're looking at, get insights, or drill into specifics.

### How the Copilot Works

- **Overlay mode** (default): The sidebar slides over the app content with a backdrop blur. Clicking outside the sidebar or pressing the X closes it.
- **Pinned mode**: Users can click the pin icon to dock the sidebar. The app content shrinks to make room, and the sidebar stays open while the user works.
- **Persistent chat**: Each app gets a persistent embedded chat session. Conversations are preserved across opens/closes — the user picks up where they left off.

The copilot has the Informer API skill **automatically enabled** — the AI gets `apiCall` and `searchRoutes` tools without any extra configuration.

### Opening the Copilot from App Code

Apps can programmatically open the copilot with context. This lets users click a data point, insight, or button and land in a chat pre-loaded with relevant data and instructions.

**Important:** Your `instructions` should spell out which APIs to call. The app knows what data it's working with — tell the AI the specific datasets, integrations, or query endpoints to use.

```javascript
__INFORMER__.openChat({
    prompt: 'Why did revenue spike in Q4?',
    context: { revenue: 1250000, quarter: 'Q4' },
    instructions: 'Use the Informer API to query the sales-data dataset (admin:sales-data) ' +
        'for year-over-year Q4 trends. Use the Salesforce integration to pull Opportunity ' +
        'records for pipeline context.'
});
```

| Option | Type | Description |
|--------|------|-------------|
| `prompt` | `string` | Initial user message sent to the AI. If omitted, chat opens empty with context loaded. |
| `context` | `object` | Data points injected into the AI's context — current state, filters, selected rows, etc. |
| `instructions` | `string` | **Tell the AI which APIs to call.** Name specific datasets, integrations, queries, and what to focus on. |
| `skills` | `string[]` | Additional resources to attach: `"dataset:owner:slug"`, `"library:id"` (optional). |

The AI automatically receives:
- **`apiCall`** — Make authenticated requests to any Informer API endpoint
- **`searchRoutes`** — Discover available API endpoints and their parameters

The app's identity (`id`, `name`, `url`) is automatically included as the chat's source — you don't need to pass it.

**Example — chart click handler:**
```javascript
chart.on('click', (point) => {
    __INFORMER__.openChat({
        prompt: `Tell me about ${point.label}`,
        context: {
            field: point.field,
            value: point.value,
            filters: currentFilters
        },
        instructions: `Use the Informer API to search the sales-data dataset. ` +
            `The user clicked on ${point.field}=${point.value}. ` +
            `Analyze trends and related records.`
    });
});
```

**Example — insight card:**
```javascript
document.querySelector('.insight').addEventListener('click', () => {
    __INFORMER__.openChat({
        prompt: 'What should we do about this?',
        context: {
            insight: 'AWS spend trending 18% over budget',
            currentSpend: 68400,
            budget: 58000
        },
        instructions: 'The user is viewing a cost optimization insight. ' +
            'Use the Informer API to query the cloud-costs dataset for detailed breakdown. ' +
            'Suggest concrete actions to reduce spend.'
    });
});
```

**Dev mode:** `__INFORMER__.openChat()` is not available in local Vite dev mode since there is no parent GO app. You can mock it for testing:

```javascript
if (!window.__INFORMER__?.openChat) {
    window.__INFORMER__ = window.__INFORMER__ || {};
    window.__INFORMER__.openChat = (opts) => console.log('openChat:', opts);
}
```

### Registering Tools (Report Bridge)

Apps can register tools that the copilot can call at runtime to get fresh data. This enables **bidirectional** communication — instead of sending a static snapshot via `openChat()`, the AI can ask the app for its current state on-demand.

The most common tool is `getContext`, which returns the app's current filters, selections, and visible data.

```javascript
__INFORMER__.registerTool({
    name: 'getContext',
    description: 'Returns the current app state including active filters, selected data, and summary metrics.',
    schema: {
        type: 'object',
        properties: {},
        additionalProperties: false
    },
    handler: () => {
        return {
            filters: getCurrentFilters(),
            selectedRows: getSelectedRows(),
            metrics: getSummaryMetrics(),
            view: getCurrentView()
        };
    }
});
```

| Option | Type | Description |
|--------|------|-------------|
| `name` | `string` | **Required.** Tool name — exposed to the AI as `report_<name>` (e.g., `report_getContext`). |
| `description` | `string` | What the tool does. The AI reads this to decide when to call it. |
| `schema` | `object` | JSON Schema for the tool's input parameters. Use `{}` properties for no-arg tools. |
| `handler` | `function` | **Required.** Called when the AI invokes the tool. Can return a value or a Promise. The return value is serialized to JSON and sent back to the AI. |

**How it works:**
1. App calls `registerTool()` during initialization (before user opens copilot)
2. The handler stays local in the app; only metadata (name, description, schema) is sent to GO
3. When the user opens the copilot, the AI sees `report_getContext` as an available tool
4. If the AI calls it, GO sends a message back to the app, the handler runs, and the result is returned to the AI

**Timing:** Tools must be registered before `openChat()` is called. Register them on page load or after your app initializes.

**Cleanup:** Tools are automatically unregistered when the app page unloads (via `beforeunload`).

**Example — dashboard with live filters:**
```javascript
// Register on page load
__INFORMER__.registerTool({
    name: 'getContext',
    description: 'Get the current dashboard state: active filters, date range, and visible KPIs.',
    schema: { type: 'object', properties: {} },
    handler: () => ({
        dateRange: { start: startDate, end: endDate },
        region: selectedRegion,
        department: selectedDepartment,
        kpis: {
            totalRevenue: revenueEl.textContent,
            openDeals: dealsEl.textContent,
            conversionRate: rateEl.textContent
        }
    })
});

// Later, user clicks "Ask AI"
askButton.addEventListener('click', () => {
    __INFORMER__.openChat({
        prompt: 'Why is the conversion rate dropping?',
        instructions: 'Use report_getContext to see the current dashboard state. ' +
            'Then query the sales-data dataset (admin:sales-data) for trends.'
    });
});
```

**Example — tool with parameters:**
```javascript
__INFORMER__.registerTool({
    name: 'getRowDetails',
    description: 'Get detailed data for a specific row by its ID.',
    schema: {
        type: 'object',
        properties: {
            rowId: { type: 'string', description: 'The row ID to look up' }
        },
        required: ['rowId']
    },
    handler: (args) => {
        const row = dataStore.getRow(args.rowId);
        return row || { error: 'Row not found' };
    }
});
```

**Dev mode:** `registerTool()` is not available in local Vite dev mode. Mock it for testing:

```javascript
if (!window.__INFORMER__?.registerTool) {
    window.__INFORMER__ = window.__INFORMER__ || {};
    window.__INFORMER__.registerTool = (def) => console.log('registerTool:', def.name);
}
```

### AI Completions from Apps

Apps can call Informer's AI directly for inline insights, structured data extraction, or interactive chat. Use the `go_everyday` model slug for all requests. Three endpoints are available:

| Endpoint | Response | Tools | Use Case |
|----------|----------|-------|----------|
| `_chat` | SSE stream | Yes | Interactive AI with tool calling |
| `_completion` | SSE stream | No | Simple text generation |
| `_object` | JSON | No | Structured data extraction |

**Data access:** Add the endpoints to your `data-access.yaml`:
```yaml
apis:
  - POST /api/models/go_everyday/_chat
  - POST /api/models/go_everyday/_completion
  - POST /api/models/go_everyday/_object
```

#### Streaming Chat (`_chat`)

The only endpoint that supports tools. Use this when the AI needs to call functions or when you want multi-turn conversations.

```javascript
const response = await fetch('/api/models/go_everyday/_chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        messages: [
            {
                role: 'user',
                parts: [{ type: 'text', text: 'Summarize the sales trend' }]
            }
        ],
        system: 'You are a data analyst. Be concise.',
        tools: {
            getData: {
                description: 'Fetch current sales data from the dashboard',
                inputSchema: {
                    type: 'object',
                    properties: {
                        metric: { type: 'string', description: 'Which metric to fetch' }
                    },
                    required: ['metric']
                }
            }
        }
    })
});
```

**Message format — AI SDK UIMessage (not OpenAI format):**

Messages must use the [AI SDK UIMessage format](https://ai-sdk.dev/docs/reference/ai-sdk-ui/use-chat#ui-messages) with a `parts` array. Do not use the OpenAI `{ role, content }` string format.

```javascript
// CORRECT — AI SDK UIMessage format (parts array)
messages: [
    {
        role: 'user',
        parts: [{ type: 'text', text: 'Your message here' }]
    }
]

// WRONG — OpenAI format (content string)
messages: [
    { role: 'user', content: 'Your message here' }
]

// WRONG — system message in array (use the top-level `system` field instead)
messages: [
    { role: 'system', content: '...' },
    { role: 'user', content: '...' }
]
```

Part types: `{ type: 'text', text: '...' }` for text content. Assistant messages from previous turns may also contain `tool-invocation` and `tool-result` parts — pass these through as-is for multi-turn tool calling.

**Inline tools format — this is NOT the OpenAI format:**

The `tools` property is a **plain object keyed by tool name**, not an array. Each value has `description` and `inputSchema` (or `parameters`). Do not use the OpenAI `tools: [{ type: "function", function: { ... } }]` array format — the server will reject it with a 400.

```javascript
// CORRECT — Informer format (object keyed by name)
tools: {
    searchSchema: {
        description: 'Search tables and fields by keyword',
        inputSchema: {
            type: 'object',
            properties: {
                query: { type: 'string', description: 'Keyword to search for' }
            },
            required: ['query']
        }
    },
    runQuery: {
        description: 'Execute a SQL query against the datasource',
        inputSchema: {
            type: 'object',
            properties: {
                sql: { type: 'string', description: 'The SQL query to run' }
            },
            required: ['sql']
        }
    }
}

// WRONG — OpenAI format (array with type/function wrappers)
tools: [
    { type: 'function', function: { name: 'searchSchema', parameters: { ... } } }
]
```

The server automatically adds an `aiProgressMessage` string parameter to every tool — the AI fills this in to show progress to the user while the tool runs.

**SSE response format (AI SDK UIMessage stream):**

The `_chat` and `_completion` endpoints return an SSE stream (`text/event-stream`). Each event is a `data:` line containing a JSON object with a `type` field. The stream ends with `data: [DONE]`.

Key event types:

| Type | Description | Key Fields |
|------|-------------|------------|
| `text-delta` | Text content chunk | `delta` (string to append) |
| `tool-input-start` | Tool call begins | `toolCallId`, `toolName` |
| `tool-input-delta` | Tool input JSON chunk | `toolCallId`, `inputTextDelta` |
| `tool-input-available` | Tool input complete | `toolCallId`, `toolName`, `input` (parsed args) |
| `tool-output-available` | Tool result | `toolCallId`, `output` |
| `tool-output-error` | Tool failed | `toolCallId`, `errorText` |
| `finish-step` | Step complete | `usage`, `finishReason` |
| `finish` | Stream complete | — |
| `error` | Error occurred | `errorText` |

For server-registered functions (via `functions`), the server executes tool calls automatically through `maxSteps` rounds. For inline tools (via `tools`), the server also executes them if their handler is registered server-side — otherwise the tool call appears in the stream.

**Reading the SSE stream:**

```javascript
async function streamChat(messages, options = {}) {
    const response = await fetch('/api/models/go_everyday/_chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ messages, ...options })
    });

    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let fullText = '';
    let buffer = '';

    while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        buffer += decoder.decode(value, { stream: true });
        const lines = buffer.split('\n');
        buffer = lines.pop(); // keep incomplete line in buffer

        for (const line of lines) {
            if (!line.startsWith('data: ')) continue;
            const payload = line.slice(6);
            if (payload === '[DONE]') break;

            try {
                const event = JSON.parse(payload);
                switch (event.type) {
                    case 'text-delta':
                        fullText += event.delta;
                        onTextUpdate?.(fullText);
                        break;
                    case 'tool-input-available':
                        onToolCall?.(event.toolName, event.input, event.toolCallId);
                        break;
                    case 'error':
                        onError?.(event.errorText);
                        break;
                }
            } catch {}
        }
    }

    return fullText;
}
```

**Complete example — SQL assistant with tool calling:**

```javascript
// Tool implementations (your app provides these)
const toolHandlers = {
    searchSchema: async ({ query }) => {
        const resp = await fetch(`/api/datasources/${dsId}/request`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                url: `/metadata/search?q=${encodeURIComponent(query)}`,
                method: 'GET'
            })
        });
        return resp.json();
    },
    runQuery: async ({ sql }) => {
        const resp = await fetch(`/api/datasources/${dsId}/_query`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ query: sql, limit: 100 })
        });
        return resp.json();
    }
};

// Send chat request with inline tools
const response = await fetch('/api/models/go_everyday/_chat', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        messages: [
            {
                role: 'user',
                parts: [{ type: 'text', text: 'Show me orders with customer and product info' }]
            }
        ],
        system: 'You are a SQL assistant. Use searchSchema to discover tables before writing queries.',
        tools: {
            searchSchema: {
                description: 'Search tables, fields, and relationships by keyword',
                inputSchema: {
                    type: 'object',
                    properties: {
                        query: { type: 'string', description: 'Keyword to search for' }
                    },
                    required: ['query']
                }
            },
            runQuery: {
                description: 'Execute a SQL query and return results',
                inputSchema: {
                    type: 'object',
                    properties: {
                        sql: { type: 'string', description: 'SQL query to execute' }
                    },
                    required: ['sql']
                }
            }
        }
    })
});
```

**Using the AI SDK `useChat` hook (React — recommended):**

The `_chat` endpoint streams the [AI SDK UI Message Stream Protocol](https://ai-sdk.dev/docs/ai-sdk-ui/stream-protocol). For React apps, the `useChat` hook from `@ai-sdk/react` handles SSE parsing, tool-call dispatch, and automatic resubmission — no manual stream reading needed.

```bash
npm install ai @ai-sdk/react
```

```tsx
import { useRef } from 'react';
import { useChat } from '@ai-sdk/react';
import { DefaultChatTransport, lastAssistantMessageIsCompleteWithToolCalls } from 'ai';

function NlQueryBar({ datasourceId }) {
    // Ref to break the circular dependency: onToolCall needs addToolOutput,
    // but addToolOutput comes from the useChat return value
    const addToolOutputRef = useRef(null);

    const { messages, sendMessage, addToolOutput, status } = useChat({
        // Point the transport at the Informer _chat endpoint
        transport: new DefaultChatTransport({
            api: '/api/models/go_everyday/_chat',
            // Pass tools and system prompt as extra body fields
            body: {
                system: 'You are a SQL assistant. Use searchSchema to find tables before writing queries.',
                tools: {
                    searchSchema: {
                        description: 'Search tables, fields, and relationships by keyword',
                        inputSchema: {
                            type: 'object',
                            properties: {
                                query: { type: 'string', description: 'Keyword to search for' }
                            },
                            required: ['query']
                        }
                    }
                }
            },
        }),

        // Auto-resubmit when all tool results are filled in — this creates the tool-call loop
        sendAutomaticallyWhen: lastAssistantMessageIsCompleteWithToolCalls,

        // Execute tool calls client-side and feed results back
        async onToolCall({ toolCall }) {
            const emit = addToolOutputRef.current;
            if (toolCall.toolName === 'searchSchema') {
                const res = await fetch(`/api/datasources/${datasourceId}/_search-metadata`, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify({ query: toolCall.input.query }),
                });
                const data = await res.json();
                // IMPORTANT: `tool` (the tool name) is required alongside toolCallId and output
                emit({ tool: 'searchSchema', toolCallId: toolCall.toolCallId, output: data });
            }
        },
    });

    // Sync the ref after hook returns — onToolCall reads from this ref
    addToolOutputRef.current = addToolOutput;

    const isLoading = status === 'submitted' || status === 'streaming';

    return (
        <input
            placeholder="Describe what you want to query..."
            disabled={isLoading}
            onKeyDown={(e) => {
                if (e.key === 'Enter') {
                    sendMessage({
                        parts: [{ type: 'text', text: e.target.value }],
                    });
                }
            }}
        />
    );
}
```

**Important patterns:**

- **`addToolOutputRef` pattern:** `onToolCall` is passed into `useChat` at hook init time, but it needs `addToolOutput` from the hook's return value. Use a ref that's synced after the hook call — the callback reads from the ref at execution time.
- **`tool` parameter is required:** `addToolOutput` requires `{ tool, toolCallId, output }` — passing just `{ toolCallId, output }` will cause a TypeScript error. The `tool` value must be the tool name string (e.g. `'searchSchema'`).

**How the loop works:**
1. `sendMessage()` sends the user message to `/api/models/go_everyday/_chat`
2. The server streams back SSE events — `useChat` parses them into `messages` automatically
3. When a `tool-input-available` event arrives, `onToolCall` fires with the parsed tool call
4. You execute the tool locally and call `addToolOutput()` with the result
5. `sendAutomaticallyWhen: lastAssistantMessageIsCompleteWithToolCalls` detects all tool calls have results and resubmits the conversation automatically
6. The server generates the next response (which may have more tool calls or final text)
7. The loop continues until the model produces a text-only response and `status` becomes `'ready'`

**Key `useChat` return values:**

| Value | Type | Description |
|-------|------|-------------|
| `messages` | `UIMessage[]` | Full conversation history with typed `parts` arrays |
| `sendMessage` | `function` | Send a new user message (with `parts` or `text`) |
| `addToolOutput` | `function` | Feed a tool result back: `{ tool, toolCallId, output }` — `tool` is the tool name string |
| `status` | `string` | `'ready'` \| `'submitted'` \| `'streaming'` \| `'error'` |
| `stop` | `function` | Abort the current stream |
| `error` | `Error` | Last error, if any |

**Full `_chat` payload options:**

| Field | Type | Description |
|-------|------|-------------|
| `messages` | `array` | **Required.** AI SDK UIMessage format — each message has `role` and `parts: [{ type: 'text', text }]`. |
| `system` | `string` | System prompt — sets the AI's behavior and context. Do NOT put system as a message; use this field. |
| `tools` | `object` | Inline tool definitions — **object keyed by name**, each with `description` and `inputSchema`. |
| `functions` | `string[]` | Built-in server function names to enable: `"evaluateMath"`, `"webSearch"`, etc. |
| `toolkitIds` | `string[]` | Server-side toolkit IDs to attach. |
| `maxSteps` | `number` | Max tool-calling round trips (default: 20). |
| `outputSize` | `string` | `"small"`, `"medium"` (default), or `"large"` — controls max output length. |

#### Simple Completion (`_completion`)

Fastest path for one-shot text generation. No tools, no multi-turn.

```javascript
const response = await fetch('/api/models/go_everyday/_completion', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        prompt: 'Write a one-sentence summary of this data: ' + JSON.stringify(chartData)
    })
});

// Same SSE stream format as _chat — parse text-delta events
const text = await streamChat([], { prompt: '...' });
```

| Field | Type | Description |
|-------|------|-------------|
| `prompt` | `string` | **Required.** The text prompt (converted to a user message internally). |
| `messages` | `array` | Optional prior messages for context (UIMessage format with `parts`). |

#### Structured Output (`_object`)

Returns a JSON object matching a schema. Not streaming — returns a single JSON response.

```javascript
const response = await fetch('/api/models/go_everyday/_object', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        messages: [
            {
                role: 'user',
                parts: [{
                    type: 'text',
                    text: `Analyze this data and extract insights:\n${JSON.stringify(salesData)}`
                }]
            }
        ],
        schema: {
            type: 'object',
            properties: {
                summary: { type: 'string', description: 'One paragraph overview' },
                trend: { type: 'string', enum: ['up', 'down', 'flat'] },
                topMetric: { type: 'string' },
                recommendations: {
                    type: 'array',
                    items: { type: 'string' }
                }
            },
            required: ['summary', 'trend', 'recommendations']
        }
    })
});

const insights = await response.json();
// { summary: "...", trend: "up", topMetric: "Revenue", recommendations: ["...", "..."] }
```

| Field | Type | Description |
|-------|------|-------------|
| `messages` | `array` | **Required.** Messages to analyze (UIMessage format with `parts`). |
| `schema` | `object` | **Required.** JSON Schema defining the output structure. |
| `outputSize` | `string` | `"small"`, `"medium"` (default), or `"large"`. |

**Dev mode:** All three endpoints work in local dev mode — the Vite proxy handles authentication automatically.

#### Defensive Parsing for `_object` Responses

The `_object` endpoint uses `go_everyday` (Haiku-class) which sometimes deviates from the provided JSON schema. Common failure modes:

- **Array fields returned as strings** — e.g. `risks: "some text"` instead of `risks: ["some text"]`
- **Array items scattered into top-level keys** — e.g. `item_1: "...", item_2: "..."` instead of a proper array
- **Enum values slightly off** — missing or novel labels
- **Numbers as strings** — e.g. `score: "75"` instead of `score: 75`

Always normalize `_object` responses before using them. Never call `.map()` or access array methods on a response field without checking its type first. Write a normalizer function that:

1. Validates each field's type and coerces when possible (`typeof x === 'string'` → wrap in array)
2. Collects scattered `item_N` keys back into arrays
3. Clamps numeric ranges
4. Falls back to sensible defaults for missing/malformed fields

**Reinforce the schema in the prompt text itself** — include a concrete JSON example showing the exact shape you expect. This gives the model two signals (prompt + schema) and significantly reduces drift:

```javascript
const resp = await fetch('/api/models/go_everyday/_object', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        messages: [{
            role: 'user',
            parts: [{
                type: 'text',
                // Include explicit JSON shape example at the end of the prompt
                text: `Analyze this data...\n\nRespond with JSON only: { "summary": "<text>", "items": ["<item1>", "<item2>"] }`
            }]
        }],
        schema: { /* formal schema here */ }
    })
});

const raw = await resp.json();
// NEVER use raw directly — always normalize first
const result = normalize(raw);
```

### Responding to Theme

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
import informer from 'vite-plugin-informer';

export default {
    plugins: [informer({ mock: { theme: 'dark' } })]
};
```

## PDF Export

Apps can be exported to PDF via `POST /api/apps/{id}/_print`.

### How it works

1. Informer opens your app in a headless browser (Puppeteer)
2. Waits for network requests to complete
3. Waits for `window.informerReady` to become `true`
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

- `references/api-reference.md` - Detailed API documentation
- `references/app-templates.md` - HTML/CSS/JS starter templates

## Terminology Note

Informer Apps were previously called "Magic Reports". The underlying technology is the same — the rename reflects their broader role as full applications with built-in AI copilots, not just static reports. The deploy tool automatically detects which API your server supports (`/api/apps` or the legacy `/api/reports`) and uses the correct one.
