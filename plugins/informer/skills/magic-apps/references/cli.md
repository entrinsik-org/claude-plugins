# CLI — commands people run from their terminal

> **Load this reference when:** the app should be usable from a terminal or a script — "add a command", "CLI", "`inf`", "run it from the shell", "a script / CI job that calls the app", "sync a folder", "import these files from my computer", "watch a folder", "a board / dashboard in the terminal", "an interactive screen", "show progress while it works". Covers the `cli/` folder, the five shapes a command can take and how to choose, the command file contract (`description`, `schema`, `handler`, `cli`, `confirm`, `roles`, `complete`, `watch` + `added` / `changed` / `removed`), how arguments map from the schema, what the handler gets beyond the tool bag (`run.trigger: 'cli'`, `run.client`, `run.timeZone`, `reply()`, `follow()`, `client`), sessions that work in the person's own folders (`format: 'directory'` with `access: read | write | mirror`), files in and out, `--watch`, the building blocks a terminal draws (`client.display`), interactive views (`render`, `init`, `actions`, `event`, `loaders`, `view = { follow }`), output and `--json`, who a command runs as, CI with an App API key, limits and billing, and what to tell people: `inf login`, `inf install`, `inf deploy`.
>
> **Not in this file:** the rest of the handler bag (`query`, `context`, `fetch`, `emit`, `log`, …) — see `server-routes.md`; staged upload and download handles in depth — see `streams.md`; channels a command can `follow()` — see `channels.md`; tools for outside AI clients — see `mcp.md`, the same file contract for a different caller.
>
> **Availability:** Informer **2026.1.4+** (I5-13206). Feature-detect `platform?.capabilities?.cli` in a handler or on the page: `true` on an App, `false` on a Magic Report (deploy refuses `cli/` there), absent on older builds. `@entrinsik/vite-plugin-informer` **2.14.0+** uploads `cli/`; earlier releases leave the folder behind, so the commands never appear. Against a server below 2026.1.4, 2.14.0+ leaves `cli/` on disk and says why, since those servers would serve the handlers as static files. `npm run dev` does not run commands (the dev `platform` reports `cli: false`): deploy to try one. People run commands with `@entrinsik/informer-cli` (`inf`, Node 22+), and a server administrator adds the **Informer Command Line Interface** OAuth client once (Admin → OAuth Clients → New) before anyone can sign in.

An app with a `cli/` directory has commands. Deploy scans it, so `npm run deploy` is all it takes — **the folder is the declaration**, as with `mcp/`.

```
my-app/
  cli/
    mine.js               → inf my-app mine
    move.js               → inf my-app move I5-1 Done
    retro/add.js          → inf my-app retro add "Ship it"
    releases/index.js     → inf my-app releases
```

Path segments become the words a person types; `index.js` names its folder. Words are lowercase letters, digits and single dashes (`on-duty`). A `[param]` segment fails the deploy — arguments come from the schema. Two files naming the same command fail it too, and so does a command that is also the first words of another (`retro` and `retro add`): the CLI could not tell the command `retro add` from `retro` given the argument "add".

## Five shapes of command

Each shape holds server resources only as long as it needs them. Pick the smallest that does the job:

| Shape | The file exports | How it runs | Held on the server | For |
|---|---|---|---|---|
| **Plain** | `handler` | one run, up to 30 s | nothing once it answers | lookups, writes, reports |
| **Follow** | `handler` returning `follow(channel)` | one run, then the CLI tails the channel | a socket subscription | a live feed, a log |
| **Session** | `handler` that uses `client` | one run over the CLI's socket, up to 30 min | the isolate while it runs; a database connection only while it queries | work in the person's folders, a question mid-run, progress |
| **Watch** | `watch` + `added` / `changed` / `removed` | one session run per file event | per event | keeping a folder in step |
| **View** | `render` (+ `init`, `actions`, `event`, `loaders`, `view`) | one short run per key or broadcast | nothing but the socket; the state lives in the CLI | a board, a dashboard, anything a person works with keys |

**Session or view?** Ask who decides what happens next. A session is a script the server runs: "read the folder, *then* import, *then* ask". It finishes on its own, and its progress lives in its local variables, so it holds an isolate until it does. A view is a screen the person drives: "*whenever* I press f, *whenever* someone moves a card". It has no end, so no code runs between keys: each key is a short run that turns the state the CLI kept into the next state and frame. A board written as a session holds an isolate for hours and dies with the connection; a folder import written as a view becomes an awkward state machine. They combine: a view's action can `client.prompt`, and a session can `client.display` its progress.

## Writing a command

The `mcp/` contract — `description`, `schema`, `handler` — plus `export const cli` for how it is typed and shown:

```javascript
// cli/move.js
export const description = 'Move an issue to another column';

export const schema = {
    type: 'object',
    properties: {
        key: { type: 'string', description: 'Issue key, e.g. I5-12' },
        column: { type: 'string', enum: ['Todo', 'Doing', 'Done'] },
        note: { type: 'string', description: 'Why, for the history' },
    },
    required: ['key', 'column'],
    additionalProperties: false,
};

// positional order, and where it is listed in `inf my-app`
export const cli = { positional: ['key', 'column'], group: 'Issues', order: 2 };

export async function handler({ args, query, run, reply }) {
    const [issue] = await query(
        'UPDATE issues SET col = $2, moved_by = $3 WHERE key = $1 RETURNING key, col',
        [args.key, args.column, run.user.username]
    );
    if (!issue) throw new Error(`No issue ${args.key}`);
    return reply(`Moved ${issue.key} to ${issue.col}.`, issue);
}
```

`inf my-app move I5-12 Done --note "shipped"` runs it. `inf my-app` lists the commands by group, and `inf my-app move --help` prints the usage line, the description and each argument from the schema.

The scanner reads `description`, `schema`, `cli`, `watch`, `confirm` and `roles` **from the file's own source, each on its own**: they must be literals, not names imported or defined elsewhere in the file (a `ReferenceError` in the deploy warning means exactly this). `handler` may be re-exported (`export { handler } from '../mcp/move_issue.js'`), which is how one function serves both an MCP tool and a command.

### `export const cli`

| Key | Value | Effect |
|---|---|---|
| `positional` | `['key', 'column']` | Schema properties typed in order without a flag. A last entry ending `...` (`'files...'`) takes every remaining word and must be an `array` property. Anything not listed is a flag. |
| `group` | `'Issues'` | Heading the command is listed under; ungrouped commands come first. |
| `order` | number | Order within the listing; equal or missing orders sort alphabetically. |
| `output` | `'table'` / `'markdown'` / `'text'` / `'json'` | How a terminal shows the result. Without it the shape decides (below). `markdown` lays a string out as a page — headings, lists, tables, links — and stays markdown in a pipe. |
| `columns` | `['key', 'title', 'col']` | Which fields a table shows, in order. |
| `session` | `true` | Run as a session (below) though the source shows no `client` call — for a handler that passes the whole bag to a helper. |

Unknown keys and mistyped values warn at deploy and are dropped; they never fail it.

### Gates: `confirm` and `roles`

```javascript
export const confirm = true;              // asks "…?" first; scripts need --yes
export const roles = ['ops', 'admin'];    // app roles allowed to see and run it
```

Both are read as literals, never evaluated, so they cannot be computed. `confirm` must be `export const confirm = true` (or `false`); any other spelling deploys as `true` with a warning — the author reached for the gate, so the strict reading wins. A command with `roles` is hidden from, and refused (`403 cli_role_required`) to, anyone holding none of them; an app's owners (Publisher+) hold every role. A `roles` list the scanner cannot read closes the command to everyone until it is fixed, and deploy warns about a role `informer.yaml` does not define.

### Tab completion: `complete`

```javascript
export async function complete({ arg, partial, args, query }) {
    if (arg !== 'key') return [];
    const rows = await query('SELECT key FROM issues WHERE key ILIKE $1 ORDER BY key LIMIT 50', [`${partial}%`]);
    return rows.map(r => r.key);
}
```

Runs with the handler bag when someone presses Tab on an argument: `arg` is the argument, `partial` what is typed of it, `args` the rest typed so far. Return strings (at most 200 are kept). It has **3 seconds**, and a failure or timeout offers nothing rather than an error, so a slow completer never hangs a shell. Enum and boolean values, flags and command words complete without it. Completion runs are not recorded.

## Arguments

The CLI turns what was typed into an object shaped by `schema`, and the server validates it with the full JSON Schema before anything runs (`400 cli_invalid_args`, one line per problem). So `required`, `enum`, `minimum`, `pattern` and `additionalProperties: false` are real checks, and `description` is the help text.

| Schema | Typed as |
|---|---|
| `string` / `number` / `integer` | `--due-date 2026-10-01`, `--limit 5` (camelCase properties are typed kebab-case; both spellings work) |
| `boolean` | `--include-done` / `--no-include-done` |
| `array` | the flag repeated (`--tag a --tag b`), or the variadic positional |
| `object` | a JSON value (`--filter '{"col":"Done"}'`) |
| `format: 'binary'` (or an array of them) | local paths, or `-` for stdin: each file is uploaded first and the handler receives an **upload id** — `const file = await uploads.get(args.file)` (see `streams.md` for the handle) |
| `format: 'directory'` + `access` | a folder on the person's computer the command may work in — a session (next section) |

Every command also understands `--help`, `--json`, `--yes`, `--out`, `--overwrite`, `--delete`, `--hidden`, `--answer` and `--watch`, and those win over a property of the same spelling. **Don't name an argument `out`, `delete`, `json` and so on**, or it can only be given as a positional.

## What the handler gets

The tool bag (`args`, `run`, `context`, `query`, `transaction`, `fetch`, `emit`, `broadcast`, `notify`, `email`, `embed`, `crypto`, `markdown`, `extractText`, `uploads`, `downloads`, `log`, `env`, `platform` — see `server-routes.md`), plus three helpers only a command has:

| Field | Meaning |
|---|---|
| `run.trigger` | `'cli'` — branch on it when one handler also serves `mcp/` or an agent. |
| `run.user` | `{ username, displayName }` of the person who ran it, `run.roles` their app roles. |
| `run.timeZone` | IANA zone of the computer that ran it, else the user's Informer time zone, else the server's — always set, so "today" in a command means the person's today. |
| `run.client` | What the CLI says about its computer: `{ os, arch, release, node, cliVersion, cpus, memoryGb, blocks }`, `blocks` being the building blocks it draws (below). Self-reported: show or check it, never treat it as proof of anything. |
| `reply(message, data)` | Return it: a terminal shows `message`, while a pipe or `--json` gets `data`. Use it whenever the person wants a sentence and a script wants the record. |
| `follow(channel, { events })` | Return it: the CLI joins that channel and prints its events until Ctrl-C (one JSON line per event when piped), under the same rules as a page joining it. `events` limits what is printed. See `channels.md`. |
| `client` | The terminal that ran the command, in a session only (next section); `undefined` otherwise. |

`log()` still writes the app's Logs tab. To print a line on the person's terminal while the command runs, use `client.log()`.

### Results

Return a value and the CLI prints it. In a terminal the shape picks the form unless `cli.output` names one:

| Result | Printed as |
|---|---|
| array of objects | a table (`cli.columns`, else every key) |
| array of scalars | one per line |
| object | aligned `key  value` lines |
| string / number | as is (`cli.output: 'markdown'` lays a string out as a page) |
| `null` / `undefined` | nothing |
| a `downloads` handle | the file: saved under its filename (never over an existing file), to `--out`, or to stdout when piped |

Piped or with `--json`, everything is JSON, so `inf my-app mine | jq` always works; a string prints as it is, so `inf my-app report > report.md` writes the text. Throwing fails the run (`422 cli_command_failed`) with your message as the error; make it say what to do.

## Sessions: working in the person's folders

A command that calls back to the terminal runs as a **session**: the CLI opens a socket to the app, and the handler's `client` reaches the computer that ran it while the run lasts. A command is a session when its schema has a folder argument, its source calls `client.files` / `client.prompt` / `client.progress` / `client.log` / `client.display` or takes `client` from the bag, or it declares `cli.session: true`.

A session's workspace connection opens at its first `query()` and closes after **10 seconds** without one (`app.cli.sessionIdleMs`); the next query opens another. So a session waiting minutes on a prompt holds no database connection. It never closes inside a `transaction()` or while a `copyInto` / `fromQuery` streams, but **a temp table does not survive the close**: a session that needs one across a wait on the person makes a real table instead.

```javascript
// cli/backup.js — inf my-app backup ~/Documents/notes
export const description = 'Copy every note into a folder, one markdown file each';

export const schema = {
    type: 'object',
    properties: {
        folder: { type: 'string', format: 'directory', access: 'write', description: 'Where the files go' },
    },
    required: ['folder'],
};

export const cli = { positional: ['folder'] };

export async function handler({ args, query, downloads, client, reply }) {
    const notes = await query('SELECT slug, body FROM notes ORDER BY slug');
    let done = 0;
    for (const note of notes) {
        const dl = await downloads.create({ filename: `${note.slug}.md`, contentType: 'text/markdown' });
        await dl.write(note.body);
        await client.files.write(`${args.folder}/${note.slug}.md`, await dl.end());
        await client.progress({ label: 'Backing up', done: ++done, total: notes.length });
    }
    return reply(`Wrote ${notes.length} notes to ${args.folder}.`, { count: notes.length });
}
```

**A folder argument's `access` is the most the command may do there**, and naming the folder on the command line is the person's consent to it. `--help` says what each command may do in each folder, and App Admin's CLI tab badges it.

| `access` | Allows |
|---|---|
| `read` | `files.list`, `files.read`, `files.text` |
| `write` | also `files.write`: create and replace files |
| `mirror` | also `files.remove`: delete files — for a command that keeps a folder identical to the app |

A folder without a valid `access` deploys read-only with a warning; `access` on anything that is not `format: 'directory'` does nothing. The CLI resolves the folder to an absolute path before the run, so `args.folder` is that path: build file paths from it. Every call names a path, checked on the server against the folders and levels the command declares and checked again by the CLI against the real disk after symlinks, so a handler can never reach outside what was named.

What naming a folder does **not** consent to, enforced by the CLI:

- **Replacing** an existing file asks once per folder at a terminal, and needs `--overwrite` in a script. **Deleting** asks the same way and needs `--delete`, so raising a command to `mirror` in a later deploy cannot delete through a script's standing `--overwrite`.
- **Hidden entries** (a name starting with `.`, at any depth) are left out of listings and refused unless the person passes `--hidden`: a project folder holds `.env` and `.git`.
- The filesystem root is never a folder, and a home folder only ever to read.

### `client`

| Call | Returns |
|---|---|
| `client.files.list(folder, { glob?, hash? })` | `[{ path, name, size, mtime, hash? }]` — files under the folder, recursively, `name` relative to it with `/` separators. `glob` filters (`*.md`, `**/*.csv`); `hash: true` adds a SHA-256 to compare with what the app holds. Symlinks are skipped; more than 10,000 matches is refused — narrow with a glob. |
| `client.files.read(path)` | an upload handle (`text()`, `json()`, `copyInto(table)`, …, `streams.md`). The bytes are staged, never sent over the socket, and the upload is discarded when the run ends — store what you need before returning. |
| `client.files.text(path, encoding?)` | the file's text, releasing its upload at once. Use it to read many files in one run. |
| `client.files.write(path, download)` | writes a finished `downloads` handle (`await dl.end()`) to `path`, creating folders. |
| `client.files.remove(path)` | deletes a file (`mirror` only). |
| `client.prompt({ name, message, choices?, default? })` | the person's answer, as a string. In a script `--answer name=value` answers it; with no terminal and no answer it takes `default`, else the call fails naming the `--answer` to pass. Give every prompt a `name`. |
| `client.progress({ label, done, total })` | draws one live progress bar on the terminal (hidden when piped). |
| `client.log(text)` | prints a line on the person's terminal. |
| `client.display(tree)` | draws a live region from building blocks (below) and answers `{ show(tree), update(id, node) }` to change it. It only shows — for a status panel while the handler works. When the run ends the last frame stays; piped, only that frame prints; with `--json`, one `{"view": tree}` line per change. |

A refused call throws with `err.code`: `cli_access_denied` (outside the folders or above their level), `cli_not_found`, `cli_no_terminal`, `cli_bad_answer`, `cli_list_too_long`, `cli_view_too_large` (a tree over 256 KB of JSON), `cli_view_unknown_node` (`update` of an id the tree lacks). Ctrl-C or a dropped connection fails waiting calls within a second and stops the run, which is recorded as failed — the work and its billing stop with it.

### Keeping a folder in step: `watch`

```javascript
// cli/sync.js — inf my-app sync ./notes --watch
export const schema = {
    type: 'object',
    properties: {
        folder: { type: 'string', format: 'directory', access: 'read' },
        glob: { type: 'string', default: '**/*.md' },
    },
    required: ['folder'],
};
export const cli = { positional: ['folder'] };
export const watch = { folder: 'folder', glob: 'glob' };

export async function handler({ args, client }) { /* one full sync, also run first by --watch */ }

export async function added({ args, file, client, query }) {
    await query('INSERT INTO notes (path, body) VALUES ($1, $2) ON CONFLICT (path) DO UPDATE SET body = $2',
        [file.name, await client.files.text(file.path)]);
}
export const changed = added;
export async function removed({ file, query }) {
    await query('DELETE FROM notes WHERE path = $1', [file.name]);
}
```

With `--watch` the CLI runs `handler` once, then sends each file that appears, changes or goes, one at a time and in order, until Ctrl-C. Each event runs its export with `{ args, file }` (and `client`) as its own session run. `watch.folder` names a folder argument; `watch.glob`, when set, names the string argument whose value filters which files' events are sent. Dotfiles, editor leftovers and saves that changed nothing are never sent; a dropped connection reconnects and syncs again; a failing event is printed and the watch goes on. A watch that cannot work (no event export, a `folder` that is not a folder argument) deploys with a warning and no `--watch`. An event's `client.display` shows while that event runs and goes before its line is printed.

## Building blocks: what a terminal draws

`client.display` and views send a **tree**, and the CLI lays it out to the terminal's width. The server says what to show, never how: no escape codes cross, and every string is stripped of control characters before it is drawn.

| Node | Draws |
|---|---|
| `'text'` or `{ type: 'text', text, style? }` | wrapped text; `style`: `bold`, `dim`, `italic`, `underline`, `cyan`, `green`, `yellow`, `red` (or a list of them) |
| `{ type: 'markdown', text }` | a page, as `cli.output: 'markdown'` |
| `{ type: 'table', title?, columns?, rows, rowKey?, keys?, onSelect?, highlight?, empty? }` | aligned columns; `columns` picks and orders the fields; `empty` shows when there are no rows |
| `{ type: 'list', title?, items, keys?, onSelect?, empty? }` | `• item` lines (an item may be `{ text }`) |
| `{ type: 'columns', children }` | children side by side; stacked one under another when each would be under 16 columns wide |
| `{ type: 'box', title?, children }` | a frame around its children |
| `{ type: 'progress', label?, done, total }` | a bar with `done/total` and a percentage |
| `{ type: 'spinner', label? }` | an animated spinner |
| `{ type: 'pending', id, label?, load? }` | a placeholder spinner, replaced later by `update(id, …)` or, in a view, by a loader |
| `[ … ]` | its children, one under another |

Any node may carry an `id`, which `update(id, node)` (or a view's loader) replaces. A type the CLI does not know shows its `text`, else its `children`, so a newer block degrades on an older `inf`; `run.client.blocks` lists what this CLI draws if a command wants to choose. The frame is clipped to the terminal (rows past its height become "… N more lines"), wide characters and emoji count as two columns, and a resize redraws it. A tree is at most **256 KB** of JSON.

## Views: screens a person drives

A `cli/` file that **exports `render`** is a view — no `handler`, and one in the same file never runs (deploy warns). There is no long-running code: the CLI keeps the view's **state** and sends it back with every step, and each step is one short session run that returns the next state and frame.

```javascript
// cli/board.js — inf my-app board
import { cardsIn, historyOf, move } from '../lib/cards.js';

const NEXT = { todo: 'doing', doing: 'done' };

export const description = 'The board, live: pick a card, move it from the keyboard';
export const view = { follow: 'cards' };                 // broadcasts here run event()

export async function init({ args, query }) {            // once, when the view opens
    return { highlight: {} };                            // the first state
}

export async function render({ state, query }) {         // every step: state → tree
    const lane = async (id) => ({
        type: 'table', id, title: id, columns: ['key', 'summary'], rowKey: 'key',
        rows: await cardsIn(query, id),
        keys: { f: 'forward', enter: 'open' },           // key → action
        onSelect: 'peek',                                // the selection moving runs actions.peek
        highlight: state.highlight,                      // { 'VD-3': 'yellow' }
    });
    return [
        { type: 'columns', children: [await lane('todo'), await lane('doing'), await lane('done')] },
        state.showing ? { type: 'pending', id: 'detail', load: 'detail', label: 'Loading' } : '',
    ];
}

export const actions = {                                  // each returns the new state
    peek: ({ state, row }) => ({ ...state, showing: row.key }),
    forward: async ({ state, row, node, query, run, broadcast }) => {
        if (!NEXT[node]) return undefined;               // already done: nothing changes
        await move(query, row.key, NEXT[node], run.user.username);
        await broadcast('cards', 'changed', { key: row.key, by: run.user.username });
        return { ...state, highlight: {} };
    },
    open: async ({ state, row, client }) => {            // an action may ask
        const note = await client.prompt({ name: 'note', message: `Note for ${row.key}` });
        return { ...state, note };
    },
};

export function event({ state, event }) {                 // a broadcast on view.follow
    return { ...state, highlight: { [event.payload.key]: 'yellow' } };
}

export const loaders = {                                  // fill a placeholder after the frame
    detail: async ({ state, query }) => ({
        type: 'list', title: 'History',
        items: (await historyOf(query, state.showing)).map(h => `${h.at}  ${h.by} ${h.change}`),
    }),
};
```

| Export | Runs | Gets | Answers |
|---|---|---|---|
| `init` | once, when the view opens (optional; the state starts `null` without it) | the bag | the first state |
| `render` | after every step | the bag, `state` | the tree |
| `actions.<name>` | a key bound in `keys`, or `onSelect` as the selection moves | `state`, `row` (the selected row), `node` (the table's `id`), `key` (`null` for onSelect) | the new state; `undefined` keeps it |
| `event` | for each broadcast on `view.follow`, oldest first | `state`, `event` (`{ event, payload, at }`) | the new state; `undefined` keeps it |
| `loaders.<name>` | for a `pending` node with `load: '<name>'`, after the frame is drawn | `state`, `node` (the placeholder's `id`) | the node that replaces it |

Every export also gets the handler bag (`query`, `run`, `broadcast`, `client`, …), and `args` from the command line.

**Keys.** The arrows (or `j`/`k`) move the selection and `←`/`→` or Tab move between tables with `keys`, all inside the CLI; only a bound key or `onSelect` reaches the server. `q`, Esc or Ctrl-C quits. A dim line under the frame names the keys. The selection follows a row by its `rowKey` across frames, else by position.

**State is the CLI's, and untrusted.** It comes back with every step exactly as the last step answered, so treat it like `args`: the person could change it. Every step runs as the person, so their permissions hold anyway; the app's own tables are guarded by the queries you write, as everywhere. Keep it small — ids and flags, not rows: `render` queries what it shows each time, and state over **64 KB** (`app.cli.maxViewStateBytes`) fails the step.

**Steps.** Keyed actions, selections and events go one at a time, in order; while one runs, only the newest selection waits behind it, since the person has moved past the rest. Broadcasts that arrive together (within 150 ms, or while a step runs) go as one step — `event()` runs for each, the frame renders once — so a bulk change costs each open view one run. A step that fails prints its message and the view keeps the frame and state it had.

**Placeholders.** `render` answers one whole tree, so a slow part delays the frame. Put it in a `pending` node with `load`, and the frame goes out without it; the CLI then runs the loader (up to 4 at once, beside the steps) and swaps its node in. A loader answering after a newer frame is dropped, and that frame's placeholder loads afresh.

**Following.** `view.follow` names a channel, and may take arguments from the command line: `follow: 'cards/{project}'` with a `project` string or number argument. A value that is missing or would not make one channel's name (a `/`, a space) follows nothing. The CLI subscribes on the same socket under the usual channel rules (`channels.md`). Broadcast after a write so every open view, this one included, hears it.

**Connection.** A dropped connection reconnects with backoff, renders the state the CLI kept, and subscribes again; keys pressed meanwhile wait. Not at a terminal, or with `--json`, only the opening step runs (with its loads), its frame prints plain or as JSON, and the command ends.

## Who a command runs as

The person who ran it, signed in through `inf`: every query, `context` call and `fetch` is theirs, and `run.roles` are their app roles from the share. They see only the apps shared with them and only the commands their roles allow.

- **`inf login <server>`** signs a person in. **`inf install <owner:slug> <name>`** gives an app a command of its own (`name move I5-1 Done`) with a sign-in bound to that one app: a token that can reach nothing else, kept apart from their `inf` sign-in. In an app's own instructions, tell people the `inf install` line, by the app's natural id (`owner:slug`), not its UUID.
- **Scripts and CI:** an **App API key** with **Runs CLI commands** on (App Admin → API Keys) signs `inf` in from the environment — `INFORMER_URL` plus `INFORMER_TOKEN=<key>`. It reaches this app's commands and nothing else, runs as the key's owner, and the key's roles cap theirs. In a script, `--yes`, `--overwrite`, `--delete` and `--answer` replace the questions a terminal would ask.
- Every run is recorded with who ran it, the arguments, the result or error and the time taken. A view records its opening, keyed actions and events; a selection moving and a placeholder loading happen on every arrow key, so they are recorded only when they fail. App Admin's **CLI** tab lists each command with its 30-day runs and failures, the latest runs, the copyable install and sign-in steps for that server, and who installed the app's commands, with revoke.

## Limits and billing

- A plain run has the sandbox's **30 seconds**. A session run may last **30 minutes** (`app.cli.sessionMaxMs`), one `client` call **10 minutes** including a prompt waiting on the person (`clientCallTimeoutMs`), with **8** calls open at once (`maxPendingCalls`). A view has no limit on how long it stays open: nothing runs between its steps.
- Runs are billed as app compute and refused (`402`) once the app's compute budget is spent; a session's time waiting on the terminal is billed as memory held, like an idle channel actor (`app.cli.idleCreditsPerGbHour`). A view's every step is a short run, billed as one (about 60 ms to start, plus its queries), and idle time costs nothing.
- **A view's cost grows with the people watching it.** Each open view renders for its own person, so one broadcast to a channel with 50 open views is 50 runs. Batching makes a burst one run per view, not one per change; for many viewers keep `render` cheap, and push slow parts into loaders.
- Commands are a person's tool. For data another program reads on a schedule, a server route with an App API key (`server-routes.md`) is still the contract to build.

## Choosing `cli/`, `mcp/` or `server/`

| | `cli/` | `mcp/` | `server/` |
|---|---|---|---|
| Caller | a person at a terminal, or their script | an outside AI client's model | the app's pages, or another program over HTTP |
| Arguments | typed words, checked against `schema` | the model's JSON, checked against `schema` | `request.body` / `query` / `params` |
| Reaches the caller's computer | yes, in a session (`client`) | no | no |
| Result | printed (table, page, file, a live view) or piped | read by the model | an HTTP response |

The file contract is shared with `mcp/` and `tools/`, so one handler re-exported from `cli/` and `mcp/` serves both — branch on `run.trigger` where they differ.

## What to tell the person

When an app ships commands, its README or `docs.html` should carry the three lines a person needs, using the app's natural id:

```bash
npm install -g @entrinsik/informer-cli     # Node 22+
inf login acme.informer.cloud               # approve in the browser
inf install sales:pipeline pipe             # then: pipe --help
```

`inf install` offers to put its folder on the PATH and turn on tab completion (zsh, bash, fish, PowerShell); the person opens a new terminal before the command is found. `inf app` lists every app shared with them that has commands, and `inf app <app> --about` shows an app's whole description.
