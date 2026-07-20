---
name: marketplace-publishing
description: Publishing an Informer App to the marketplace — the tag-driven CI flow via `informer-publish`, semver release channels (stable vs beta prereleases), the CHANGELOG/release-notes convention, vendor publish keys (`lmpub_…`, self-serve from Informer GO), the `informer` block in package.json, listing screenshots (the `screenshots/` folder), pack-to-pack dependencies (`target: pack` — "Works with" another marketplace pack), and the GitHub Actions setup. Use when setting up or running marketplace publishing for an Informer App repo — anything about tagging a release, changelog/release notes, CI publishing, publish keys, listing description/screenshots, channels, or depending on another marketplace pack.
---

# Publishing an Informer App to the Marketplace

This skill covers how an Informer App repo ships **versioned releases to the Informer
marketplace**. App *development* (Vite, handlers, datasets, copilot) lives in the
`magic-apps` skill — this one is purely the **release/publish** workflow.

## The model in one breath

- The **git tag is the source of truth for the published version.** `v1.4.0` → **stable**;
  `v1.4.0-beta.1` → **beta**. Push the tag → GitHub Actions builds the app and runs
  **`informer-publish`**, which packages the app's filesystem and uploads it to the
  License Manager (the marketplace backend).
- **Channel is derived from semver.** A prerelease version (`1.4.0-beta.1` — anything with a
  `-`) publishes to the **beta** channel; a clean `X.Y.Z` publishes to **stable**. Consumers
  opt into beta per-pack; stable is the default install.
- **Release notes come from `CHANGELOG.md`** — the section matching the version, falling back
  to `## [Unreleased]`.
- **Auth is a vendor publish key** (`lmpub_…`), stored as a CI secret. It authenticates the
  publish *as the vendor account* — no Informer license or user login needed in CI.

The publishing tool ships in **`@entrinsik/vite-plugin-informer` ≥ 2.6.0-beta.1** as the
`informer-publish` bin (sibling to `informer-deploy`). Track `@latest` (or `@beta`) —
newer capabilities land in later releases, so pin forward, not back. The 2.6.0-beta.1
floor matters: earlier versions did not package `lib/` and `shared/` source dirs, so apps
with shared server-side modules published incomplete archives.

## One-time repo setup

Five things, once per app repo.

### 1. The `informer` block in `package.json` (listing metadata — repo is the source of truth)

```jsonc
{
  "informer": {
    "name": "SQL Scratchpad",
    "slug": "sql-scratchpad",            // ^[a-z0-9-]+$ — the pack's stable id within your vendor
    "shortDescription": "Interactive SQL editor with a results grid",
    "description": "Full **markdown** listing — rendered on the pack's Overview tab (headings, lists, etc.).",
    "categories": ["analytics"],         // see taxonomy below
    "requires": { "informer": ">=2026.1.0" },  // optional
    "screenshots": "screenshots"         // optional — override the screenshots directory (default `screenshots/`)
  }
}
```

`name` + `slug` are required. The **first publish creates the listing**; **every** publish then
**refreshes the listing metadata** (name, shortDescription, **description**, categories,
documentationUrl, icon, screenshots) from the repo *and* adds the new version — so editing the
`description` and re-publishing updates what consumers see (it isn't frozen at first-publish).
`description` is **markdown** and renders on the detail **Overview** tab, so make it a real
listing (overview, highlights, getting-started). Valid categories: `data-connectors`,
`analytics`, `automation`, `finance`, `hr`, `it-ops`, `compliance`. (An `informer.id` may also
be present — that's for `informer-deploy` pushing to a live instance, unrelated to publishing.)

### 2. `CHANGELOG.md` (release notes — Keep a Changelog)

```markdown
# Changelog

## [Unreleased]

### Added
- …
```

Keep `## [Unreleased]` current as you work. `informer-publish` ships the section whose
header matches the tag version (e.g. `## [1.4.0]`), else `## [Unreleased]`. See
**Release notes** below for the stable-vs-beta flow.

### 3. The publishing dependency

`informer-publish` comes from `@entrinsik/vite-plugin-informer`. For **CI it must resolve
from the registry**, not a local `file:` path — a `file:` dep won't exist on a CI runner:

```bash
npm i -D @entrinsik/vite-plugin-informer@latest   # or @beta to track prereleases
```

### 4. The publish key + env

Two values, supplied as env (CI secrets, or a gitignored `.env` for local testing):

| Var | Value |
|---|---|
| `INFORMER_MARKETPLACE_URL` | Base URL of the License Manager cloud-api. The CLI appends `/packs/publish`. For a direct LM that's `https://<lm-host>/cloud-api`; behind the public gateway it's the gateway root (e.g. `https://api.informer.cloud`). Not secret. |
| `INFORMER_PUBLISH_TOKEN` | Your vendor publish key, `lmpub_…` (see **Publish keys** below). Secret. |

### 5. The GitHub Actions workflow (`.github/workflows/publish.yml`)

```yaml
name: Publish to Marketplace
on:
  push:
    tags: ['v*']            # v1.4.0 → stable, v1.4.0-beta.1 → beta (channel derived server-side)
jobs:
  publish:
    runs-on: ubuntu-latest
    environment: marketplace   # holds the secret/variable; add a v* deployment-tag rule
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22 }
      - run: npm ci
      - run: npm run build
      - run: npx informer-publish
        env:
          INFORMER_MARKETPLACE_URL: ${{ vars.INFORMER_MARKETPLACE_URL }}
          INFORMER_PUBLISH_TOKEN: ${{ secrets.INFORMER_PUBLISH_TOKEN }}
          # GITHUB_REF_NAME / GITHUB_SHA / GITHUB_REPOSITORY / GITHUB_RUN_ID are injected automatically
```

Recommended GitHub config: a **`marketplace` Environment** (Settings → Environments) with a
**deployment tag rule limiting it to `v*`** (so the publish key is only exposed on real
release tags), the token as an **environment secret**, and the URL as an **environment
variable**. Optionally add **required reviewers** to gate stable publishes.

## Versioning & channels

The tag *is* the version and the channel:

| Tag | Published version | Channel |
|---|---|---|
| `v1.4.0` | `1.4.0` | **stable** |
| `v1.4.0-beta.1` | `1.4.0-beta.1` | **beta** (prerelease) |
| `v2.0.0-rc.1` | `2.0.0-rc.1` | **beta** (any prerelease ⇒ beta) |

`informer-publish` resolves the version from the tag (`GITHUB_REF_NAME`, leading `v`
stripped), then `--version <x>`, then `package.json`'s `version`. The **server** derives the
channel from the version, so you never pass a channel flag.

## Release notes (the changelog flow)

The split that works well in practice — it maps to the channel ceremony:

- **Beta = low ceremony.** Keep `## [Unreleased]` current as you work; tag `v…-beta.N` and the
  beta ships the cumulative `Unreleased` notes. No promotion needed.
- **Stable = reviewed.** When cutting `v1.4.0`, **promote** `## [Unreleased]` → `## [1.4.0]` in
  the same commit you tag. CI then matches `## [1.4.0]` exactly. Reset `Unreleased` to empty
  for the next cycle.

Claude can draft/maintain `Unreleased` from your commits before you push — ask it to "update
the changelog for these changes."

## Screenshots

Drop promotional images in a **`screenshots/`** directory at the repo root — `informer-publish`
uploads them **ordered by filename**, and they render as a strip (with a click-to-zoom
lightbox) at the top of the pack's **Overview** in the consumer surface. PNG / JPG / WebP / GIF.

- Override the directory with `informer.screenshots` in `package.json` (e.g. `"assets/shots"`).
- Like the description, screenshots are **listing-level** (not per-version): the latest publish
  defines what consumers see. A publish that **uploads** screenshots **replaces** the set; a
  publish with **none** leaves the existing set untouched (so there's no accidental wipe — and,
  for now, no clear-all via publish).

## Pack dependencies (`target: pack` — "Works with" another pack)

If your app calls the server routes of **another marketplace pack** (yours or a third
party's), don't declare a generic `target: app` slot — declare a **pack dependency** in
`informer.yaml`. You pin the pack by slug and version range; the consumer's instance
resolves the pin to their locally-installed copy by itself:

```yaml
dependencies:
  kanban:
    target: pack
    pack: informer-kanban          # the pack's marketplace slug
    requires: ">=1.2 <2"           # semver range your code supports
    description: The Kanban board this dashboard drives
```

Handler code calls it like an app slot — `await context.kanban.request({ method, url,
params, data })` — one hop deep, through the target's own routes and roles.

What the pin buys you over `target: app`:

- **The installer consents, they never pick.** The slot shows the pinned pack's install
  state with a single **Connect** action (plus consent dialog) — no browsing for the right
  app, no mis-binding. If the pack isn't installed, the panel routes them to the
  marketplace to get it.
- **Resolution is late and self-healing** — stable install preferred over beta; the
  consumer uninstalling/reinstalling the target pack doesn't break the slot.
- **The version gate fails hard.** An installed version outside `requires` makes calls
  throw a 422 with `errorCode: 'pack_dependency_out_of_range'` (carrying
  `installedVersion` and `requires`) instead of answering wrongly. Matching is
  prerelease-inclusive, so a beta install like `1.4.0-beta.1` satisfies `>=1.2 <2`.
- **The pin is author-owned.** Installers can't re-point it; only your redeploy/republish
  changes `pack`/`requires`. (`defaultBinding` is rejected on pack slots — the pin *is*
  the identity.)

Publisher discipline for `requires`:

- Treat it like any dependency range: **widen it in a release when you've verified the new
  target major**, and ship that as your own version bump. Consumers who update the target
  pack past your range get the clean 422 until you publish support.
- Note the compatibility in your listing `description` and `CHANGELOG.md` ("Works with
  Informer Kanban 1.2+") — the range in the manifest enforces; the listing communicates.

**Local dev:** there's no marketplace install to resolve against in dev, so point the slot
at your locally-installed copy via the vite plugin (≥ 2.6.0-beta.2):

```javascript
// vite.config.js
informer({
    devBindings: {
        kanban: { app: 'admin:kanban' }   // your local copy of the pack's app
    }
})
```

## Publishing — the actual steps

```bash
# Beta (safe — goes to the beta channel):
git tag -a v1.4.0-beta.1 -m "beta.1"
git push origin v1.4.0-beta.1

# Stable (promote Unreleased → [1.4.0] first, commit, then):
git tag -a v1.4.0 -m "v1.4.0"
git push origin main v1.4.0
```

Pushing the `v*` tag triggers the workflow → build → `informer-publish` → the LM stores the
versioned artifact under your vendor's listing. The pushed commit must contain the workflow
file, so push the branch before/with the tag. (The `-m` is just a tag label — notes come from
`CHANGELOG.md`, not the tag message.)

**Local dry run** (against a reachable LM, with a `.env`): `npm run build && npx
informer-publish --version 0.1.0-beta.0`.

## Publish keys (vendor auth)

A publish key is an **account-scoped** credential — it publishes *as the vendor account*,
distinct from a personal API token (`lm_…`, which authenticates as a user and is **not**
accepted by the publish route). Keys are prefixed **`lmpub_`** and shown **once** at creation.

- **Getting one (self-serve):** in **Informer GO → Publish → Publish keys**, click *Create key*,
  name it, and copy the `lmpub_…` value — it's shown **once**. Store it as the
  `INFORMER_PUBLISH_TOKEN` CI secret. List and revoke from the same place. The key is scoped to
  *your* account (the LM derives it from your license), so no admin involvement is needed.
- **Getting one (admin):** an Entrinsik admin/staff can also mint one for any account in the
  License Manager (`POST /api/packs/publish-keys` with `{ accountId, name }`).
- **Scope:** per vendor account — one key can publish any of that vendor's packs. The pack's
  `vendorId` is resolved from the key, so whatever account the key belongs to owns the listing.

## What `informer-publish` does (under the hood)

1. **Assembles the app file set** — the same files `informer-deploy` pushes: the Vite `dist/`
   output (at the library root), `informer.yaml` (declare host-API grants in its
   `access.apis:` block — `data-access.yaml` is deprecated and ignored by the deploy
   pipeline), and the `server/`, `tools/`, `migrations/`, `webhooks/`, `lib/`, `shared/`
   source trees (dotfiles, `node_modules`, and `*.test.js` are excluded). Shared with
   `informer-deploy` so a published artifact is byte-identical to a normal deploy.
2. **Packages** them into a `.tgz` of the app's filesystem.
3. **Reads** version (tag/arg/package.json), release notes (`CHANGELOG.md`), listing metadata
   (`package.json` `informer` block), an icon (`favicon.svg` if present), **screenshots**
   (`screenshots/`), and **provenance** (`GITHUB_REPOSITORY` / `GITHUB_SHA` / `GITHUB_RUN_ID`).
4. **POSTs** a multipart request to `${INFORMER_MARKETPLACE_URL}/packs/publish` (archive + icon +
   screenshot parts + metadata fields) with the `lmpub_` key as a Bearer token.

## Gotchas

- **`INFORMER_MARKETPLACE_URL` includes the cloud-api root.** The CLI appends `/packs/publish`
  — so the value must already resolve there (`…/cloud-api` for a direct LM; the gateway root
  if one fronts it). A wrong base shows up as a 404 on publish.
- **CI needs the registry dep, not `file:`.** A local `file:../…` path resolves for dev but
  not on a CI runner — switch to a published version before relying on the workflow.
- **`lm_` vs `lmpub_`.** A `401 Invalid token structure` on publish almost always means a
  personal API token (`lm_…`) was used instead of a vendor publish key (`lmpub_…`).
- **Beta-only listings are normal.** A pack can have only beta versions (no stable yet) — the
  consumer surface handles "Try beta" with no stable to install.
- **Version uniqueness.** Re-publishing the same version 409s — bump the tag.
- **Re-running a failed workflow re-reads secrets** at re-run time; it doesn't cache the token.
  A "looks cached" symptom is usually a repo-vs-environment secret-scope mismatch.
