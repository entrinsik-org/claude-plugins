# App APIs — discovering contracts, typed integration, and publishing your own

> **Load this reference when:** integrating with another App or pack (writing `context.<slot>.request()` calls against a `target: app` / `target: pack` slot), fetching an App's API contract (`openapi.json`), setting up typed dev bindings (`.informer/app-deps.d.ts`), or making your own App integratable (`export const description` / `export const schema`, `config.api = 'public'`, a root `API.md`).

**Version floors:** the `openapi.json` endpoint requires Informer **≥ 2026.1.1** (older servers 404 it). Typed `.d.ts` generation requires `@entrinsik/vite-plugin-informer` **≥ 2.6.0-beta.2**.

## Every deployed App publishes a contract

Every App with `server/` routes serves an **OpenAPI 3.0.3 document** describing them:

```
GET /api/apps/{owner}:{name}/openapi.json     # e.g. /api/apps/admin:kanban/openapi.json
```

Access matches app visibility: if you can see the App (read access), you can read its contract — anonymous gets 401, a user the App isn't shared with gets 404. The document carries, per route:

| In the document | From |
|---|---|
| Method, path, path params | The deployed `server/` file layout |
| Query/body/response shapes | The handler's `export const schema` (when declared) |
| Operation description | The handler's `export const description` |
| `x-informer-roles` | The handler's `config.roles` — the role a caller's user must hold |
| `x-informer-public: true` | The handler's `config.api = 'public'` — the author-curated public surface |
| `info.description` | The App's root `API.md` — the author's integration guide, recipes included |

**Fetch the contract before writing any `context.<slot>.request()` call.** Never guess a target's routes from its source or from route names — the contract is the single source of truth for what exists, what parameters are required, and what roles a call needs.

### Public vs internal routes

Routes marked `x-informer-public: true` are the surface the author invites you onto. Everything else is internal plumbing the author is free to refactor between versions — code against it and your app breaks on their next release, without warning, legitimately. If the route you need isn't public, ask the target App's author to mark it (one line — see "Making your App integratable" below) rather than depending on internals.

## App or pack? (pick the right target)

| Your situation | Declare | Binding |
|---|---|---|
| Integrating with an App **on this instance** (yours or a colleague's) | `target: app` | `defaultBinding: <app-uuid>` binds at deploy |
| Your app will be **published to the marketplace** and depends on another **marketplace pack** | `target: pack` | The pin (`pack:` slug + `requires:` range) resolves to the installer's local copy — no binding to manage |

The pack form is author-owned, version-gated (calls 422 cleanly when the installed version is outside `requires`), and self-healing across the target's reinstalls — full mechanics in the **marketplace-publishing** skill. Either way, handler code is identical: `await context.<slot>.request({ method, url, params, data })`, and both resolve to the target's `server/` routes with the same one-hop limit.

## Typed calls in dev (`devBindings` → `.d.ts`)

With a `target: app` or `target: pack` slot declared, point the slot at a locally-installed copy in dev:

```javascript
// vite.config.js
informer({
    devBindings: {
        kanban: { app: 'admin:kanban' }   // or the shorthand: kanban: 'admin:kanban'
    }
})
```

On `npm run dev` the plugin fetches the target's `openapi.json`, writes **`.informer/app-deps.d.ts`**, and adds `.informer/` to your `.gitignore`. Opt a handler in with a JSDoc annotation and `context.<slot>.request()` gets real overloads — method, url, params, and the 200 response shape:

```javascript
/** @param {import('../../.informer/app-deps').HandlerBag} bag */
export async function GET({ context }) {
    return await context.kanban.request({
        method: 'GET',
        url: 'issues',                    // relative to the target's API — no leading slash
        params: { project: 'I5' }
    });
}
```

The import path is relative to the handler file — one `../` per directory below `server/`.

Failure modes are split by cause, so the dev-console warning tells you which thing to fix:

| Symptom | Meaning |
|---|---|
| 401 / 403 | The binding is wrong, or the App isn't shared with your dev user |
| 404 | The app ref doesn't exist — or the server predates `openapi.json` (< 2026.1.1) |
| Network error | Transient — your **last-good** `.d.ts` is kept, never emptied |

## Making your App integratable

Three author-side declarations turn your App from "has routes" into "has an API." All are optional — every deployed route documents at the skeleton level (method + path + path params) with zero effort — but the curated version is what makes dependents (and their AI tooling) actually build on you.

### 1. Mark your public surface — `config.api = 'public'`

```javascript
// server/issues/index.js
export const config = { api: 'public', roles: ['dev'] };
```

Marks every method this file exports as part of your **public contract** (`x-informer-public: true` in the document). Unmarked routes stay reachable but unadvertised — you can refactor them freely. Mark deliberately: the public surface is a compatibility promise, and (for marketplace packs) breaking it without a major version bump warns at publish time.

### 2. Describe the contract — `description` + `schema`

```javascript
export const description = 'App-owned issues — shaped list views, create, and rank';

export const schema = {
    GET: {
        query: {
            properties: {
                project: { type: 'string', description: 'Project key, e.g. I5' },
                view: { type: 'string', description: 'board | triage | resolved | all' }
            },
            required: ['project']
        },
        response: { properties: { issues: { type: 'array' } } }
    },
    POST: {
        body: { properties: { action: { type: 'string' } }, required: ['action'] }
    }
};
```

- `schema` slices are per-method (`GET:` / `POST:` keys, **uppercase**); a flat schema (no method keys) applies to every method the file exports. Each slice takes `query` / `body` / `response` as JSON-Schema fragments — they become the document's `parameters`, `requestBody`, and 200 response.
- `description` must be a plain string literal (single, double, or backtick quotes — no expressions).

Deploy behavior is deliberately asymmetric: a **near-miss `schema`** (lowercase `get:` key, a `query` without `.properties`, a non-object `body`) deploys fine and reports the exact problem via the deploy response's `partialFailures` — a bad schema only costs you documentation. An **unparseable `config`** fails the whole deploy — a bad config would cost you the role gate, so it fails closed.

### 3. Write the guide — root `API.md`

An `API.md` at the project root becomes the contract's `info.description` — the prose half of your API: why to integrate, how access works, and 2–3 **recipes** (concrete request patterns). It ships with both `informer-deploy` and `informer-publish`, renders on the marketplace listing's **Integrate** tab, and is read verbatim by AI tooling building against your app — write the recipes as the usage patterns you want copied.

Live-read on the instance: editing `API.md` updates the served contract on the next deploy of the file — route metadata (`schema` / `config`) refreshes on redeploy since it lives in the route registry.

### What consumers see

- **On an instance:** `GET /api/apps/{id}/openapi.json` — always current with the deployed code.
- **On the marketplace:** the contract is frozen per published version and rendered on the listing's **Integrate** tab (guide, public routes, copy-paste on-ramps). Publishing mechanics — including the "public API changed without a major version bump" warning — live in the **marketplace-publishing** skill.
