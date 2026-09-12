# Streams (Staged Uploads & Downloads)

> **Load this reference when:** the app moves files or large data — a CSV/Excel import into a workspace table, an image or PDF attachment into a `bytea` column, a big export (CSV / JSON / JSONL) the browser saves, or any upload larger than a JSON body should carry. Covers `__INFORMER__.upload(file, opts)` and `__INFORMER__.downloadUrl(id, filename)` on the page, and the `uploads` / `downloads` objects in the handler bag (`uploads.get(id)` → `copyInto()` / `text()` / the handle as a `bytea` parameter; `downloads.create()` → `fromQuery()` / `writeRows()` / `write()` / `end()` / `dl.url`).
>
> **Not in this file:** the rest of the handler bag (`query`, `transaction`, `fetch`, `respond`, …) — see `server-routes.md`. Small files that fit a JSON field (base64 in, `base64Decode()` / `extractText(data, type)`) — see `server-routes.md`.
>
> **Availability:** Informer **2026.1.3+** (I5-12979). On older servers the handler bag has no `uploads` / `downloads` and the page has no `__INFORMER__.upload` — feature-detect (`if (!uploads)` in a handler, `typeof __INFORMER__.upload === 'function'` on the page) rather than compare versions; there is no `platform.capabilities` flag for streams. The page helper is injected by the server into every deployed app page, so it does not depend on the Vite plugin version; the **dev-server emulation** needs `@entrinsik/vite-plugin-informer` **2.10.0+** (see [Local development](#local-development)).
>
> **2026.1.3+, the I5-13030 build** (phase 2, same release, later build): transfer events (`onEvent`, `task.created`), the `412` resend, `__INFORMER__.streams` (`list()` / `status()` / `discard()`), the listing and discard routes, and forwarding a staged stream to an integration (`context.<slot>.request()` with a handle as `data` / in `form`, or `into`). The version probe cannot tell that build from an earlier 2026.1.3, so feature-detect on the page with `typeof __INFORMER__.streams === 'object'`; a handler learns it the hard way (`request()` with a handle on an earlier build sends `{}` for it). The dev emulation of phase 2 needs plugin **2.12.0+**.

## The model

Bytes never enter the app's isolate. The page stages them, the handler holds a **handle**, the host moves the bytes.

| Layer | Owned by | What it does |
|---|---|---|
| Page | Your app | `__INFORMER__.upload(file)` slices the file, `PUT`s chunks in parallel, retries, seals — and hands your route the resulting `id`. `__INFORMER__.downloadUrl(id, filename)` builds the save-as link for a download a route staged. |
| Staging store | Informer (harness) | Chunks and staged downloads live in Redis (the platform's `updown` store) for `ttlSeconds`, scoped to the app **and** the user who created them. |
| Handler | Your app's server code | `uploads.get(id)` / `downloads.create()` return plain metadata objects whose methods ask the host to move bytes: `COPY FROM STDIN` into a table, bind as a `bytea` parameter, stream a query into a download. |
| Routes | Informer | `POST` / `PUT` / `GET` / `DELETE …/view/_uploads/…` and `GET …/view/_downloads/{id}/{filename?}` under the app's own `/view` subtree — inside the page CSP, covered by the view token. Origin mode serves them as `/_uploads/*` and `/_downloads/*` on the app origin. The helper picks the right base; handlers never see a URL. |

A 100 MB import costs nothing against the isolate's 128 MB heap; a million-row export streams Postgres → browser without being materialized. Measured on the demo app: a 100k-row CSV lands in a table through `copyInto` in ~450 ms and streams back out in ~2 s.

### Which surfaces have it

`uploads` and `downloads` are in the bag of **server routes, webhooks, and tools**. **Channel handlers do not get them** (`Streams are unavailable in this context`). A `download.url` minted inside a webhook is fetchable only by the principal the handler ran as (the app owner, or a team app's first admin) — the intended use is build a file, then hand the link to `notify()` / `email()`. An anonymous webhook caller gets the bytes by **returning the handle** instead.

## Limits and scoping

Every stream belongs to the app **and** the user who created it. Another user's or another app's id answers **`404`, never `403`** — an id cannot probe for streams that are not yours. Authentication is whatever the page already has: the app view token (path-scoped cookie, `?token=`, or `Authorization: Bearer`) or a logged-in session.

`config.app.streams` is server-wide, set by the operator:

| Setting | Default | Applies to |
|---|---|---|
| `maxUploadBytes` | 100 MB | The declared size of one upload, and the bytes one download may stage — `413` with `data.maxUploadBytes` |
| `maxChunkBytes` | 8 MB | One chunk body (`413`) |
| `maxInlineBytes` | 10 MB | Reading an upload **into** the isolate — `text()`, `json()`, `base64()`, `extractText()` — `413` with `data.maxInlineBytes` |
| `ttlSeconds` | 3600 | How long a staged stream survives unconsumed |
| `maxStreamsPerUser` | 32 | Open streams one viewer may hold in this app (`429` at create) |
| `maxStagedBytesPerUser` | 512 MB | Declared bytes one viewer may hold staged in this app (`413` at create); released on discard, `DELETE`, or serve |

Don't design around bigger numbers. An app that needs more than 100 MB per file is asking the operator for a config change, not working around the cap.

## The page: `__INFORMER__.upload()`, `downloadUrl()`, and `streams`

```javascript
const controller = new AbortController();
const task = __INFORMER__.upload(file, {
    chunkSize: 4 * 1024 * 1024,   // default 4 MB; the server may clamp it — the helper uses the returned geometry
    concurrency: 3,               // parallel chunk PUTs
    retries: 5,                   // per chunk, exponential backoff with jitter
    onProgress: ({ loaded, total, percent }) => { bar.style.width = percent + '%'; },
    onEvent: e => log(e),         // each step as it happens — see Watching a transfer
    signal: controller.signal     // abort → the partial upload is DELETEd and its staged bytes freed
});
const { id, chunks, chunkSize } = await task.created;   // the geometry, before a chunk moves
const upload = await task;        // { id, filename, contentType, size, chunkSize, chunks, complete: true, expiresAt }

await fetch('/api/_server/import', {          // your own route — the id is all it needs
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ uploadId: upload.id })
});
```

What the helper does: `POST …/_uploads` with `filename`, `size`, `contentType`, a `fingerprint` (name + size + last-modified), and the requested `chunkSize`; `PUT …/_uploads/{id}/{n}` for every chunk (1-based, raw bytes, **idempotent** — a retry after an ambiguous failure just overwrites); `POST …/_uploads/{id}/_complete` to seal. A route can't use an upload until it is sealed (`uploads.get` → `409`).

- `task.id` is set as soon as the upload exists; `task.created` is a promise for that moment (it rejects with a create-time refusal such as a `413` over the cap, or a `429` over `maxStreamsPerUser`); `task.abort()` cancels and discards.
- **Sealing is the authority on what landed.** If `_complete` answers `412` because a chunk the server acknowledged never became durable, the helper resends exactly the chunks it names (at most 50) and seals again; a second `412` fails the upload, resumable.
- **Resume:** `__INFORMER__.upload(file, { resume: previousUploadId })` probes `GET …/_uploads/{id}` for `received` / `missing` (both arrays of chunk numbers) and sends only the missing chunks. It refuses unless the file matches both the **size and the fingerprint** the upload was created with — size alone would let two same-length files splice into one upload that completes without complaint.
- A failed upload **stays resumable**: only `abort()` discards; any other terminal failure carries `err.uploadId` so the page can offer "Retry" instead of starting over — except an upload the server already reclaimed (`err.code === 'upload_expired'`), which no resume could find. The TTL reclaims the bytes if nobody does.
- `__INFORMER__.downloadUrl(id, filename)` → the same-origin URL for a download a route staged. The trailing filename is cosmetic (bookmarkable, save-as friendly); `Content-Disposition` comes from the stream's own filename.

Every helper works unchanged in path mode, on an app origin, and under the Vite dev server. Don't hand-roll the protocol with `fetch` — the helper owns geometry, retry, abort, and the base URL.

### Watching a transfer (2026.1.3, I5-13030 build)

`onEvent` receives one plain object per step, in order. A progress bar hides the fact that three chunks are usually in flight and land out of order; this is how a page shows it.

| Event | Fields | When |
|---|---|---|
| `created` | `id`, `size`, `chunks`, `chunkSize`, `resumed`, `received` | The server has reserved the upload. `received` lists the chunks a resumed upload already held |
| `chunk` | `n`, `state`, `attempt?`, `status?` | `state` is `sent` when a PUT goes out, `landed` when it is acknowledged, `retry` when it failed with a retryable `status` and will be sent again, or `resend` when a `412` seal named it missing. `attempt` is 1-based, and absent on a `resend` |
| `sealed` | `handle` | The upload is complete; the same handle the task resolves with |
| `failed` | `error`, `aborted`, `resumable` | Terminal. `resumable` is true when `error.uploadId` is set — never for `upload_expired` |

A listener that throws does not fail the transfer it is watching; its error is rethrown on a fresh tick so it still reaches the console.

### `__INFORMER__.streams` (2026.1.3, I5-13030 build)

What the staging area holds for the current user in this app. The helper owns the base URL for these routes, so a page asks here rather than deriving a prefix from `downloadUrl('')` and building the calls itself.

```javascript
const { uploads, downloads } = await __INFORMER__.streams.list();   // oldest first
gauge.textContent = `${uploads.length + downloads.length} staged`;  // against maxStreamsPerUser

const state = await __INFORMER__.streams.status(staleUploadId);    // { received, missing, complete, … }
if (!state.complete) offerToResume(state.missing.length);

await __INFORMER__.streams.discard(uploads[0]);                     // a handle — now, not at expiry
await __INFORMER__.streams.discard(downloadId, 'download');        // or a bare id plus its kind
```

Behind it: `GET …/_uploads` and `GET …/_downloads` list the caller's own staged streams for this app (expired ones dropped; another user's never listed, whatever their app); `DELETE …/_downloads/{id}` discards a staged download nobody will claim (`204`; someone else's, or one already gone, `404`). A download that was served, discarded or expired is not listed — unless it was served with `?keep=true`, which leaves it staged and therefore listed.

`list()` is the truthful source for `maxStreamsPerUser`: streams an earlier session staged and abandoned count against it until they expire, and this is where a page finds them to clear. It is **not** a way to compute how much of `maxStagedBytesPerUser` is left: a stream still open (an unsealed download, an upload being filled from an integration) is held against the byte cap at the ceiling it could still reach, while `size` reports only what has landed (`0` until it seals).

## The handler: `uploads.get(id)`

```javascript
// server/import.js — POST { uploadId }. Bytes go staging store → COPY → temp table → upsert;
// the handler never holds a row. Give it time: config.timeout for big files.
export const config = { timeout: 120000 };

export async function POST({ request, uploads, query }) {
    const upload = await uploads.get(request.body.uploadId);   // 404 not yours · 409 not sealed
    await query('CREATE TEMP TABLE staging (LIKE orders INCLUDING ALL)');
    const { rowCount } = await upload.copyInto('staging', { format: 'csv', header: true });
    await query(`
        INSERT INTO orders (id, customer, region, total, ordered_on)
        SELECT id, customer, region, total, ordered_on FROM staging
        ON CONFLICT (id) DO UPDATE
            SET customer = EXCLUDED.customer, region = EXCLUDED.region,
                total = EXCLUDED.total, ordered_on = EXCLUDED.ordered_on`);
    await upload.discard();                                     // free the staged bytes now, not at expiry
    return { status: 201, body: { filename: upload.filename, imported: rowCount } };
}
```

The handle carries `id`, `filename`, `contentType` (inferred from the filename when the page didn't send one), `size`, `expiresAt`. Every method is async:

| Method | Returns | Where the bytes go |
|---|---|---|
| `copyInto(table, opts?)` | `{ rowCount }` | staging store → `COPY … FROM STDIN` into a workspace table. Never through the isolate. |
| *the handle as a `query()` parameter* | — | staging store → Postgres, bound as `bytea`. Never through the isolate. |
| `text(encoding?)` | string | into the isolate (default `utf8`) — capped by `maxInlineBytes` |
| `json()` | any | into the isolate, `JSON.parse`d — capped |
| `base64()` | string | into the isolate — capped |
| `extractText(contentType?)` | string | PDF / Excel / Word → plain text, into the isolate — capped |
| `discard()` | `true` | dropped now instead of at expiry |

**`copyInto()` runs on the invocation's own workspace connection**, which is what makes a `CREATE TEMP TABLE` from the same handler visible to it — the temp-table-then-upsert shape above is the idiom for keyed imports. Options: `format` (`csv` | `text`, default `csv`), `columns` (explicit list; default all), `header` (CSV, default `true`), `delimiter` / `quote` / `escape` (single characters), `null` (the string that means NULL). The table name (optionally schema-qualified) and every column must be plain Postgres identifiers — anything else is **rejected, not escaped**.

**The handle is a `bytea` parameter.** Store an image or a PDF without ever holding it:

```javascript
// server/attach.js
const upload = await uploads.get(request.body.uploadId);
const [row] = await query(
    `INSERT INTO attachments (name, mime, bytes, data) VALUES ($1, $2, $3, $4) RETURNING id, name`,
    [upload.filename, upload.contentType, upload.size, upload]      // ← the handle
);
await upload.discard();
```

Reading it back through SQL? Postgres' `encode(data, 'base64')` wraps lines at 76 characters, which the sandbox's strict base64 helpers reject — select `translate(encode(data, 'base64'), E'\n', '')`.

**Inline reads are the exception.** `text()` / `json()` / `base64()` / `extractText()` are for a config file, a small spreadsheet to inspect, a document to summarize — over `maxInlineBytes` (10 MB) they throw a `413` carrying `data.maxInlineBytes`. Anything headed for a table goes through `copyInto()`; anything headed for a column goes as a parameter.

## The handler: `downloads.create()`

```javascript
// server/export.js — GET ?format=csv|json|jsonl. Heap stays flat however many rows.
export async function GET({ request, downloads }) {
    const format = ['csv', 'json', 'jsonl'].includes(request.query.format) ? request.query.format : 'csv';
    const dl = await downloads.create({ filename: `orders.${format}` });
    await dl.fromQuery(
        `SELECT id, customer, region, total, ordered_on::text AS ordered_on FROM orders ORDER BY id`,
        [],
        { format }
    );
    return dl;      // streams as THIS response: Content-Disposition: attachment; filename="orders.csv"
}
```

`downloads.create({ filename?, contentType? })` returns a handle (`id`, `filename`, `contentType`, `size`, `expiresAt`, plus **`url`** — a single-use same-origin link). Methods, all async:

| Method | Returns | Description |
|---|---|---|
| `fromQuery(sql, params?, opts?)` | `{ rowCount }` | Stream a workspace query straight into the download. |
| `writeRows(rows, opts?)` | `true` | Append rows you already hold through a `csv` / `json` / `jsonl` encoder. Call it per batch. |
| `write(chunk)` | `true` | Append a string or byte array (any format you build yourself). |
| `end()` | handle | Seal it. The returned handle is what you `return` or `respond()` with. |
| `discard()` | `true` | Drop the staged bytes. |

`fromQuery` / `writeRows` options: `format` (`csv` | `json` | `jsonl`, default `csv`), `columns`, `header`, `delimiter`. A download created without a `contentType` takes the encoder's (`text/csv`, `application/json`, `application/x-ndjson`).

**Three ways to deliver:**

```javascript
// 1. Return it (or `return await dl.end()`) — the staged bytes become the response body
return dl;

// 2. respond() with it, then keep working in the background
const { rowCount } = await dl.fromQuery('SELECT * FROM orders');
await respond(await dl.end());
await query('INSERT INTO export_log (rows) VALUES ($1)', [rowCount]);

// 3. Hand the page a URL to navigate to — survives the handler returning
const done = await dl.end();
return { url: done.url, filename: done.filename, size: done.size };
```

Rules that matter:

- **Single-use.** The staged bytes are destroyed once served; a stale URL is `404`. If the page may fetch the same download twice, it appends `?keep=true` (the TTL reclaims it later).
- **`?inline=true`** asks the browser to render instead of save — ignored for `text/html` and `image/svg+xml`, which are always sent as attachments under a restrictive CSP (a handler picks the content type; rendering one would run app-authored markup on the Informer origin with the viewer's session).
- **Over the cap fails, never truncates.** Writing past `maxUploadBytes` fails the call with `413` and leaves the download unsealed, so a truncated file is never served as complete.
- **Auto-seal.** A download left open when the handler returns is sealed for you — background work after `respond()` still produces a complete file.
- **Cast dates in SQL** (`ordered_on::text`). The encoder stringifies what pg hands it, and a `DATE` arrives as a JS `Date`, which prints as a locale string.

## Forwarding to an integration (2026.1.3, I5-13030 build)

A staged stream can be the body of a `context.<slot>.request()` call, and an integration's response can land in one. Either way the host moves the bytes between the staging store and the upstream; the handler holds only handles. Works for **`target: integration` slots only** — `fetch()` and `target: app` slots do not take handles.

**Outbound — the handle as the body.** An upload handle in `data` is sent as the raw request body with the upload's `Content-Type` and a `Content-Length`. In `form`, the handle becomes a file part of a `multipart/form-data` body and the other fields are sent beside it.

```javascript
// Raw body — S3 presigned PUT, Drive media upload, GitHub release assets
await context.drive.request({ method: 'POST', url: '/upload/drive/v3/files?uploadType=media', data: upload });

// Multipart — Slack files, Salesforce ContentVersion, Gmail attachments
await context.slack.request({ method: 'POST', url: '/api/files.upload', form: { channels: 'C123', title: upload.filename, file: upload } });
```

`request()` returns what it always has — the parsed upstream body — and the upload is **not** consumed: an upstream failure throws the usual dependency error (`data.upstreamStatus` says what the upstream answered) and leaves the bytes staged, so the route or the page can retry with the same id. Call `discard()` once the push is known to have landed. A download handle is never a request body (`400`).

**Header ownership.** The stream describes its own bytes, so `Content-Length` (and, for `form`, the generated multipart `Content-Type` with its boundary) belong to it: setting either on the call is a `400`, not a silent override — a stale length truncates the body to nothing and a boundary-less multipart type is unparseable upstream. Every other header is yours, including `Content-Type` for a raw `data` body when you want to relabel what you are sending.

**Inbound — `into`.** Without it, a binary upstream response comes back as a base64 envelope read whole into the isolate — there is no size cap on that path (`maxInlineBytes` does not apply), so a large file is a memory cost you pay in the handler. With `into`, the host streams the upstream body into a staged stream and seals it, `request()` resolves with the sealed handle instead, and `maxUploadBytes` bounds it:

```javascript
// Upstream file → download → the browser
const dl = await downloads.create({ filename: 'statement.pdf' });
await context.sf.request({ method: 'GET', url: '/services/data/v59.0/…/VersionData', into: dl });
return dl;

// Upstream CSV → a fresh upload → COPY into a table
const report = await context.qb.request({ method: 'GET', url: '/v3/…/reports/GeneralLedger?format=csv', into: 'upload' });
await report.copyInto('staging', { format: 'csv', header: true });
await report.discard();

// A body out and a file back: `data` and `into` travel together
await context.sf.request({ method: 'POST', url: '/…/analytics/reports/00O…/instances', data: { reportMetadata: { reportFilters: [] } }, into: dl });
```

| `into` | Fills | Named |
|---|---|---|
| a download handle | that download, which must be unsealed and unwritten (`409` otherwise); `into` is terminal — it seals it | by the handle (`filename`, `contentType`), falling back to the upstream's |
| `'upload'` | a new upload, returned as a normal upload handle (`copyInto()`, a `bytea` parameter, `text()` under the cap) | after the upstream's `Content-Disposition` filename, else the last segment of the request path |

What a failure leaves behind:

- **Over `maxUploadBytes`** fails with `413` (`data.maxUploadBytes`) and never truncates — a download is put back empty and unsealed, so nothing half-written can be served; a fresh upload is discarded.
- **A short body** — fewer bytes than the `Content-Length` the upstream declared — is refused the same way, `502` with `data.declaredBytes` / `data.receivedBytes`, rather than sealed as a complete but truncated file. An `into` request asks for the bytes uncompressed so that length describes what lands; set your own `Accept-Encoding` and a compressed upstream may deliver more than it declared, which is not a failure.
- **A non-2xx upstream, or one that cannot be reached,** throws the usual dependency error and the target is released: your download is left exactly as it was — empty and unsealed, still yours to `end()` or `discard()` — and a fresh `'upload'` is discarded, so a failing call costs nothing against your staging allowance.
- **A `3xx`** counts as no body delivered: `502` with `data.upstreamStatus`. Redirects are followed as usual on a plain `into` pull, but **not** when the same call is also sending a staged body (a stream cannot be replayed onto the redirect target) — address the final URL yourself then.

## Errors

Stream failures cross the membrane as real errors with `statusCode` and `data` intact, so a handler can branch:

```javascript
try {
    const upload = await uploads.get(request.body.uploadId);
    return { lines: (await upload.text()).split(/\r?\n/).length };
} catch (err) {
    // 404 not yours · 409 not sealed · 413 over the inline cap
    return { status: err.statusCode || 500, body: { error: err.message, data: err.data || null } };
}
```

| Status | Meaning | Payload |
|---|---|---|
| `400` | An `into` target that is neither a download handle nor `'upload'`, a download handle sent as a request body, or a header the stream owns set by the caller | |
| `404` | No such stream, or it belongs to another app or user | |
| `409` | The upload has not been sealed by the page yet, a chunk arrived after sealing, or an `into` target is already complete or already holds bytes | |
| `412` | Sealing found missing chunks | `data.missing` (at most 50) — the helper resends just those, once |
| `413` | Over `maxUploadBytes` (upload, download, or an `into` fill), `maxChunkBytes`, `maxInlineBytes`, or `maxStagedBytesPerUser` | `data.<limit>` |
| `422` | A chunk's number or length disagrees with the declared geometry | |
| `429` | The viewer already holds `maxStreamsPerUser` open streams in this app | `data.maxStreamsPerUser` |
| `502` | An `into` upstream delivered a short body, or no body at all (a redirect) | `data.declaredBytes` / `data.receivedBytes`, or `data.upstreamStatus` |

## Choosing the path

| You have… | Do this | Not this |
|---|---|---|
| A CSV/TSV headed for a table | `upload.copyInto('staging')` + upsert | `text()` then `INSERT` per row |
| An image / PDF / any blob for a column | the handle as a `bytea` parameter | `base64()` into a JSON field |
| A small file to inspect or summarize (< 10 MB) | `text()` / `json()` / `extractText()` | — |
| A big result set to hand the browser | `downloads.create()` + `fromQuery()`; `return dl` | building a string and returning it as the body |
| Rows you compute in batches | `writeRows(batch, { format })` per batch, then `end()` | accumulating an array |
| A file for a link in `notify()` / `email()` | `dl.end()` → `dl.url` | — |
| A staged file to push to an integration | the handle as `data` (raw body) or a `form` field (multipart) | `base64()` into the outbound body |
| A file an integration serves | `request({ …, into: dl })` or `into: 'upload'` | reading the base64 envelope in the handler |
| A file that fits a JSON field (a few KB) | base64 in the body, `base64Decode()` / `extractText(data, type)` | staging it |

## Local development

The Vite plugin (**2.10.0+**) stands in for the harness: an in-memory store behind same-origin `/_uploads` and `/_downloads`, the page helper injected into the dev mock, the same geometry rules, statuses (`412` + `missing`, `409`, `413`, `429`) and handle shapes — an app that works here works deployed. **2.12.0+** carries phase 2: the same helper as the server (`onEvent`, `task.created`, the `412` resend, `__INFORMER__.streams`), the listing and discard routes, and forwarding through the dev integration proxy. The emulation gaps are named in errors, not papered over:

| Production | Dev server |
|---|---|
| `copyInto()` → `COPY FROM STDIN` | batched parameterized `INSERT`s through the `_sql` proxy — same rows, `INSERT` semantics and error text on a bad row |
| bytea parameter → binary bind | a `\x…` hex string (Postgres' text-format bytea input) — same rows, slower |
| `fromQuery()` → pg query stream | rows read through `query()` and encoded locally |
| `extractText()` | **unavailable** — throws a named error |
| forwarding streams host → upstream | the staged bytes ride the integration request route's base64 envelope, which holds at most ~37.5 MB (`DEV_FORWARD_MAX_BYTES`); a larger file throws a named error — test it against a deployment |
| `into` fill | bounded by `maxUploadBytes` and gated at `< 300` as production is; refuses a download handle as the body and caller-set stream headers the same way |

Nothing persists across a dev-server restart.

## Not yet

Deferred on the ticket: `upload.rows()` batch iteration in the handler, and `Range` on downloads. Forwarding a staged file to an integration shipped in the I5-13030 build (see [Forwarding to an integration](#forwarding-to-an-integration-202613-i5-13030-build)).
