---
name: magic-apps
description: Building Informer Apps with local Vite development. Covers the dev/publish workflow, key Informer APIs, and the built-in AI copilot sidebar.
---

# Informer App Development

## What is an Informer App?

An Informer App is a custom HTML/JS/CSS application that runs inside Informer. It can:
- Query Informer datasets (Elasticsearch-indexed data)
- Execute saved queries
- Make authenticated requests to external APIs via integrations (Salesforce, etc.)
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

### Deploying (`npm run deploy`)

Builds your project and uploads to Informer:
1. Creates/finds an App via the `/api/apps` endpoint (falls back to legacy `/api/reports` on older servers)
2. Snapshots the library for rollback
3. Clears existing files
4. Uploads all built assets from `dist/`
5. Uploads `data-access.yaml` from project root (if it exists)
6. App is viewable at `/api/apps/{owner}:{slug}/view`

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

## Data Access Configuration

When your app is published and shared, you must declare which APIs it needs access to. Create a `data-access.yaml` file in your project root (it will be published with your app).

**Important:** Without this file, all API access is blocked when the app runs in Informer.

### Basic Example

```yaml
# data-access.yaml

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
apis:
  - POST /api/custom/endpoint
```

## App Context

When running inside Informer (not dev mode), the app receives context:

```javascript
const appId = window.__INFORMER__?.report?.id;
const appName = window.__INFORMER__?.report?.name;
const theme = window.__INFORMER__?.theme; // 'light' or 'dark'
```

In dev mode, the Vite plugin mocks this with placeholder values (theme defaults to `'light'`).

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
