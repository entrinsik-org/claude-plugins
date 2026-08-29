# Agents (Event-Driven AI Automation)

> **Load this reference when:** declaring agents in `informer.yaml`, writing tool files under `tools/`, emitting events from server routes or other agent tools (agent chaining), scheduling agents via cron, or working with the agent REST API.
>
> **Not in this file:** the in-app sidebar copilot — see `copilot.md`. Server route handlers (which often emit events) — see `server-routes.md`. The sandbox helpers (`query`, `fetch`, `emit`, `notify`, `email`, `log`) are documented in detail in `server-routes.md`; agent tools use the same sandbox. Live frames to open pages (`broadcast()`, and relaying `emit()`-ed events to a channel via the `channels:` block) — see `channels.md`.

Apps can define **agents** — AI-powered workflows that listen for events, execute tools, and chain together to automate complex tasks. Agents are declared in `informer.yaml`, run server-side in isolated V8 sandboxes, and have access to the app's workspace database, API whitelist, and custom tools.

## Defining Agents in `informer.yaml`

Add an `agents:` section to your `informer.yaml`:

```yaml
# informer.yaml
dependencies:
  sales:
    target: dataset
    defaultBinding: 7d5a9b1e-0c83-4bde-9e2a-3a4b5c6d7e8f

agents:
  order-processor:
    description: "Processes new orders and updates inventory"
    instructions: |
      You are an order processing agent. When triggered by a new order event,
      validate the order, check inventory levels, and update the database.
      Use the check_inventory tool to verify stock before confirming.
    model: go_everyday
    tools:
      - check_inventory
      - update_status
    on:
      - order_created

  daily-report:
    description: "Generates a daily summary report"
    instructions: |
      Generate a summary of today's activity. Query the orders table
      for today's records and calculate totals. Post results to Slack.
    model: go_everyday
    webSearch: true
    tools:
      - send_notification
    toolkits:
      - admin:slack-notifications
    assistants:
      - admin:report-writer
    cron: "0 8 * * 1-5"   # Weekdays at 8:00 AM

events:
  order_created:
    description: "Fired when a new order is submitted"
```

| Field | Type | Description |
|-------|------|-------------|
| `description` | `string` | Display name/description shown in the Agents UI |
| `instructions` | `string` | System prompt for the AI model — tells the agent what to do |
| `model` | `string` | AI model slug (default: `go_everyday`) |
| `tools` | `string[]` | Tool names from the app's `tools/` directory |
| `toolkits` | `string[]` | Informer toolkit IDs (naturalId or UUID) to attach — their tools become available to the agent |
| `assistants` | `string[]` | Informer assistant IDs (naturalId or UUID) — their instructions are merged into the agent's system prompt |
| `on` | `string \| string[]` | Event name(s) that trigger this agent |
| `cron` | `string` | 5-field cron expression for scheduled execution (e.g. `"0 8 * * 1-5"` = weekdays at 8 AM) |
| `webSearch` | `boolean` | Enable web search (default: `false`). When enabled, the AI model can search the web for current information during execution. |
| `onFailure` | `string` | Event to emit when a run of this agent **terminally fails** — declares an error branch so the workflow advances instead of stalling. See [Handling Failures](#handling-failures). |

The optional `events:` section documents available events (for reference only — events don't need to be declared to work).

## Tools

Agents use tools defined in your app's `tools/` directory. Each tool is a `.js` file that exports a `description`, `schema`, and `handler`:

```
my-app/
  tools/
    check_inventory.js
    update_status.js
    notifications/
      send_notification.js    → tool name: "notifications_send_notification"
  server/
    orders/index.js
  migrations/
    001-create-orders.sql
  informer.yaml
```

**Tool file structure:**

```javascript
// tools/check_inventory.js

export const description = 'Check inventory levels for a product';

export const schema = {
    type: 'object',
    properties: {
        productId: { type: 'string', description: 'The product ID to check' },
        quantity: { type: 'number', description: 'Required quantity' }
    },
    required: ['productId', 'quantity']
};

export async function handler({ args, query, fetch, emit, notify, email, crypto, log, context, run }) {
    const [product] = await query(
        'SELECT * FROM inventory WHERE product_id = $1',
        [args.productId]
    );

    if (!product) {
        return { available: false, error: 'Product not found' };
    }

    return {
        available: product.stock >= args.quantity,
        currentStock: product.stock,
        requested: args.quantity
    };
}
```

**Handler bag** — a single object, the same service surface as server routes/webhooks:

| Property | Type | Description |
|----------|------|-------------|
| `args` | `object` | The AI-supplied tool input (validated against `schema`) |
| `run` | `object` | Agent-run metadata: `{ appId, agentId, runId, trigger }`. `run.trigger` is the **full triggering event** — read `run.trigger.event` (the name) and `run.trigger.payload` (the data), not `run.trigger` alone |
| `context` | `object` | Typed bound dependencies — `context.<slot>.<method>(...)` (see `informer-yaml.md`) |
| `query` | `async (sql, params?) => rows` | Execute SQL against the app's workspace |
| `fetch` | `async (path, options?) => { status, body }` | Make authenticated API calls (subject to whitelist) |
| `emit` | `async (event, payload) => void` | Emit an event to trigger other agents |
| `broadcast` | `async (channel, event, payload?) => { ok: true }` | Push a fire-and-forget, at-most-once frame to every open page subscribed to `channel` — e.g. tell the dashboard an agent finished triaging (origin-mode servers only). See `channels.md`. |
| `notify` | `async (username, message) => { id }` | Enqueue a push notification (single or bulk) |
| `email` | `async (to, message) => { id }` | Enqueue an email (single or bulk) |
| `crypto` | `object` | `hmac`, `hash`, `randomUUID`, `randomBytes`, `timingSafeEqual`, `verifyHmac`, `encrypt`/`decrypt`, `verify` — all async. See `server-routes.md`. |
| `markdown` | `async (text) => string` | Convert markdown text to HTML |
| `extractText` | `async (data, contentType) => string` | Extract plain text from a base64 file (PDF, Excel, Word, text). See `server-routes.md`. |
| `log` | `function` | Structured logging. `log(message, data?)` or `log.info()`/`log.warn()`/`log.error()`/`log.debug()`. See `server-routes.md`. |
| `env` | `object` | App environment variables |

> **Migration note:** earlier tools used `handler(args, ctx)` and read run metadata from `ctx.context`. Tools now take a **single bag**: AI input is `args`, run metadata is `run`, and `context` is the typed dependency proxy. Tools also gained `crypto`, `env`, `notify`, and `email`.

**Tool naming:** The tool name is derived from the file path relative to `tools/`. Nested directories use underscores: `tools/notifications/send_email.js` → `notifications_send_email`.

> The full sandbox-helper reference (calling shapes, edge cases, return values) lives in `server-routes.md` — agent tools share the same V8 sandbox as server route handlers, so anything documented there applies here too.

### Returning a document or image

A tool's return value is serialized to the model as JSON (or as text for a string). To instead hand the model a file as a **native document or image part**, so it reads the actual PDF or image rather than extracted text, return a `$file` (or `$files`) marker:

```javascript
// tools/read-document.js
export async function handler({ args, query }) {
    const [doc] = await query(
        'SELECT filename, content_type, data FROM documents WHERE id = $1',
        [args.id]
    );
    if (!doc) return { error: `Document ${args.id} not found` };

    // `data` is base64-encoded bytes. For a text-heavy file, return
    // extractText(doc.data, doc.content_type) instead (cheaper, no vision tokens).
    return {
        $file: { mediaType: doc.content_type, data: doc.data, filename: doc.filename },
        text: `Loaded ${doc.filename}.`
    };
}
```

| Field | Type | Description |
|-------|------|-------------|
| `$file` | `object` | A single file: `{ mediaType, data, filename? }`, where `data` is base64 |
| `$files` | `array` | Several files, each `{ mediaType, data }` |
| `text` | `string` | Optional caption emitted before the file part(s) |

`mediaType` must be `application/pdf` or an `image/*` type; provider support follows the underlying model. Reach for this when the document's layout, tables, or visuals matter, or for a scanned PDF with no text layer.

## Toolkits

In addition to custom tools defined in the `tools/` directory, agents can use **Informer toolkits** — shared tool collections managed at the system level (MCP servers, custom toolkits, etc.). Declare them in the agent's `toolkits` array using the toolkit's naturalId or UUID:

```yaml
# informer.yaml
agents:
  research-agent:
    description: "Researches topics using external tools"
    instructions: |
      Use the available tools to research the requested topic.
      Summarize findings and store results in the workspace.
    tools:
      - save_results
    toolkits:
      - admin:web-scraper
      - admin:slack-notifications
    on: research_requested
```

**How toolkit integration works:**

1. **At deploy time**, each toolkit ref is validated — deploy **fails hard** if a referenced toolkit doesn't exist. Resolved refs are stored in the `app_toolkit` junction table.
2. **At agent execution time**, the agent executor loads all toolkits declared on the agent, fetches their namespaced tool definitions, and merges them into the agent's available tools alongside any custom `tools/` directory tools.
3. Toolkit **system instructions** (if configured) are appended to the agent's system prompt automatically.
4. Tool names from toolkits are namespaced to avoid collisions (e.g., `web-scraper:fetch_page`).

**Toolkits vs. custom tools:**

| Feature | Custom tools (`tools/`) | Toolkits |
|---------|------------------------|----------|
| Defined in | App's `tools/` directory | System-level toolkit config |
| Scope | Single app | Shared across apps/chats |
| Execution | V8 sandbox (app context) | Toolkit driver (MCP, custom, etc.) |
| Deploy validation | Warns on missing refs | Fails on missing refs |
| Use case | App-specific logic | Shared capabilities (APIs, MCP servers) |

## Assistants

Agents can reference Informer assistants to inherit their instructions. Each referenced assistant's system prompt is merged into the agent's own instructions, allowing you to compose agent behavior from reusable assistant personas.

```yaml
agents:
  support-agent:
    description: "Customer support with a specialized persona"
    instructions: |
      Process support tickets and escalate critical issues.
    assistants:
      - admin:support-persona
    on: support_request
```

**How assistant integration works:**

1. **At deploy time**, each assistant ref is validated — deploy **fails hard** if a referenced assistant doesn't exist. Use either naturalId (`owner:slug`) or UUID.
2. **At agent execution time**, the executor loads each assistant and collects its `instructions` field.
3. Assistant instructions are prepended to the system prompt **before** toolkit instructions.

## Events

Events are the trigger mechanism for agents. They can be emitted from:

1. **Server-side route handlers** — using the `emit()` callback
2. **Other agent tools** — using `emit()` in a tool handler (enables agent chaining)
3. **Manual triggers** — via the Agents UI or API (uses `_manual` event name)

**Emitting events from server routes:**

```javascript
// server/orders/index.js

export async function POST({ query, emit, request }) {
    const { customer, total } = request.body;
    const [order] = await query(
        'INSERT INTO orders (customer, total) VALUES ($1, $2) RETURNING *',
        [customer, total]
    );

    // Trigger agents listening for 'order_created'
    await emit('order_created', { orderId: order.id, customer, total });

    return { status: 201, body: order };
}
```

**Emitting events from tools (agent chaining):**

```javascript
// tools/update_status.js

export const description = 'Update order status and notify downstream';

export const schema = {
    type: 'object',
    properties: {
        orderId: { type: 'string' },
        status: { type: 'string', enum: ['confirmed', 'shipped', 'delivered'] }
    },
    required: ['orderId', 'status']
};

export async function handler({ args, query, emit }) {
    await query(
        'UPDATE orders SET status = $1 WHERE id = $2',
        [args.status, args.orderId]
    );

    // Chain: trigger another agent
    await emit('order_status_changed', {
        orderId: args.orderId,
        newStatus: args.status
    });

    return { updated: true };
}
```

## Handling Failures

A successful run advances the workflow by `emit()`-ing the next event from a tool. If a run **terminally fails**, nothing is emitted and the workflow stops — the failure is visible in the app's logs, but there's no forward transition.

Declare `onFailure` to give an agent an explicit error branch: when a run of that agent terminally fails, the platform emits the named event so another agent can react — compensate, notify, mark the work item failed, and so on.

```yaml
agents:
  research-topic:
    instructions: Research the requested topic and save findings.
    tools: [web_search, save_findings]
    on: research_requested
    onFailure: research_failed      # emitted if a run terminally fails

  handle-research-failure:
    instructions: Mark the workflow item failed and notify the owner.
    tools: [mark_failed, notify_owner]
    on: research_failed             # your error branch
```

The `onFailure` event fires with a standard envelope describing the failure:

```json
{
  "error": "<failure message>",
  "runId": "<failed run id>",
  "agent": "research-topic",
  "event": "research_requested",
  "payload": { "...": "the payload that triggered the failed run" }
}
```

**Semantics:**

- **Fires once** — emitted when a run terminally fails; never re-emitted if the source event is later retried.
- **Branches instead of retrying** — declaring `onFailure` hands a failed run to your error branch and marks the source event handled, instead of the default blind retry. An event whose matching agents declare *no* `onFailure` keeps the default behavior: retry up to 5 times, then dead-letter.
- **Shared events** — when several agents trigger on the same event, each agent's failure is independent: any failed agent that declares `onFailure` emits its failure event. The event only falls back to retry/dead-letter when *every* matching agent fails *and none* declares `onFailure`.
- **Loop guard** — failure events carry a reserved `_failureDepth` counter (the platform adds it to the payload — don't set or rename it). If an error handler itself fails and also declares `onFailure`, the chain is capped after 3 hops so a broken handler can't spawn a runaway failure-event chain.

## Cron Scheduling

Agents can run on a schedule using standard 5-field cron expressions (`minute hour dom month dow`). When an agent has a `cron` field, the event dispatcher automatically triggers it at the scheduled time using the `_cron` event.

```yaml
agents:
  daily-digest:
    description: "Send daily activity digest"
    instructions: |
      Query today's activity and send a summary notification.
    tools:
      - send_notification
    cron: "0 8 * * 1-5"   # Weekdays at 8:00 AM

  hourly-sync:
    description: "Sync external data every hour"
    instructions: |
      Fetch latest records from the external API and upsert into the workspace.
    tools:
      - fetch_external_data
      - upsert_records
    cron: "0 * * * *"     # Every hour on the hour
```

**Common cron patterns:**

| Expression | Schedule |
|-----------|----------|
| `0 8 * * *` | Daily at 8:00 AM |
| `0 8 * * 1-5` | Weekdays at 8:00 AM |
| `*/15 * * * *` | Every 15 minutes |
| `0 0 * * 0` | Sundays at midnight |
| `0 9 1 * *` | First of every month at 9:00 AM |

**How it works:**
- At deploy time, the cron expression is validated and **desugared into an `app_automation` row** (named `<agentName>:cron`) with `nextRunAt` computed.
- The dispatcher's `sweepAutomations()` loop queries `app_automation` for rows whose `nextRunAt` has passed (using `FOR UPDATE SKIP LOCKED` for cluster safety).
- When fired, `server.inject`s a POST to the agent's `/_trigger` endpoint directly — **bypassing the `AppEvent` queue** that event-driven triggers go through. The agent receives `{ cron }` as the payload.
- After execution, the automation row's `nextRunAt` is recomputed.
- Only **active** agents with a valid cron expression keep their automation row scheduled.

**Cron + event triggers can coexist** — an agent can have both `cron` and `on` fields. It runs on schedule (via the automation sweeper) AND when matching events fire (via the event dispatcher). The two paths are separate.

Setting an agent's status to `stopped` via the API also stops its desugared cron automation (clears the automation row's `nextRunAt`). Reactivating recomputes the automation's next fire time.

## How Agent Execution Works

Two trigger paths, one execution path:

**Event-driven path** (`emit()` from a handler or `POST /_trigger` with `{ event, payload }`):
1. An `AppEvent` record is created with `status: 'pending'`
2. The event dispatcher (real-time via Redis + periodic sweep fallback) picks it up
3. All **active** agents whose `on` triggers include the event name are found

**Cron path** (`cron: "..."` in `informer.yaml`):
1. `sweepAutomations()` finds rows in `app_automation` where `nextRunAt <= NOW()`
2. For each row, `server.inject` POSTs directly to `/_trigger` with `{ event: '_cron', payload: { cron } }`
3. The `AppEvent` queue is bypassed entirely

**Then the execution loop runs (both paths converge here):**

For each matching agent:
- Creates an `AppAgentRun` record
- Loads the AI model and tool bundles from `tools/`
- Loads assistant instructions declared in the agent's `assistants` array and merges them into the system prompt
- Loads toolkit tools declared in the agent's `toolkits` array (namespaced tool defs + system instructions)
- Calls the AI with the system prompt (from `instructions` + assistant instructions + toolkit instructions), the event payload, and all available tools
- The AI can call tools (up to 20 steps) — custom tools run in isolated V8 sandboxes, toolkit tools delegate to their driver
- Run is marked `completed` or `failed` with execution steps and token usage

**Sandbox constraints** (same as server routes — see `server-routes.md`):
- No Node.js APIs (`require`, `fs`, `http`, etc.)
- No direct network access — use `fetch()` (enforces whitelist)
- 128 MB memory limit per isolate
- 30-second timeout per tool execution

## Agent Status

Agents have a `status` field: `active` or `stopped`. Only active agents respond to events. You can toggle status via:

- **The Agents UI** — click the play/stop button next to an agent
- **The API** — `PUT /api/apps/{id}/agents/{agentId}` with `{ "status": "active" }`

When you redeploy, agents defined in `informer.yaml` are upserted. Agents removed from YAML are set to `stopped`. Runtime instruction overrides (`instructionsOverride`) are preserved across deploys.

## Agent REST API

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/apps/{id}/agents` | List all agents |
| GET | `/api/apps/{id}/agents/{agentId}` | Get agent details |
| PUT | `/api/apps/{id}/agents/{agentId}` | Update agent (instructions, status, model) |
| GET | `/api/apps/{id}/agents/{agentId}/runs` | List runs (paginated, newest first) |
| GET | `/api/apps/{id}/agents/{agentId}/runs/{runId}` | Get run details with step-by-step log |
| POST | `/api/apps/{id}/agents/{agentId}/_trigger` | Manually trigger (payload: `{ event, payload }`) |

## Local Development

Agents run locally during `npm run dev` via the Vite plugin. The plugin:

1. Detects a `tools/` directory or `agents:` section in `informer.yaml`
2. Mounts middleware at `/api/_agent` that loads agent definitions and tool handlers
3. Loads tool handlers via `ssrLoadModule` (same as server routes) — HMR works for tool code
4. Proxies AI calls to the Informer server's `_chat` endpoint

**Local agent endpoints:**

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/_agent` | List agents from `informer.yaml` |
| POST | `/api/_agent/{name}/_trigger` | Run agent locally with tool dispatch |

**Triggering locally:**

```javascript
// From your app's frontend code during dev
const response = await fetch('/api/_agent/validate-order/_trigger', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        event: 'order_created',
        payload: { orderId: 123, customer: 'Acme Corp', total: 1500 }
    })
});

const result = await response.json();
// { agent: 'validate-order', trigger: 'order_created', status: 'completed', tokens: 450, steps: [...] }
```

**Differences from production:**
- `emit()` is a no-op in dev mode (logs to console instead of creating events)
- AI calls proxy through the Informer server — the model must be configured there
- No agent run records are persisted locally
- Tool code reloads on save (HMR)

## Project Structure with Agents

```
my-app/
  tools/
    check_inventory.js        ← Agent tool
    update_status.js          ← Agent tool
    notifications/
      send_email.js           ← Nested tool (name: notifications_send_email)
  server/
    orders/
      index.js                ← Emits events via emit()
  migrations/
    001-create-orders.sql
    002-create-inventory.sql
  public/
    favicon.svg
  src/
    main.js
  informer.yaml               ← Declares agents, tools, events, dependencies
  index.html
  package.json
```

## Full Example: Order Processing Pipeline

```yaml
# informer.yaml
dependencies:
  products:
    target: dataset
    defaultBinding: 3e4f5a6b-7c8d-9e0f-1234-567890abcdef

agents:
  validate-order:
    description: "Validates new orders and checks inventory"
    instructions: |
      When an order_created event arrives, use check_inventory for each item.
      If all items are in stock, use update_status to set the order to 'confirmed'.
      If any item is out of stock, set it to 'backordered'.
    tools:
      - check_inventory
      - update_status
    on: order_created

  send-confirmation:
    description: "Sends order confirmation emails"
    instructions: |
      When an order is confirmed (order_status_changed with newStatus='confirmed'),
      use the Slack toolkit to notify the sales channel, then use send_email for the customer.
    tools:
      - notifications_send_email
    toolkits:
      - admin:slack-notifications
    on: order_status_changed

  daily-order-summary:
    description: "Generates a daily order summary"
    instructions: |
      Query yesterday's orders, calculate totals and trends,
      and send a summary notification to the ops team.
    tools:
      - send_notification
    cron: "0 7 * * 1-5"   # Weekdays at 7:00 AM
```

This creates an automated pipeline: order submitted → validated → status updated → confirmation sent — with each step handled by a different agent. The daily summary runs on a cron schedule independently.
