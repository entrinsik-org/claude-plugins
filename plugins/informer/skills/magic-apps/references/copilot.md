# Embedded copilots

> **Availability:** the pattern on this page works on every 2026.1.x server: `POST /api/models/{model}/_chat`, its automatic grant to every App, and `system` + `dynamicSystem` all shipped in **2026.1.0**. Attaching other Apps' `mcp/` tools with `appIds` (and the tool-approval flow they bring) needs **2026.1.4+**.

An embedded copilot is a chat the App builds into its own UI and streams from Informer's model endpoint. It looks like the rest of the App, sees exactly what the user is looking at, acts through the App's own routes, and works wherever the App runs: a browser tab, the App's own origin, an installed PWA, or inside Informer GO. Nothing about it depends on a host page beside the App.

The rules below come from Informer's own streaming chat App, including the fixes it learned the hard way. Each one prevents a failure a copilot otherwise ships with.

## The shape of an embedded copilot

1. **The browser streams the turn** from `POST /api/models/{model}/_chat`. Every App may call it: `_chat`, `_completion` and `_object` are granted automatically (as the viewing user), so they need no `access.apis` entry. Listing them anyway is fine if you want the surface explicit.
2. **A static `system` prompt** describes the copilot's job and voice. **A per-turn `dynamicSystem`** carries what the user is looking at right now, assembled by one of the App's own routes just before each turn.
3. **Client tools** are the App's actions: the model asks for one, the page runs it (usually by calling an App route), and the SDK sends the next step on its own, capped per turn.
4. **Server tools** come from Informer: built-in `functions`, `toolkitIds`, and other Apps' `mcp/` tools via `appIds`.
5. **The transcript is the App's data.** Store the AI SDK UIMessages as-is in the App's workspace, through its own routes.

Call everything root-relative: `fetch('/api/…')`. The same build is served from the App's origin, from `/api/apps/{id}/view/…` and inside GO, and the session already carries the App's identity. A view-prefixed absolute URL is refused by GO cloud's `connect-src`.

## The transport (React)

Use the AI SDK: `ai` for the transport and helpers, `@ai-sdk/react` for `useChat`. Do not hand-roll the SSE parser in a React App. The endpoint speaks the AI SDK UI message stream, and `useChat` handles text, reasoning, tool parts and approvals for you.

```tsx
import { useMemo, useRef } from 'react';
import { useChat } from '@ai-sdk/react';
import {
    DefaultChatTransport,
    lastAssistantMessageIsCompleteWithToolCalls,
    lastAssistantMessageIsCompleteWithApprovalResponses
} from 'ai';

const MAX_AUTO_SENDS = 6;   // automatic continuations per user turn

export function useCopilot({ model, system, getContext }) {
    // Everything that may change between turns is read through a ref.
    const live = useRef({ model, system });
    live.current = { model, system };
    const autoSends = useRef(0);
    const addToolOutputRef = useRef(null);

    // Built ONCE. Rebuilding the transport mid-run aborts an in-flight tool loop.
    const transport = useMemo(() => new DefaultChatTransport({
        api: `/api/models/${model}/_chat`,
        prepareSendMessagesRequest: async ({ messages, trigger, messageId, id }) => {
            const { model, system } = live.current;
            // Per-turn context is a nicety: if it fails, the turn still goes.
            const ctx = await getContext(messages).catch(() => null);
            return {
                api: `/api/models/${model}/_chat`,
                body: {
                    id, messages, trigger, messageId,
                    system,
                    dynamicSystem: ctx?.dynamicSystem || undefined,
                    tools: CLIENT_TOOLS,
                    outputSize: 'medium'
                }
            };
        }
    }), []);  // eslint-disable-line react-hooks/exhaustive-deps

    const chat = useChat({
        transport,
        throttle: 50,   // tokens arrive faster than frames; without this every token re-renders the tree
        sendAutomaticallyWhen: (o) => {
            // A hard ceiling: a tool loop that never settles must not bill a request every few seconds.
            if (autoSends.current >= MAX_AUTO_SENDS) return false;
            const go = lastAssistantMessageIsCompleteWithToolCalls(o) || lastAssistantMessageIsCompleteWithApprovalResponses(o);
            if (go) autoSends.current += 1;
            return go;
        },
        async onToolCall({ toolCall }) {
            const output = await runClientTool(toolCall);   // see Client tools
            if (output === undefined) return;               // a server tool: not ours to answer
            addToolOutputRef.current?.({ tool: toolCall.toolName, toolCallId: toolCall.toolCallId, output });
        }
    });
    // onToolCall is defined before `chat` exists, so it reaches addToolOutput through a ref.
    addToolOutputRef.current = chat.addToolOutput;

    // Busy spans the gap between tool steps: after a tool answers, the SDK sends the
    // next request by itself, and treating that beat as "done" makes UI flash in and out.
    const continuing = chat.status === 'ready' && chat.messages.length > 0 &&
        (lastAssistantMessageIsCompleteWithToolCalls({ messages: chat.messages }) ||
         lastAssistantMessageIsCompleteWithApprovalResponses({ messages: chat.messages }));
    const busy = chat.status === 'submitted' || chat.status === 'streaming' || continuing;

    const send = (text) => {
        autoSends.current = 0;   // reset the ceiling on every user turn (and on approvals and edits)
        chat.sendMessage({ parts: [{ type: 'text', text }] });
    };

    return { ...chat, busy, send };
}
```

Two more rules:

- **Stop is `chat.stop()`**: wire it to a Stop button, to Escape while busy, and to leaving the screen.
- **Do not wrap the App in `<StrictMode>`.** It double-mounts the transport (and any channel subscription) in development.

A vanilla (no-build) App has no `useChat`. Read the stream directly and run the tool loop yourself; see [Reading the stream without the AI SDK](#reading-the-stream-without-the-ai-sdk).

## The `_chat` request body

| Field | Type | Notes |
|---|---|---|
| `messages` | `UIMessage[]` | **Required.** AI SDK UIMessages: `{ id, role, parts: [...] }`. Not the OpenAI `{ role, content }` shape, and no `system` role inside the array. |
| `system` | `string` | The static prompt: the copilot's job, voice and rules. Keep it stable from turn to turn so the provider can cache it. |
| `dynamicSystem` | `string` | Per-turn context: what is on screen, the user's name and timezone, "Now: …", a summary of earlier turns. |
| `tools` | `object` | Client tools, **an object keyed by tool name**, each `{ description, inputSchema }` (JSON Schema). The server does not run these: the call streams to the page. The OpenAI array shape is rejected with a 400. |
| `functions` | `string[]` | Built-in server functions, e.g. `datasetSearch`, `datasetLookupAndSearch`, `datasourceSqlTables`, `datasourceSqlColumns`, `searchResources`, `evaluateMath`. The server runs them. |
| `toolkitIds` | `string[]` | Toolkits whose tools the server runs. |
| `appIds` | `string[]` | **2026.1.4+.** Apps (uuid or `owner:slug`) whose `mcp/` tools the server runs as the user; unreadable ids add nothing. These tools can require approval ([Approvals](#approvals)). |
| `webSearch` | `boolean` | Let the model search the web. |
| `outputSize` | `string` | `small` / `medium` (default) / `large`. Caps reply length. |
| `maxSteps` | `number` | Server-side tool rounds per request (default 20). With client tools the loop runs in the browser instead, through `sendAutomaticallyWhen`. |

The server adds an `aiProgressMessage` parameter to every tool. The model fills it with a short "what I'm doing" line; show it on the tool card while the tool runs.

## System prompt and per-turn context

Split the prompt in two. `system` never changes within a conversation. `dynamicSystem` is rebuilt for every turn by one of the App's own routes, so it always reflects the current state.

```js
// server/copilot/context.js — POST /api/_server/copilot/context  { screen }
export async function POST({ request, query }) {
    const user = request.user;
    if (!user) return { status: 401, body: { error: 'No user' } };
    const blocks = [];
    // What the user is looking at, as the App knows it. describeScreen is yours:
    // look the record or view up here rather than trusting a large blob from the page.
    const view = await describeScreen(query, request.body?.screen);
    if (view) blocks.push(`What the user is looking at:\n${view}`);
    blocks.push(`Now: ${new Date().toISOString()}${user.timezone ? ` (user timezone ${user.timezone})` : ''}. The person's name is ${user.displayName || user.username}.`);
    return { dynamicSystem: blocks.join('\n\n') };
}
```

On the page, `getContext` posts the current screen state and returns that object. A copilot with memory adds the remembered facts and a summary of earlier turns to the same string.

## Client tools (App actions)

A client tool is how the copilot does something in the App: filter a view, open a record, draft a change. Define it once, send it on every turn, run it in `onToolCall`.

```ts
export const CLIENT_TOOLS = {
    findOrders: {
        description: 'Find orders matching a customer name or order number. Use before answering any question about a specific order.',
        inputSchema: {
            type: 'object',
            properties: { q: { type: 'string', description: 'Customer name or order number' } },
            required: ['q']
        }
    },
    openOrder: {
        description: 'Open an order in the app so the user can see it.',
        inputSchema: { type: 'object', properties: { id: { type: 'string' } }, required: ['id'] }
    }
};

async function runClientTool({ toolName, input }) {
    try {
        if (toolName === 'findOrders') {
            // The App's own route does the data work: it reads dependencies through
            // typed slots (context.<slot>), never raw platform endpoints from the page.
            const res = await fetch('/api/_server/orders/search', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ q: input.q })
            });
            return res.ok ? { orders: await res.json() } : { error: `Search failed (${res.status})` };
        }
        if (toolName === 'openOrder') {
            navigate(`/orders/${input.id}`);
            return { opened: true };
        }
    } catch (e) {
        return { error: e.message };   // return errors as data, never throw: the loop must continue
    }
    return undefined;                  // not a client tool
}
```

- **Return `{ error }` instead of throwing.** A thrown error stalls the turn; an error as output lets the model recover or explain.
- **A tool can be presentational.** A `chart` tool can return `{ rendered: true }` and let the message render the chart from the tool part's `input`.
- **Keep the ceiling.** Six automatic continuations per user turn. Reset it on each user send, approval and edit.

## Server tools

Put Informer's own capabilities on the server side of the call: `functions` for built-ins, `toolkitIds` for toolkits, and **2026.1.4+** `appIds` for other Apps' `mcp/` tools. The server runs them and streams their parts back. `onToolCall` still fires for them; return `undefined` so the page doesn't answer a call that isn't its own.

App tool names arrive as `app_<owner>_<slug>_<tool>_<hash>`. Decode one back into an app, a tool and a read-or-write kind before showing it to the user.

### Approvals

An App's `mcp/` tool runs as the user, so unless it declares `needsApproval = false` the server stops and asks: on the first call by default, on every call with `needsApproval = true`. The stream then carries the tool part in state `approval-requested` with `part.approval.id`, and the turn waits.

```ts
// On the tool card's buttons:
chat.addToolApprovalResponse({ id: part.approval.id, approved: true });
chat.addToolApprovalResponse({ id: part.approval.id, approved: false, reason: 'The user declined' });
```

`lastAssistantMessageIsCompleteWithApprovalResponses` then sends the next request, which is why it sits in `sendAutomaticallyWhen`. On the card, show the intent first (`input.aiProgressMessage`), then the arguments as labelled values, with the raw call behind a Details toggle. If the App keeps standing answers ("always allow"), apply them in an effect the moment a request appears, and paint an auto-approved card as running from its first frame so no prompt flashes.

## Rendering the reply

Streaming markdown looks broken unless the page manages it. The rules:

- **Throttle** `useChat` at 50 ms. **Memoise** each message on its message object and streaming flag.
- **Render per block**, one sanitized HTML string per top-level block (DOMPurify; links limited to http(s)/mailto with `target=_blank rel=noopener`).
- **Pace only the live last block.** The reveal runs on its own clock, releasing whole sentences or lines while the stream is live, with a short stall fallback. Text before a tool call is not paced: it may never end in a sentence break and would sit held back for the whole turn. On a hidden tab, show everything at once, since browsers starve `requestAnimationFrame` there.
- **Memoise on the text being rendered, not the text received.** Close unbalanced `**`, `*` and backticks in the last paragraph, and keep single-paragraph list items tight so items already on screen don't reflow.
- **Fade new words by colour, not opacity.** Opacity re-rasterises glyphs and nudges them.
- **Highlight code and typeset maths only once a block has settled.**
- **Merge consecutive text parts.** The stream splits text around tool calls and citations; those seams are not paragraph breaks.
- **Give each tool card and status line one root element for its whole life**, and the same size in every state. "Thinking…" and the reply's first line share one row height, so nothing jumps.
- **Park the sent prompt at the top of the view** and let the reply grow under it. Scroll by gliding, not jumping, and follow the bottom only while busy and pinned there.

## Errors and session loss

Show `chat.error` inline with a retry that regenerates the turn, and say what went wrong in plain words:

```ts
function describe(err) {
    const m = String(err?.message || err);
    if (/402|budget|credit/i.test(m)) return 'This copilot is out of AI budget for now. An admin can raise it under AI settings.';
    if (/401|403/.test(m)) return 'Your session has expired. Reload to sign in again.';
    if (/Failed to fetch|network/i.test(m)) return 'Lost the connection while answering.';
    return 'Something went wrong answering that.';
}
// "Try again":
chat.clearError(); chat.regenerate();
```

A session can end mid-use, and every request then fails quietly one by one. Route every App fetch through one helper that fires a single signed-out event on a 401, and show one "You're signed out" screen with a Sign in action. To probe whether the session is still alive, fetch an App route with `redirect: 'manual'`: an ended session answers with a redirect to sign in, and `manual` turns that into a plain failed response instead of a CORS error. An installed PWA also needs its service worker to serve the cached shell on an off-origin redirect, or the standalone window goes blank.

## Persisting the conversation

The wire format is the storage format: store each UIMessage's `parts` as JSONB, keyed by the id the page minted.

```sql
-- migrations/001-conversations.sql
CREATE TABLE conversations (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    owner text NOT NULL,
    title text,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE messages (
    conversation_id uuid NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    id text NOT NULL,           -- the UIMessage id minted on the page
    seq int NOT NULL,           -- 1-based position in the transcript
    role text NOT NULL,
    parts jsonb NOT NULL,       -- UIMessage parts, as sent
    PRIMARY KEY (conversation_id, id)
);
```

- **The page saves the whole array** with one `PUT /api/_server/conversations/:id/messages`: once when the user sends (so a reload mid-stream keeps the turn) and again in `useChat`'s `onFinish`, including aborts and errors.
- **The route replaces the transcript**: delete rows not in the list (this covers edit-and-resend), upsert the rest, and only rewrite a row whose parts actually changed.
- **Respond first, then work.** `await respond({ ok: true })`, then title the conversation, summarise it, or index it in the same handler; give the route `export const config = { timeout: 120000 }`. Make the title write race-safe: `UPDATE … SET title = $2 WHERE id = $1 AND title IS NULL`.
- **Create the conversation row alongside the first turn**, not before it, and have `prepareSendMessagesRequest` await it. The prompt then appears the instant the user sends.

When the copilot needs more than a transcript:

- **Memory across conversations.** After a settled turn with at least four new messages, one `_object` call proposes facts to add or update, capped at two new ones. Most conversations teach nothing durable, so an empty answer is normal. Filter what comes back in code too (drop activity logs, ticket ids and anything long): a prompt alone will not hold that line. Keep a watermark of the last message already mined.
- **Silent compaction.** Past roughly 160k characters of text, summarise all but the most recent 14 messages with one `_object` call, folding in any earlier summary. Store the summary and the position it covers; send the summary in `dynamicSystem` and drop the covered messages from `_chat`. Never show the summary to the user.
- **Recall over past chats.** Declare `embeddings/` for messages and search them by vector, falling back to Postgres full-text search when `platform.capabilities.embeddings` is off. Gate the pgvector migration with `-- requires: embeddings` so it is skipped rather than failing where the extension is absent.
- **Multi-tab sync.** Broadcast changes on `@user/<username>` channels and invalidate the matching queries. Channels exist only in origin mode, so gate on `platform.originMode`. Tag every write with a per-tab id so a tab ignores its own echo, and adopt a transcript another tab changed only while this one is idle.

## Calling the model from a server route

Use `_object` from `server/` handlers. It answers with buffered JSON, so it behaves the same in production and under the Vite plugin's `fetch` emulation, which mis-parses a `text/event-stream` body. Never consume a stream in a route. Use the bag's `fetch` with a path relative to the API root:

```js
// server/_lib/ai.js
export async function generateObject(fetch, { prompt, schema, outputSize = 'small', model = 'go_everyday' }) {
    const res = await fetch(`models/${model}/_object`, {
        method: 'POST',
        body: { messages: [{ role: 'user', parts: [{ type: 'text', text: prompt }] }], schema, outputSize }
    });
    if (res.status !== 200) throw new Error(`_object failed (${res.status})`);
    const raw = res.body;
    // Some paths wrap the result as { object }; accept both.
    return raw && typeof raw === 'object' && raw.object && typeof raw.object === 'object' ? raw.object : raw;
}
```

Small models drift from schemas, so normalise the output before using it ([Defensive parsing](#defensive-parsing-for-_object)). The call is metered to the App.

## Streaming in production

Tokens stream live through the App proxy when the server sets `appProxyStreaming: true`, and Informer cloud does. On a server without it, each reply arrives whole when the model finishes. A paced reveal (see [Rendering the reply](#rendering-the-reply)) keeps that looking smooth, so build the reveal regardless. In local dev the Vite plugin sends `/api` straight to the server, so replies always stream there.

## Choosing a model

`go_everyday` is a sound default slug. For a picker, list `GET /api/chat-models` (it answers a HAL collection: read `_embedded['inf:model']`, and accept a bare array too) rather than hard-coding tiers. `GET /api/ai-budget` reports the current user's AI budget (weekly and session windows, turns left per tier), if the App wants to show it before a 402 does. Both need `access.apis` entries: they are not auto-granted.

## Endpoint reference

Three endpoints, all granted to every App:

| Endpoint | Response | Tools | Use |
|---|---|---|---|
| `_chat` | UI message stream (SSE) | Client and server tools | The copilot |
| `_completion` | UI message stream (SSE) | None | One-shot text |
| `_object` | JSON | None | Structured output; the one to use from routes |

### Message and tool formats

Messages are AI SDK UIMessages with a `parts` array. Do not send the OpenAI shape, and do not put a system message in the array:

```js
// CORRECT
messages: [{ id: 'm1', role: 'user', parts: [{ type: 'text', text: 'Why did Q4 spike?' }] }]
// WRONG — OpenAI content string (validates, then fails deep inside the server)
messages: [{ role: 'user', content: 'Why did Q4 spike?' }]
```

Assistant messages carry tool parts typed `tool-<toolName>`, with `toolCallId`, `state`, `input` and, once answered, `output`. Send prior assistant messages back exactly as they came.

`tools` is an object keyed by name. The OpenAI array (`[{ type: 'function', function: {...} }]`) is rejected with a 400.

### Reading the stream without the AI SDK

The stream is `text/event-stream` with CRLF framing: events are separated by `\r\n\r\n`, each has an `id:` line and a `data:` line of JSON with a `type`. There is no `[DONE]` sentinel; the stream ends when the body closes.

| `type` | Meaning | Fields |
|---|---|---|
| `text-delta` | Text chunk | `delta` |
| `tool-input-available` | A tool call is ready | `toolCallId`, `toolName`, `input` |
| `tool-output-available` | A server tool returned | `toolCallId`, `output` |
| `tool-output-error` | A tool failed | `toolCallId`, `errorText` |
| `tool-approval-request` | A server tool needs approval | `approvalId`, `toolCallId` |
| `finish-step` / `finish` | A step / the stream ended | |
| `error` | Stream error | `errorText` |

A vanilla App runs the tool loop itself. `tool-input-available` fires for every tool call, including the ones the server runs (`functions`, `toolkitIds`, `appIds`), which are followed by their own `tool-output-available`, or `tool-output-error` when they fail. After the stream ends, append the assistant message with **every** call as a `tool-<name>` part: state `output-available` with the output (the server's for its tools, yours for yours), or state `output-error` with `errorText` for a server tool that failed, so the model sees the failure instead of an empty result. Run only your own tools, and post again if you ran any. Keep the same six-step ceiling.

Three things the reader has to handle that `useChat` handles for you:

- **A refusal is JSON, not a stream.** Check `res.ok` before reading; a 4xx/5xx body is `{ statusCode, error, message }`. Keep the status on the error, so the page can say "out of AI budget" for a 402 or "session expired" for a 401 (see [Errors and session loss](#errors-and-session-loss)).
- **Stop has to abort the request.** Pass an `AbortController`'s `signal` to `fetch`; aborting ends the read with an `AbortError`. Keep the text that already arrived as the reply rather than discarding it.
- **An `error` event can arrive mid-stream,** after text has already been shown. Surface it where the reply was going, and offer Try again.

```js
// Reads one _chat response. Resolves with what arrived; on Stop (an aborted
// signal) it resolves with the partial text and `aborted: true` instead of throwing.
async function readStream(res, onText) {
    const reader = res.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '', text = '';
    const calls = [], serverOutputs = {}, serverErrors = {};
    try {
        while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            buffer += decoder.decode(value, { stream: true });
            let cut;
            while ((cut = buffer.search(/\r?\n\r?\n/)) >= 0) {
                const raw = buffer.slice(0, cut);
                buffer = buffer.slice(cut).replace(/^\r?\n\r?\n/, '');
                const data = raw.split(/\r?\n/).filter(l => l.startsWith('data:')).map(l => l.slice(5).trimStart()).join('\n');
                if (!data) continue;
                let e; try { e = JSON.parse(data); } catch { continue; }
                if (e.type === 'text-delta') { text += e.delta; onText(text); }
                else if (e.type === 'tool-input-available') calls.push(e);
                else if (e.type === 'tool-output-available') serverOutputs[e.toolCallId] = e.output;
                else if (e.type === 'tool-output-error') serverErrors[e.toolCallId] = e.errorText;
                else if (e.type === 'error') throw Object.assign(new Error(e.errorText), { text });
            }
        }
    } catch (err) {
        if (err.name === 'AbortError') return { text, calls, serverOutputs, serverErrors, aborted: true };
        throw err;
    }
    return { text, calls, serverOutputs, serverErrors, aborted: false };
}

// crypto.randomUUID exists only in a secure context; plain-http servers have none.
const newId = () => globalThis.crypto?.randomUUID?.() ?? Date.now().toString(36) + Math.random().toString(36).slice(2);

async function turn(messages, onText, signal, step = 0) {
    const res = await fetch('/api/models/go_everyday/_chat', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ messages, system: SYSTEM, tools: CLIENT_TOOLS }),
        signal
    });
    if (!res.ok) {
        // A refusal is JSON ({ statusCode, error, message }), not a stream.
        const body = await res.json().catch(() => null);
        throw Object.assign(new Error(body?.message || `HTTP ${res.status}`), { status: res.status });
    }
    const { text, calls, serverOutputs, serverErrors, aborted } = await readStream(res, onText);
    const parts = text ? [{ type: 'text', text }] : [];
    let ranMine = false;
    for (const c of calls) {
        if (c.toolCallId in serverErrors) {
            parts.push({ type: `tool-${c.toolName}`, toolCallId: c.toolCallId, state: 'output-error', input: c.input, errorText: serverErrors[c.toolCallId] });
            continue;
        }
        const mine = !aborted && Object.hasOwn(CLIENT_TOOLS, c.toolName) && !(c.toolCallId in serverOutputs);
        if (!mine && !(c.toolCallId in serverOutputs)) continue;   // stopped before it ran: leave it out
        const output = mine ? await runClientTool(c) : serverOutputs[c.toolCallId];
        if (mine) ranMine = true;
        parts.push({ type: `tool-${c.toolName}`, toolCallId: c.toolCallId, state: 'output-available', input: c.input, output });
    }
    const next = [...messages, { id: newId(), role: 'assistant', parts }];
    if (aborted || !ranMine || step + 1 >= 6) return next;
    return turn(next, onText, signal, step + 1);
}

// Wiring: one controller per user turn, so Stop cancels the turn and every step after it.
let controller = null;
async function send(text) {
    controller = new AbortController();
    const messages = [...history, { id: newId(), role: 'user', parts: [{ type: 'text', text }] }];
    try {
        history = await turn(messages, renderReply, controller.signal);
    } catch (err) {
        showError(err.status, err.message);   // 402 → out of AI budget; 401/403 → session expired
    } finally {
        controller = null;
    }
}
stopButton.onclick = () => controller?.abort();
```

This loop does not answer approvals. A vanilla App that attaches `appIds` must handle `tool-approval-request`: show the call, then resend with that tool part in state `approval-responded` carrying `approval: { id, approved, reason? }`. Otherwise, attach only Apps whose tools declare `needsApproval = false`.

### `_completion`

```js
await fetch('/api/models/go_everyday/_completion', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ prompt: 'One sentence on this trend: ' + JSON.stringify(series) })
});
```

Fields: `prompt` (required) and optional prior `messages`. It does **not** take `outputSize`. The response is the same stream as `_chat`: read `text-delta` events.

### `_object`

```js
const res = await fetch('/api/models/go_everyday/_object', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
        messages: [{ role: 'user', parts: [{ type: 'text', text:
            `Summarise these orders.\n${JSON.stringify(rows)}\n\nRespond with JSON: { "summary": "<text>", "risks": ["<risk>"] }` }] }],
        schema: {
            type: 'object',
            properties: { summary: { type: 'string' }, risks: { type: 'array', items: { type: 'string' } } },
            required: ['summary', 'risks']
        },
        outputSize: 'small'
    })
});
const raw = await res.json();   // the object itself; normalise before use
```

Fields: `messages` and `schema` (both required), and `outputSize`.

### Defensive parsing for `_object`

`go_everyday` is a Haiku-class model and drifts from schemas. Expect:

- array fields returned as a bare string (`risks: "text"`);
- array items scattered into top-level keys (`item_1`, `risks_1`, …);
- enum values that are slightly off, and numbers as strings.

Never call `.map()` on a field without checking its type. Normalise first, and repeat the shape as a JSON example in the prompt text, so the model gets two signals:

```js
const asString = (v, max = 400) => (typeof v === 'string' ? v : v == null ? '' : String(v)).trim().slice(0, max);
function asArray(v, raw, key) {
    if (Array.isArray(v)) return v;
    if (typeof v === 'string' && v.trim()) return [v];
    if (raw && typeof raw === 'object') {
        const scattered = Object.keys(raw).filter(k => k.startsWith(`${key}_`) || /^item_\d+$/.test(k)).map(k => raw[k]);
        if (scattered.length) return scattered;
    }
    return [];
}
const result = { summary: asString(raw.summary), risks: asArray(raw.risks, raw, 'risks').map(r => asString(r, 160)) };
```

## Local development

All three endpoints work under `vite dev`: the plugin proxies `/api` to the server with your credentials, and streams live.
