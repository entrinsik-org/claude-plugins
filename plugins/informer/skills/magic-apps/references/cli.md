# CLI — commands people run from their terminal

> **Load this reference when:** the app should be usable from a terminal or a script — "add a command", "CLI", "`inf`", "run it from the shell", "a script / CI job that calls the app", "sync a folder", "import these files from my computer", "watch a folder". Covers the `cli/` folder, the command file contract (`description`, `schema`, `handler`, `cli`, `confirm`, `roles`, `complete`, `watch` + `added` / `changed` / `removed`), how arguments map from the schema, what the handler gets beyond the tool bag (`run.trigger: 'cli'`, `run.client`, `run.timeZone`, `reply()`, `follow()`, `client`), sessions that work in the person's own folders (`format: 'directory'` with `access: read | write | mirror`), files in and out, `--watch`, output and `--json`, who a command runs as, CI with an App API key, limits and billing, and what to tell people: `inf login`, `inf install`, `inf deploy`.
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
| `run.client` | What the CLI says about its computer: `{ os, arch, release, node, cliVersion, cpus, memoryGb }`. Self-reported: show or check it, never treat it as proof of anything. |
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

A command that calls back to the terminal runs as a **session**: the CLI opens a socket to the app, and the handler's `client` reaches the computer that ran it while the run lasts. A command is a session when its schema has a folder argument, its source calls `client.files` / `client.prompt` / `client.progress` / `client.log` or takes `client` from the bag, or it declares `cli.session: true`.

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

A refused call throws with `err.code`: `cli_access_denied` (outside the folders or above their level), `cli_not_found`, `cli_no_terminal`, `cli_bad_answer`, `cli_list_too_long`. Ctrl-C or a dropped connection fails waiting calls within a second and stops the run, which is recorded as failed — the work and its billing stop with it.

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

With `--watch` the CLI runs `handler` once, then sends each file that appears, changes or goes, one at a time and in order, until Ctrl-C. Each event runs its export with `{ args, file }` (and `client`) as its own session run. `watch.folder` names a folder argument; `watch.glob`, when set, names the string argument whose value filters which files' events are sent. Dotfiles, editor leftovers and saves that changed nothing are never sent; a dropped connection reconnects and syncs again; a failing event is printed and the watch goes on. A watch that cannot work (no event export, a `folder` that is not a folder argument) deploys with a warning and no `--watch`.

## Who a command runs as

The person who ran it, signed in through `inf`: every query, `context` call and `fetch` is theirs, and `run.roles` are their app roles from the share. They see only the apps shared with them and only the commands their roles allow.

- **`inf login <server>`** signs a person in. **`inf install <owner:slug> <name>`** gives an app a command of its own (`name move I5-1 Done`) with a sign-in bound to that one app: a token that can reach nothing else, kept apart from their `inf` sign-in. In an app's own instructions, tell people the `inf install` line, by the app's natural id (`owner:slug`), not its UUID.
- **Scripts and CI:** an **App API key** with **Runs CLI commands** on (App Admin → API Keys) signs `inf` in from the environment — `INFORMER_URL` plus `INFORMER_TOKEN=<key>`. It reaches this app's commands and nothing else, runs as the key's owner, and the key's roles cap theirs. In a script, `--yes`, `--overwrite`, `--delete` and `--answer` replace the questions a terminal would ask.
- Every run is recorded with who ran it, the arguments, the result or error and the time taken. App Admin's **CLI** tab lists each command with its 30-day runs and failures, the latest runs, the copyable install and sign-in steps for that server, and who installed the app's commands, with revoke.

## Limits and billing

- A plain run has the sandbox's **30 seconds**. A session run may last **30 minutes** (`app.cli.sessionMaxMs`), one `client` call **10 minutes** including a prompt waiting on the person (`clientCallTimeoutMs`), with **8** calls open at once (`maxPendingCalls`).
- Runs are billed as app compute and refused (`402`) once the app's compute budget is spent; a session's time waiting on the terminal is billed as memory held, like an idle channel actor (`app.cli.idleCreditsPerGbHour`).
- Commands are a person's tool. For data another program reads on a schedule, a server route with an App API key (`server-routes.md`) is still the contract to build.

## Choosing `cli/`, `mcp/` or `server/`

| | `cli/` | `mcp/` | `server/` |
|---|---|---|---|
| Caller | a person at a terminal, or their script | an outside AI client's model | the app's pages, or another program over HTTP |
| Arguments | typed words, checked against `schema` | the model's JSON, checked against `schema` | `request.body` / `query` / `params` |
| Reaches the caller's computer | yes, in a session (`client`) | no | no |
| Result | printed (table, page, file) or piped | read by the model | an HTTP response |

The file contract is shared with `mcp/` and `tools/`, so one handler re-exported from `cli/` and `mcp/` serves both — branch on `run.trigger` where they differ.

## What to tell the person

When an app ships commands, its README or `docs.html` should carry the three lines a person needs, using the app's natural id:

```bash
npm install -g @entrinsik/informer-cli     # Node 22+
inf login acme.informer.cloud               # approve in the browser
inf install sales:pipeline pipe             # then: pipe --help
```

`inf install` offers to put its folder on the PATH and turn on tab completion (zsh, bash, fish, PowerShell); the person opens a new terminal before the command is found. `inf app` lists every app shared with them that has commands, and `inf app <app> --about` shows an app's whole description.
