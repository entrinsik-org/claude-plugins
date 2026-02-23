---
name: magic-reports
description: Building Magic Reports with local Vite development. Covers the dev/publish workflow and key Informer APIs for datasets, queries, and integrations.
---

# Magic Report Development

## What is a Magic Report?

A Magic Report is a custom HTML/JS/CSS application that runs inside Informer. It can:
- Query Informer datasets (Elasticsearch-indexed data)
- Execute saved queries
- Make authenticated requests to external APIs via integrations (Salesforce, etc.)
- Render charts, tables, and interactive visualizations

Reports are stored in Informer libraries and served through the Informer UI.

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

Builds your project and uploads to an Informer library:
1. Creates/finds a Magic Report by slug (from package.json `name`)
2. Snapshots the library for rollback
3. Clears existing files
4. Uploads all built assets from `dist/`
5. Uploads `data-access.yaml` from project root (if it exists)
6. Report is viewable at `/reports/r/{owner}:{slug}`

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
| `description` | Report description |
| `id` | Report UUID (auto-saved after first deploy) |

### Report Icon (favicon.svg)

Place a `favicon.svg` in your `public/` directory. It will be deployed to the report's library root and used as:
- **App gallery icon** — shown as the report's tile in the desktop and mobile app galleries
- **Browser tab favicon** — shown when the report is viewed in a browser tab

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
- Design should visually represent the report's content (bars for dashboards, document for invoices, etc.)

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

The response is a true HTTP proxy — the upstream status code, headers, and body are returned directly.

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
const result = await response.json();  // body is the upstream response directly
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
const records = result.records;
```

## Data Access Configuration

When your report is published and shared, you must declare which APIs it needs access to. Create a `data-access.yaml` file in your project root (it will be published with your report).

**Important:** Without this file, all API access is blocked when the report runs in Informer.

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
| `$report.id` | Report UUID |

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

## Report Context

When running inside Informer (not dev mode), the report receives context:

```javascript
const reportId = window.__INFORMER__?.report?.id;
const reportName = window.__INFORMER__?.report?.name;
const theme = window.__INFORMER__?.theme; // 'light' or 'dark'
```

In dev mode, the Vite plugin mocks this with placeholder values (theme defaults to `'light'`).

### Opening a Chat from a Report

Reports can trigger an AI chat in Informer GO with context from the report. This lets users click a data point, insight, or button and land in a chat pre-loaded with relevant context and the right tools.

Since the chat originates from a report, the Informer API skill is **automatically enabled** — the AI gets `apiCall` and `searchRoutes` tools without any extra configuration.

**Important:** Your `instructions` should spell out which APIs to call. The report knows what data it's working with — tell the AI the specific datasets, integrations, or query endpoints to use. Without this guidance, the AI has access to the full API but no direction.

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

The AI can query datasets, execute saved queries, and call integrations — but it needs your `instructions` to know _which ones_ and _why_.

The report's identity (`id`, `name`, `url`) is automatically included as the chat's source — you don't need to pass it.

**How it works across platforms:**
- **Capacitor** (mobile/tablet): `postMessage` to parent app. Gallery and report dismiss, new chat opens.
- **Electron** (desktop): IPC bridge between the report's BrowserWindow and the main app window.

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

Reports can register tools that the AI can call at runtime to get fresh data from the report. This enables **bidirectional** communication — instead of sending a static snapshot via `openChat()`, the AI can ask the report for its current state on-demand.

The most common tool is `getContext`, which returns the report's current filters, selections, and visible data.

```javascript
__INFORMER__.registerTool({
    name: 'getContext',
    description: 'Returns the current report state including active filters, selected data, and summary metrics.',
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
1. Report calls `registerTool()` during initialization (before user clicks "Ask AI")
2. The handler stays local in the report; only metadata (name, description, schema) is sent to GO
3. When the user opens a chat from the report, the AI sees `report_getContext` as an available tool
4. If the AI calls it, GO sends a message back to the report, the handler runs, and the result is returned to the AI

**Timing:** Tools must be registered before `openChat()` is called. Register them on page load or after your app initializes. The tool appears in the AI's available tools on the next chat message.

**Cleanup:** Tools are automatically unregistered when the report page unloads (via `beforeunload`).

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

### AI Completions from Reports

Reports can call Informer's AI directly for inline insights, structured data extraction, or interactive chat. Use the `go_everyday` model slug for all requests. Three endpoints are available:

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

    while (true) {
        const { done, value } = await reader.read();
        if (done) break;

        const chunk = decoder.decode(value, { stream: true });
        // Each SSE chunk is a line like: 0:"text piece"\n
        // For simple text extraction, accumulate the raw text
        for (const line of chunk.split('\n')) {
            if (line.startsWith('0:')) {
                try {
                    const text = JSON.parse(line.slice(2));
                    if (typeof text === 'string') {
                        fullText += text;
                        onTextUpdate?.(fullText); // callback for live rendering
                    }
                } catch {}
            }
        }
    }

    return fullText;
}
```

**Full `_chat` payload options:**

| Field | Type | Description |
|-------|------|-------------|
| `messages` | `array` | **Required.** Conversation history. Each message has `role` and `parts`. |
| `system` | `string` | System prompt — sets the AI's behavior and context. |
| `tools` | `object` | Tool definitions (name → `{ description, inputSchema }`). Only works with `_chat`. |
| `functions` | `string[]` | Built-in server functions: `"evaluateMath"`, `"webSearch"`, etc. |
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

// Same SSE stream format as _chat
const text = await readStream(response);
```

| Field | Type | Description |
|-------|------|-------------|
| `prompt` | `string` | **Required.** The text prompt. |
| `messages` | `array` | Optional prior messages for context. |

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
| `messages` | `array` | **Required.** Messages to analyze. |
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

Use the theme value to adapt your report's appearance:

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

Reports can be exported to PDF via `POST /api/reports/{id}/_print`.

### How it works

1. Informer opens your report in a headless browser (Puppeteer)
2. Waits for network requests to complete
3. Waits for `window.informerReady` to become `true`
4. Adds `.print` class to `<html>`
5. Captures the page as PDF using print media

### Signal when ready

Set `window.informerReady` to signal when your report is fully rendered:

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
await fetch(`/api/reports/${reportId}/_print`, {
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
- `references/report-templates.md` - HTML/CSS/JS starter templates
