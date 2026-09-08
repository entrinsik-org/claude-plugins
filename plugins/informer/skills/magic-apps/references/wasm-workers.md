# WebAssembly & Web Workers in Magic Apps

Running a WASM library — especially one that uses a Web Worker (DuckDB-WASM, sql.js, ffmpeg.wasm, pdf.js, ONNX Runtime Web) — works inside a Magic App. How much ceremony it takes depends on **which serving mode** the deployment uses; the blob-worker recipe below works in BOTH, which is why it stays the recommended pattern for portable apps.

## Two serving modes, two origins

**Per-app origins (App API v2 — Informer 2026.1.2+ with `appsBaseUrl` configured).** Each app serves from its own origin (`https://<label>.apps.…`). The frame has a REAL origin: plain `new Worker(bundledAssetUrl)` just works, and so do `localStorage`, IndexedDB, `BroadcastChannel`, and service workers. If your app targets only origin-mode deployments, you can skip the blob dance entirely — bundle the worker/wasm with Vite `?url` and construct directly.

**Path mode (deployments without per-app origins, and all older servers).** The app runs in a **sandboxed iframe without `allow-same-origin`**, so its origin is opaque (`window.location.origin === 'null'`):

- **`new Worker('https://…/worker.js')` throws** `Failed to construct 'Worker': Script at '…' cannot be accessed from origin 'null'`. An opaque-origin document can't construct a worker from an `http(s)` URL — only from a `blob:` (or `data:`) URL.
- **The fetch shim rewrites `/api/*`.** Path mode injects a shim that routes `/api/*` calls through the proxy. Your app's *own* bundled assets live under `/api/apps/{id}/view/-/assets/…`; that `/view/-/` path is carved out of the rewrite so you can `fetch()` your own assets — but only your own.

**In both modes: CDN fetches are blocked.** `connect-src` is locked down (`'self'` on an app origin, the proxy in path mode), so `fetch('https://cdn…/x.wasm')` is refused either way. This is the data-exfiltration boundary — don't widen it for convenience (see "External fetch targets"). Bundle locally regardless of mode.

A marketplace app cannot know which mode its installer runs, so unless you control the deployment, use the portable recipe:

## The pattern: bundle locally, construct the worker from a blob

**1. Bundle the worker + wasm with your app** (never a CDN). With Vite, import them as asset URLs and exclude the package from pre-bundling:

```js
// vite.config.js
export default defineConfig({
    plugins: [informer()],
    // Let Vite emit the worker/wasm as real assets (via ?url) instead of
    // trying to pre-bundle them.
    optimizeDeps: { exclude: ['@duckdb/duckdb-wasm'] }
});
```

```js
// src/duckdb.js
import * as duckdb from '@duckdb/duckdb-wasm';
import ehWasm   from '@duckdb/duckdb-wasm/dist/duckdb-eh.wasm?url';
import ehWorker from '@duckdb/duckdb-wasm/dist/duckdb-browser-eh.worker.js?url';
```

**2. Fetch the worker + wasm bytes in the MAIN frame and wrap them as blob URLs.** The main frame's `fetch` goes through the app's auth shim and the `/view/-/` carve-out, so it can read your own assets. The worker itself can't — its fetch is cross-origin from `'null'` and unauthenticated.

```js
// Fetch an own /view/-/ asset and hand it back as a blob: URL.
async function blobUrl(assetUrl, type) {
    const res = await fetch(assetUrl);
    if (!res.ok) throw new Error(`Failed to load ${assetUrl} (${res.status})`);
    return URL.createObjectURL(new Blob([await res.arrayBuffer()], { type }));
}

const workerUrl = await blobUrl(ehWorker, 'text/javascript');   // blob: worker script
const wasmUrl   = await blobUrl(ehWasm, 'application/wasm');     // blob: wasm module

const worker = new Worker(workerUrl);          // allowed: blob: inherits the doc origin
const db = new duckdb.AsyncDuckDB(new duckdb.ConsoleLogger(), worker);
await db.instantiate(wasmUrl);                 // worker fetches the blob: wasm (no network)

URL.revokeObjectURL(workerUrl);
URL.revokeObjectURL(wasmUrl);
```

Why blob URLs on both:
- The **worker** must be a `blob:` (a blob worker inherits the document's origin, so construction is allowed where an `http(s)` URL is not).
- The **wasm** is handed to the worker as a `blob:` URL so the worker never does its own cross-origin/unauthenticated fetch — it reads local bytes the main frame already fetched.

This pattern is library-agnostic. For pdf.js, set `GlobalWorkerOptions.workerPort = new Worker(blobUrl)` (built from the bundled `pdf.worker` asset) instead of pointing `workerSrc` at a CDN.

## External fetch targets (extension packs, remote data)

Some libraries auto-download from an external host at runtime — e.g. **DuckDB pulls `json`/`parquet` extensions from `extensions.duckdb.org`** the first time you call a JSON/Parquet function. That `fetch`/XHR is governed by `connect-src` and is **blocked**. Two options, tightest first:

1. **Avoid the download.** Prefer features that don't pull an extension — e.g. ingest with `read_csv_auto` (core DuckDB) instead of `read_json_auto` (needs the `json` extension). No external origin, nothing to approve, `connect-src` stays locked.
2. **Approve the origin as a `data` asset.** A tenant admin adds the URL to **Approved Resources** as an **Asset, type `data`** — this opens `connect-src`. A *Script* entry opens `script-src` and will not authorize a `fetch`. In `approved-only` CSP mode the exact URL is pinned. Use only for static, trusted hosts; `connect-src` is the exfiltration boundary.

## Loading Informer data into the engine

The worker computes locally, but the *data* comes from Informer. Load it once via a **Pattern A server route** (`server/…` → `context.<slot>.search/execute/query`) and stream it into the engine. Set the dependency's `runAs` deliberately in `informer.yaml`:

- `runAs: owner` — every viewer sees the data through the app owner's access (curated dashboard).
- `runAs: user` (default) — each viewer's own permissions / RLS apply.

Page large datasets with `search_after` (a single dataset `_search` caps at 10k rows), then ingest in one pass — e.g. serialize the rows to CSV in the browser and `CREATE TABLE t AS SELECT * FROM read_csv_auto('rows.csv', header = true)` (CSV is core; no extension download).

## Checklist

- [ ] Worker + wasm bundled with the app (Vite `?url`), **not** a CDN
- [ ] `optimizeDeps.exclude` set for the wasm package
- [ ] Worker constructed from a **blob URL** fetched in the main frame
- [ ] WASM handed to the worker as a **blob URL**, not an `http(s)` URL
- [ ] No runtime CDN/extension downloads — or the origin approved as an **Asset, type `data`**
- [ ] Informer data loaded via a Pattern A server route with an explicit `runAs`
