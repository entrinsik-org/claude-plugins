# MCP — exposing an app's tools to outside AI clients

An app with an `mcp/` directory is an MCP server. External clients (Claude Code, Claude Desktop, Cursor) connect to a per-app endpoint, the user signs in through Informer, and the client can call the app's exposed tools.

```
my-app/
  mcp/
    find_order.js       → tool "find_order", callable by MCP clients
    orders/lookup.js    → tool "orders_lookup" (nested → underscore, same as tools/)
  tools/
    update_status.js    → tool "update_status", agents only
```

Deploy scans both directories, so `npm run deploy` is all it takes. No manifest block, no flag: **the folder is the declaration.**

## The one rule: which folder

`mcp/` and `tools/` share the same file contract (`description`, `schema`, `handler`), the same sandbox, and the same service bag. The only difference is who may call them, and that difference is the whole point:

| | `tools/` | `mcp/` |
|---|---|---|
| Who calls it | the app's own agents | any MCP client the app is shared with, **and** the app's agents |
| Who decides when | the agent's `instructions`, written by you | a stranger's model, at a moment you don't control |
| Who decides the arguments | your agent, primed by your instructions | that model, from your `schema` and `description` alone |

An agent tool is safe *because* of its context: `update_status` cancelling the oldest pending order is fine as step 3 of a workflow you wrote. The same tool is a loaded gun when an outside assistant picks the moment and the arguments. Put a tool in `mcp/` when it was **written knowing that**.

Practical consequences:

- **Don't move an agent tool into `mcp/` to "reuse" it.** Re-read it as if a stranger's LLM will call it with surprising arguments. If that reading is fine, move it. If not, write a narrower tool.
- **Beware `emit()` tools.** A tool whose job is to fire an event into your agent pipeline lets an outside client push arbitrary events into your automation. Almost never what you want in `mcp/`.
- **Agents may use `mcp/` tools.** List them in an agent's `tools:` like any other; a tool written for strangers is by construction safe for your own agent. The reverse never happens: nothing in `tools/` is reachable over MCP.
- **One namespace.** The same tool name in both directories fails the deploy with an explicit error. Names are derived identically (path under the directory, `/` → `_`).

## Writing an mcp/ tool

Identical to an agent tool, except you write the `description` and `schema` for a reader with no context:

```javascript
// mcp/find_order.js
export const description =
    'Look up an order by customer name or order number, with its shipment if it has one';

export const schema = {
    type: 'object',
    properties: {
        customer: { type: 'string', description: 'Part of the customer name, e.g. "contoso"' },
        id: { type: 'integer', description: 'The order number, if you have it' },
    },
    additionalProperties: false,
};

export async function handler({ args, query, run }) {
    if (!args.customer && args.id == null) return { error: 'Pass a customer or an id.' };

    const orders = await query(
        `SELECT id, customer, total, status, created_at
           FROM orders
          WHERE ($1::int IS NULL OR id = $1)
            AND ($2::text IS NULL OR customer ILIKE $2)
          ORDER BY created_at DESC LIMIT 20`,
        [args.id ?? null, args.customer ? `%${args.customer}%` : null],
    );
    return { found: orders.length, orders };
}
```

**The description is the API doc.** An agent tool's description can be terse because the agent's `instructions` supply the context ("use check_inventory for each item"). An `mcp/` tool has no instructions anywhere: the description and the schema are the *only* things the calling model sees. Write them like public API docs.

**Return shapes should be self-describing.** `{ found: 0, orders: [], message: 'Nothing matching "eagle rare" is in stock.' }` beats `[]`. The model relays your words to a human.

**Say what you truncated.** Returning `{ returned: 25, totalMatching: 380, ... }` stops a capped list from reading as "that's everything".

**Don't guess for the caller.** When input is ambiguous, hand back candidates and let the model choose:

```javascript
if (matches.length > 1) {
    return { found: false, ambiguous: matches.map(m => ({ id: m.id, name: m.name })),
             message: 'More than one match. Call again with one of these ids.' };
}
```

## Identity: who the tool runs as

An MCP call runs the tool **as the user who signed in**, not as the app owner:

- `context.<slot>` and `fetch` follow each dependency's `runAs`. A slot declared `runAs: user` (the default) resolves to the connected person, so their row level security applies to Datasets, Queries, and Datasources.
- `run.user` is the caller, `run.roles` their [app roles](../SKILL.md#app-roles) from the share, `run.trigger` is `'mcp'`. The same handler serves an agent run (where `run.trigger` is the event) and an MCP call, so branch on `run` if you need to.
- Only people the app is **shared** with can connect at all; to anyone else the endpoint 404s.

**The app's own workspace is not per-caller.** `query()` opens the workspace as the app's Postgres role, exactly as it does for `server/` routes and agent tools. There is no automatic per-user layer on tables your app owns, so **your tool is the access control**. If a caller should only see their own rows, filter for it:

```javascript
export async function handler({ args, query, run }) {
    return await query('SELECT * FROM notes WHERE owner = $1', [run.user.username]);
}
```

That is not an MCP-specific caveat (your `server/` routes have the same property), just the place it matters most: an outside model will ask for everything.

## Connecting a client

The app's admin panel has an **MCP** tab with the endpoint address and a copy-paste snippet per client. From code, the address is the `inf:app-mcp` rel; never build it by hand.

```bash
claude mcp add --transport http my-app https://informer.example.com/api/apps/<app-id>/mcp
```

The first tool use opens a browser for sign-in. Under the hood: the endpoint 401s with a `WWW-Authenticate` header naming its RFC 9728 metadata → that names the authorization server → the client registers itself (RFC 7591) → PKCE authorization-code flow → a token bound to this app only (RFC 8707), carrying the `mcp` scope. That token authorizes this app's MCP endpoint and nothing else: not another app's, not the rest of the API.

**Dynamic client registration is off until a tenant admin enables it** (Admin → Settings → Security → *Allow OAuth dynamic client registration*). While it's off, `claude mcp add <url>` can't self-register; clients connect with an API token header instead:

```bash
claude mcp add --transport http my-app <url> --header "Authorization: Bearer <api-token>"
```

## Testing without a client

The endpoint is plain JSON-RPC over HTTP, so curl is enough:

```bash
curl -X POST "$URL/api/apps/<app-id>/mcp" \
  -H "authorization: Bearer <token>" \
  -H "accept: application/json, text/event-stream" \
  -H "content-type: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}'
```

Both `Accept` types are required (406 otherwise). Swap in `{"method":"tools/call","params":{"name":"find_order","arguments":{"customer":"contoso"}}}` to run one.

In local dev (`npm run dev`), the Vite plugin proxies `/api/*` to your server, so the endpoint is reachable at `/api/apps/<app-id>/mcp` with the plugin's auth.

## Observability

The admin panel's **MCP** tab lists the exposed tools with 30-day call counts, split from the **Tools** tab (which owns agent tools), so neither number flatters the other. Every MCP call writes an invocation row with its input, output, and duration; MCP-triggered rows have a null `agentId`.

## Gotchas

- **A tool in `mcp/` that isn't listed by `tools/list`** means the deploy didn't see it: the file must export a `handler`, and the app type must permit `mcp/` (Magic Reports don't; Apps do).
- **404 rather than 403** for a user the app isn't shared with. That's deliberate (the endpoint must not confirm an app exists), but it looks like a wrong URL. Check Sharing first.
- **Renaming the app** breaks clients configured with its natural id, and invalidates tokens bound that way. The uuid form of the address survives renames.
- **`claude mcp add` failing before any browser opens** usually means dynamic client registration is off, not a bad URL.
