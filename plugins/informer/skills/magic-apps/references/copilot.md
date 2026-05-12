# Built-in App Copilot

> **Load this reference when:** working on the in-app AI sidebar — activating it, opening it from app code with `openChat()`, registering tools (the "report bridge"), or calling the AI completion endpoints (`_chat`, `_completion`, `_object`) directly from app code.
>
> **Not in this file:** event-driven AI agents — see `agents.md`. Server-side handler dispatch — see `server-routes.md`.

Every Informer App gets a **built-in AI copilot sidebar** — a chat panel that slides in from the right side of the app window.

## How the Copilot Works

- **Hidden by default**: The copilot button is suppressed for apps. The app must explicitly activate it (see below).
- **Overlay mode** (default): The sidebar slides over the app content with a backdrop blur. Clicking outside the sidebar or pressing the X closes it.
- **Pinned mode**: Users can click the pin icon to dock the sidebar. The app content shrinks to make room, and the sidebar stays open while the user works.
- **Persistent chat**: Each app gets a persistent embedded chat session. Conversations are preserved across opens/closes — the user picks up where they left off.

The copilot has the Informer API skill **automatically enabled** — the AI gets `apiCall` and `searchRoutes` tools without any extra configuration.

## Activating the Copilot

The copilot button is hidden by default for apps. It activates automatically when tools are registered via `registerTool()`. You can also activate it explicitly or paint your own button:

**Automatic** — registering any tool activates the copilot button:
```javascript
__INFORMER__.registerTool({ name: 'getContext', ... }); // button appears
```

**Explicit** — show the platform button without registering tools:
```javascript
window.__INFORMER__?.showCopilot();
```

**Custom** — paint your own button and call `openChat()` directly. This gives you full control over where and when the copilot entry point appears:
```javascript
document.querySelector('#my-ai-btn').addEventListener('click', () => {
    __INFORMER__.openChat({ prompt: 'Analyze current dashboard data' });
});
```

## Opening the Copilot from App Code

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

**Dev mode:** `__INFORMER__.openChat()` and `showCopilot()` are not available in local Vite dev mode since there is no parent GO app. You can mock them for testing:

```javascript
if (!window.__INFORMER__?.openChat) {
    window.__INFORMER__ = window.__INFORMER__ || {};
    window.__INFORMER__.openChat = (opts) => console.log('openChat:', opts);
}
if (!window.__INFORMER__?.showCopilot) {
    window.__INFORMER__ = window.__INFORMER__ || {};
    window.__INFORMER__.showCopilot = () => console.log('showCopilot: copilot button would appear');
}
```

## Registering Tools (Report Bridge)

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

## AI Completions from Apps

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

### Streaming Chat (`_chat`)

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
// Tool implementations — the frontend tool handlers proxy through
// app server routes (server/tools/search-schema.js,
// server/tools/run-query.js) that use context.<slot>.query(...) on
// the bound datasource. The frontend never sees the datasource UUID.
// See Accessing Your Dependencies in SKILL.md for why this matters.
const toolHandlers = {
    searchSchema: async ({ query }) => {
        const resp = await fetch('/api/_server/tools/search-schema', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ query })
        });
        return resp.json();
    },
    runQuery: async ({ sql }) => {
        const resp = await fetch('/api/_server/tools/run-query', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ sql })
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

### Simple Completion (`_completion`)

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

### Structured Output (`_object`)

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
| `outputSize` | `string` | `"small"`, `"medium"` (default), or `"large"` — controls max output length. Supported on servers >= 2025.2.x with the I5-12415 fix. |

**Dev mode:** All three endpoints work in local dev mode — the Vite proxy handles authentication automatically.

### Defensive Parsing for `_object` Responses

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
