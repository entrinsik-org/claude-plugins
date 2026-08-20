# Persistence (App Workspace)

> **Load this reference when:** the app needs to store its own data (form submissions, workflow state, anything that isn't backed by a dataset/datasource/integration). Covers the `migrations/` directory, the dev-workspace lifecycle (`workspace:init` / `:migrate` / `:reset`), and how published apps read/write workspace data through server routes.
>
> **Not in this file:** raw `query()` calling shape and parameter binding — see `server-routes.md`. Datasource/dataset queries (those are deps, not workspace) — see SKILL.md "Accessing Your Dependencies".

Apps can opt into a **dedicated Postgres schema** for storing and querying custom data. This is ideal for apps that need CRUD operations, form submissions, workflow state, or any data that belongs to the app itself rather than coming from external datasources or datasets.

## How It Works

When your project has a `migrations/` directory containing `.sql` files, Informer provisions a dedicated Postgres schema for the app. The schema is:
- **Tenant-isolated** — owned by the tenant role, inaccessible to other tenants
- **Lazily provisioned** — created on first query or explicit migration
- **Automatically cleaned up** — dropped when the app is deleted

## Migration Files

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

## Querying the Workspace

All database access goes through server-side route handlers (see `server-routes.md`). The `query()` callback in server handlers executes SQL against the app's workspace.

For several writes that must all succeed or all roll back, wrap them in the handler's `transaction(fn)` helper (commit-all-or-rollback) — see `server-routes.md`.

End-user code in a published app does not query the workspace directly — call your own server routes via `fetch('/api/...')` and let the server handler use `query()`. A privileged `POST /api/apps/{id}/workspace/_query` endpoint exists for publishers and IDE tooling (it requires the `app:write` permission), but it's not a runtime surface for end-users.

## Local Development with Workspaces

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

## Full Example: CRUD App

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
    const response = await fetch('/api/orders');
    const orders = await response.json();
    renderOrderTable(orders);
}

// Create order
async function createOrder(customer, total) {
    const response = await fetch('/api/orders', {
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
    await fetch(`/api/orders/${id}`, { method: 'DELETE' });
    loadOrders(); // refresh
}

loadOrders();
```
