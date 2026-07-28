---
name: marketplace-publishing
description: Publishing an Informer App to the marketplace — the tag-driven CI flow (`informer-ci` for keyless GitHub OIDC publishing to one or more marketplaces, `informer-publish` for key-based publishing anywhere), trusted publishers and the `INFORMER_MARKETPLACES` list, semver release channels (stable vs beta prereleases), the CHANGELOG/release-notes convention, vendor publish keys (`lmpub_…`, self-serve from Informer GO), the `informer` block in package.json, listing screenshots (the `screenshots/` folder), pack-to-pack dependencies (`target: pack` — "Works with" another marketplace pack), the pack's published API contract (the frozen per-version `openapi.json`, the listing's Integrate tab, and the public-API-changed-without-a-major-bump publish warning), and the GitHub Actions setup. Use when setting up or running marketplace publishing for an Informer App repo — anything about tagging a release, changelog/release notes, CI publishing, trusted publishing, OIDC, publishing to several License Managers, publish keys, listing description/screenshots, channels, depending on another marketplace pack, or a pack's public API surface at publish time.
---

# Publishing an Informer App to the Marketplace

This skill covers how an Informer App repo ships **versioned releases to the Informer
marketplace**. App *development* (Vite, handlers, datasets, copilot) lives in the
`magic-apps` skill — this one is purely the **release/publish** workflow.

## The model in one breath

- The **git tag is the source of truth for the published version.** `v1.4.0` → **stable**;
  `v1.4.0-beta.1` → **beta**. Push the tag → GitHub Actions builds the app and runs
  **`informer-ci`**, which packages the app's filesystem and uploads it to each configured
  License Manager (the marketplace backend).
- **Channel is derived from semver.** A prerelease version (`1.4.0-beta.1` — anything with a
  `-`) publishes to the **beta** channel; a clean `X.Y.Z` publishes to **stable**. Consumers
  opt into beta per-pack; stable is the default install.
- **Release notes come from `CHANGELOG.md`** — the section matching the version, falling back
  to `## [Unreleased]`.
- **Two commands, two auth models. Pick by where you're running.**

| | `informer-ci` | `informer-publish` |
|---|---|---|
| Runs in | GitHub Actions only | anywhere — locally, GitLab, Jenkins, Actions |
| Auth | GitHub OIDC — **no stored credential** | vendor publish key (`lmpub_…`) |
| Targets | every URL in `INFORMER_MARKETPLACES` | the one `INFORMER_MARKETPLACE_URL` |

  **Prefer `informer-ci` in GitHub Actions.** It mints a short-lived OIDC token *per
  marketplace*, so nothing long-lived sits in the repo and a token minted for one License
  Manager can't be replayed against another. Each LM must list the repository as a
  **trusted publisher** before it will accept one (see below).

  `informer-publish` is not deprecated — it is the only option outside GitHub Actions,
  where no OIDC endpoint exists. Keep it for local publishes and other CI.

Both ship in **`@entrinsik/vite-plugin-informer`** (sibling bins to `informer-deploy`).
Track `@latest` — newer capabilities land in later releases, so pin forward, not back. Two
floors matter: **≥ 2.6.0-beta.1** for `informer-publish` (earlier versions did not package
`lib/` and `shared/`, so apps with shared server-side modules published incomplete
archives), and **≥ 2.7.0** for `informer-ci`, which did not exist before.

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

Both `informer-ci` and `informer-publish` come from `@entrinsik/vite-plugin-informer`. For
**CI it must resolve from the registry**, not a local `file:` path — a `file:` dep won't
exist on a CI runner:

```bash
npm i -D @entrinsik/vite-plugin-informer@latest
```

`informer-ci` needs **≥ 2.7.0**, which is what `@latest` resolves to. Check with `npm view
@entrinsik/vite-plugin-informer version` if `npx informer-ci` reports an unknown command —
an older pin has no such bin, and npx then fails with an npm E404 rather than a useful
message (the name is unclaimed on public npm, so there is nothing to fall back to).

### 4. Where you publish, and how the LM knows it's you

**For GitHub Actions (`informer-ci`) — one variable, no secrets.**

| Var | Value |
|---|---|
| `INFORMER_MARKETPLACES` | The marketplaces to publish to: one cloud-api base URL per line (a JSON array or a comma-separated list also parse). Not secret — make it a repo **Variable**, not a secret. |

The value is the URLs alone — one per line, no variable name inside it:

```
https://lm.example.com/cloud-api
https://partner-lm.example.com/cloud-api
```

Then **register the repository as a trusted publisher on each License Manager** in that
list. A token proves *which repo you are*; the trusted-publisher record is what says which
vendor account that repo may publish as. One record per (LM, repository), so a second repo
publishing to the same LM needs its own.

**Registration is two steps, and the first one alone cannot publish.** `POST
/packs/trusted-publishers` creates a **pending** binding and returns a one-time
verification code (`lmtpv_…`). To activate it, a workflow *in that repository* mints an
OIDC token with **the code as its audience** and POSTs it as `{"token": "…"}` to
`/cloud-api/packs/trusted-publishers/_verify`. Only then will that LM accept a publish.

The handshake exists because either half alone proves nothing: whoever registered knows the
code but can't mint a token from inside the repo, and the repo's CI can't mint that audience
without being given the code. Only the intersection passes — which is also what lets the
real owner reclaim a name someone else registered first, since a pending squat is inert.

A one-off verification job, deleted once it has run:

```yaml
name: Verify trusted publisher
on: { workflow_dispatch: { inputs: { code: { required: true }, lm: { required: true } } } }
permissions: { id-token: write }
jobs:
  verify:
    runs-on: ubuntu-latest
    steps:
      - name: Mint and redeem
        run: |
          TOKEN=$(curl -sH "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
            "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=${{ inputs.code }}" | jq -r .value)
          curl -fsS -X POST "${{ inputs.lm }}/packs/trusted-publishers/_verify" \
            -H 'content-type: application/json' -d "{\"token\":\"$TOKEN\"}"
```

**For anywhere else (`informer-publish`) — two values**, as env (CI secrets, or a
gitignored `.env` for local testing):

| Var | Value |
|---|---|
| `INFORMER_MARKETPLACE_URL` | Base URL of the License Manager cloud-api. The CLI appends `/packs/publish`. For a direct LM that's `https://<lm-host>/cloud-api`; behind the public gateway it's the gateway root (e.g. `https://api.informer.cloud`). Not secret. |
| `INFORMER_PUBLISH_TOKEN` | Your vendor publish key, `lmpub_…` (see **Publish keys** below). Secret. |

### 5. The GitHub Actions workflow (`.github/workflows/publish.yml`)

```yaml
name: Publish to Marketplaces
on:
  push:
    tags: ['v*']            # v1.4.0 → stable, v1.4.0-beta.1 → beta (channel derived server-side)
  # REQUIRED for publishing a tag that never reached a marketplace — by Studio,
  # or `gh workflow run --ref v1.4.0`. A dispatch runs the workflow FROM the ref
  # it targets, so the trigger has to be present in the tag being published;
  # GitHub answers 422 "does not have workflow_dispatch trigger" otherwise, and
  # a tag cut without it can never publish itself.
  workflow_dispatch:
    inputs:
      marketplaces:
        description: 'Space-separated subset of marketplace URLs. Blank = all of INFORMER_MARKETPLACES.'
        required: false

permissions:
  contents: read
  id-token: write           # REQUIRED — without it no OIDC token endpoint is injected

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version: 22, cache: npm }
      - run: npm ci
      - run: npm run build
      - name: Publish
        env:
          INFORMER_MARKETPLACES: ${{ vars.INFORMER_MARKETPLACES }}
          MARKETPLACES_INPUT: ${{ github.event.inputs.marketplaces }}
          # GITHUB_REF_NAME / GITHUB_SHA / GITHUB_REPOSITORY / GITHUB_RUN_ID are injected automatically
        run: |
          ARGS=""
          for m in $MARKETPLACES_INPUT; do ARGS="$ARGS --marketplace $m"; done
          npx informer-ci $ARGS
```

That is the whole workflow — no secrets, no matrix. **Keep it that way.** Fan-out, per-target
token minting, and reporting live inside `informer-ci` on purpose: the less logic the
workflow carries, the less there is to drift, and fixing the publish recipe becomes an npm
release instead of a pull request into every repo that copied it. (The `for` loop above is
the one concession — it exists only to turn a dispatch input into repeated `--marketplace`
flags, and it's inert on a tag push.) Resist moving the marketplace list into a job matrix —
a per-target OIDC audience can't be expressed cleanly in YAML, and you'd lose the replay
protection.

`informer-ci` builds the app **once** and sends **the same file set** to every marketplace,
so a version's contents can't vary between them. (The upload archive is re-packed per
target, so the tarball bytes differ — tar mtimes — but the files inside do not.) One target
failing does not stop the others; the step exits non-zero if any failed, and writes a
per-marketplace table to the job summary.

There is **no retry** on a failed target: a transient blip fails that marketplace and the
run. Re-dispatch with `--marketplace` scoped to the ones that failed (see **Re-publish to a
subset** below) — the successful targets already have the version and would 409 anyway.

**Still using a publish key in Actions?** Keep the old shape — `npx informer-publish` with
`INFORMER_MARKETPLACE_URL` + `INFORMER_PUBLISH_TOKEN`, ideally behind a `marketplace`
Environment with a `v*` deployment-tag rule so the key is only exposed on real release tags.
Migrating is a one-line swap to `informer-ci` plus the `id-token: write` permission.

## After a publish: visibility and review

A successful publish does not necessarily put a version on the public shelf. Two independent
things decide what happens next.

**Packs are private by default.** A pack created by a first publish is **private** —
invite-only distribution, visible to accounts you grant access to. That's the state most
packs stay in, and it's why "I published and can't find it in the marketplace" is usually
not a failure at all.

**Public packs go through submission review.** Admission is decided by the pack's
visibility, not by who published it:

| Pack visibility | A newly published version lands as |
|---|---|
| **private** | `approved` — no queue |
| **public** | `pending` — queued for review |

Flipping a pack from private to public **re-queues every version** that was admitted while
it was private. So the review step usually shows up at the moment you go public, not at the
moment you publish, which is a surprising place to meet it for the first time.

A vendor on the auto-review policy (unrelated to OIDC "trusted publishers", despite the
name) doesn't skip the queue on a public pack — their versions still land `pending` and are
auto-approved by a clean automated pass. Trust swaps the human gate for the machine one; it
doesn't remove the gate.

None of this changes the publish commands or their exit codes: a version that publishes
successfully and sits `pending` is a green build.

## Versioning & channels

The tag *is* the version and the channel:

| Tag | Published version | Channel |
|---|---|---|
| `v1.4.0` | `1.4.0` | **stable** |
| `v1.4.0-beta.1` | `1.4.0-beta.1` | **beta** (prerelease) |
| `v2.0.0-rc.1` | `2.0.0-rc.1` | **beta** (any prerelease ⇒ beta) |

Both commands take **`--version <x>` first**, then the tag (`GITHUB_REF_NAME`, leading `v`
stripped). An explicit flag therefore wins in CI too, which is what you want when
re-publishing a specific version by hand. The **server** derives the channel from the
version, so you never pass a channel flag.

They differ on what happens when neither is available — when the ref is a branch rather than
a version tag:

- **`informer-ci` refuses**, naming the ref: `this run's ref is branch "main" — not a version
  tag`. There is no `package.json` fallback. Publishing to several marketplaces off an
  ambiguous version is not a thing it will guess at; pass `--version` or run against a tag.
- **`informer-publish` falls back** to the `package.json` version and says so on stderr.

Neither can mispublish a branch's code under a stale version number — they share one
`isVersionTag` predicate so the two can't drift. What you get instead is a red build, so if
a dispatch fails with the message above, the fix is to target the tag (or pass `--version`),
not to add a fallback.

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

## Your pack's public API (the Integrate surface + compatibility warnings)

If your app marks routes public (`config.api = 'public'` on a `server/` handler — authoring
mechanics live in the **magic-apps** skill, `references/app-api.md`), publishing gives that
surface a life of its own:

- **The contract is frozen per version.** `informer-publish` (≥ 2.6.0-beta.3) generates an
  `openapi.json` from your handlers — routes, params, schemas, roles, your public markers,
  and your root `API.md` guide — and ships it in the archive. The marketplace stores it
  with the version, alongside the changelog.
- **It renders on your listing's Integrate tab** — the author guide, the public routes, and
  copy-paste on-ramps (`target: pack` stanza, `devBindings`, a typed handler call). Visible
  *pre-install*: your API is a reason to install. Apps with no public routes simply have no
  Integrate surface.
- **Breaking the public surface without a major bump warns at publish.** The marketplace
  diffs the new version's public operations against the most recent prior version that
  shipped a contract. A removed public operation (or one that lost its marker), a removed
  parameter, or a parameter that became required — without the major version increasing —
  comes back as a `warnings` entry in the publish response, printed by `informer-publish`:

  > `public API changed incompatibly since v1.2.0 without a major version bump (v1.3.0): public operation POST /issues was removed — apps built against the documented surface may break; bump the major version or restore compatibility`

  It's **advisory, never a block** — prereleases of one base version (`1.2.0-beta.12` →
  `1.2.0-beta.13`) are exempt (that's what prereleases are for), but crossing base versions
  is checked even between betas. Internal (unmarked) routes never trigger it — that's the
  point of marking a public surface: everything else stays refactorable.

This is the enforcement half of the `requires` discipline above: consumers pin
`requires: ">=1.2 <2"` trusting your major to mean something; the publish warning is what
keeps that promise honest from your side.

## Publishing — the actual steps

```bash
# Beta (safe — goes to the beta channel):
git tag -a v1.4.0-beta.1 -m "beta.1"
git push origin v1.4.0-beta.1

# Stable (promote Unreleased → [1.4.0] first, commit, then):
git tag -a v1.4.0 -m "v1.4.0"
git push origin main v1.4.0
```

Pushing the `v*` tag triggers the workflow → build → `informer-ci` → each LM stores the
versioned artifact under your vendor's listing. The pushed commit must contain the workflow
file, so push the branch before/with the tag. (The `-m` is just a tag label — notes come from
`CHANGELOG.md`, not the tag message.)

**Publishing a tag that never reached a marketplace** — say a repo published to one LM
before a second was added, or an app onboarded after it was already tagged. Dispatch the
workflow **against the tag**:

```bash
gh workflow run "Publish to Marketplaces" --ref v1.4.0
```

`GITHUB_REF_NAME` is the tag, so the version resolves exactly as a tag push would and the
build comes from that tag's tree — you publish the code that version actually is.

**The tag has to contain the workflow file *with its `workflow_dispatch` trigger*.** A
dispatch runs the workflow from the ref it's dispatched against, so both have to be present
in the tag itself — a workflow that only has `on: push` is not dispatchable, and GitHub
answers 422 (`does not have workflow_dispatch trigger`). Adding the trigger on the branch
today does nothing for tags already cut.

So a tag from before CI was set up can't publish itself. Cut a fresh tag containing the
workflow, or publish that exact version locally with `informer-publish`. Dispatching from a
branch is not a workaround — `informer-ci` refuses a non-tag ref outright (see **Versioning
& channels**), so you get a red build rather than a wrong publish.

**Re-publish to a subset** of marketplaces — `informer-ci` takes `--marketplace` repeatedly,
and the flags replace the configured list entirely. Pass it through the dispatch input:

```bash
gh workflow run "Publish to Marketplaces" --ref v1.4.0 \
   -f marketplaces="https://lm.example.com/cloud-api"
```

**Publishing by hand** (against a reachable LM, with a `.env` holding a publish key): `npm
run build && npx informer-publish --version 0.1.0-beta.0`. Useful when CI is down — but it
consumes the version number, so CI can't republish the same one afterwards (it 409s).

## Trusted publishers (keyless CI auth)

A trusted publisher is the authorization half of OIDC publishing: **(License Manager,
repository) → vendor account.** Nothing is stored in the repo; the repository's identity is
asserted by a token GitHub signs and the LM verifies against GitHub's public keys.

- **What the LM checks**, in order: the token is signed by GitHub Actions and unexpired; its
  audience matches that marketplace; its `repository` claim has a **verified**
  trusted-publisher record; and any narrowing on that record holds. Only then does it
  resolve the vendor account and publish.
- **The audience check is not optional, and it fails closed.** An LM that hasn't been
  configured with its own URL (`trustedPublisherAudience`) doesn't skip the check — it
  refuses OIDC publishing outright with a 503 telling you to use a publish key. Accepting
  tokens without audience binding would make any token a bound repo mints *for a third
  party* replayable against that marketplace.
- **The `repository` claim is `owner/repo`** — no `.git`, no URL — and is matched
  **case-insensitively** (lowercased on registration and again at verification), so a pasted
  `Informer-Apps/Studio` binds the repository it names. Getting the *shape* wrong still
  reads as "not a trusted publisher" rather than as a typo.
- **Per marketplace.** Publishing to three LMs means three records, one on each. They are
  independent: revoking on one does not touch the others.
- **A verified `(issuer, repository)` binding is globally unique** — across *all* vendor
  accounts on that LM, not just yours. A repository publishes as exactly one vendor;
  registering one that's already bound returns a 409 naming the repository (and nothing
  about who holds it).
- **The default scope is the whole repository — narrow it if that's too wide.** Without
  narrowing, anyone who can run *any* workflow in that repo can publish as that vendor, so
  treat repo write access as equivalent to holding a publish key. See below.
- **Revoking** is deleting the record on that LM. It takes effect on the next publish; there
  is no key to rotate or leak.

### Narrowing a grant

A binding takes three optional fields at registration, enforced at both verification and
publish time. They cost one line each and shrink the blast radius considerably:

| Field | Binds the grant to | Matched against |
|---|---|---|
| `workflowRef` | one workflow file | the token's `job_workflow_ref` |
| `environment` | one deployment environment | the token's `environment` |
| `packId` | a single pack | the pack being published |

`workflowRef` takes either `.github/workflows/publish.yml` (this repo's own workflow) or a
full `owner/repo/.github/workflows/x.yml` for a reusable workflow living elsewhere — the
token's `job_workflow_ref` names the workflow's *own* repo, so the bare form is wrong for
that case. Pinning the workflow, an environment, or both collapses the grant from "anyone
who can run CI here" to the release path you actually trust — the same claims PyPI and npm
bind. If you use `environment`, the publish job needs a matching `environment:` key, and
that environment is where you'd add a `v*` deployment-tag rule.

## Publish keys (vendor auth)

Publish keys remain the auth for `informer-publish` — local publishing and any CI that
isn't GitHub Actions. In GitHub Actions, prefer a trusted publisher and store no key at all.

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

## What the publish commands do (under the hood)

`informer-ci` is `informer-publish` plus target resolution and token minting — they share
one implementation of the steps below, so the file set is the same whichever ships it.
`informer-ci` additionally: parses `INFORMER_MARKETPLACES` (JSON, newlines, or commas;
duplicates and trailing-slash variants collapse), assembles the payload **once**, then for
each target mints an OIDC token with that marketplace as the `audience` and publishes,
collecting per-target results for the job summary and the exit code.

The shared steps:


1. **Assembles the app file set** — the same files `informer-deploy` pushes: the Vite `dist/`
   output (at the library root), `informer.yaml` (declare host-API grants in its
   `access.apis:` block — `data-access.yaml` is deprecated and ignored by the deploy
   pipeline), and the `server/`, `tools/`, `migrations/`, `webhooks/`, `lib/`, `shared/`
   source trees (dotfiles, `node_modules`, and `*.test.js` are excluded). Shared with
   `informer-deploy` so a published artifact carries the same files as a normal deploy.
2. **Generates the API contract** (plugin ≥ 2.6.0-beta.3) — builds `openapi.json` from the
   `server/` handlers (a root `API.md` becomes its guide text) and adds it to the file set;
   the marketplace freezes it per version and renders the listing's **Integrate** tab from it.
   An app with no `server/` routes skips this; a handler that can't be imported degrades to
   skeleton routes with a console warning, never a lost publish.
3. **Packages** them into a `.tgz` of the app's filesystem.
4. **Reads** version (tag/arg/package.json), release notes (`CHANGELOG.md`), listing metadata
   (`package.json` `informer` block), an icon (`favicon.svg` if present), **screenshots**
   (`screenshots/`), and **provenance** (`GITHUB_REPOSITORY` / `GITHUB_SHA` / `GITHUB_RUN_ID`).
5. **POSTs** a multipart request to `<marketplace>/packs/publish` (archive + icon + screenshot
   parts + metadata fields), Bearer-authenticated with either the OIDC token (`informer-ci`)
   or the `lmpub_` key (`informer-publish`).

## Gotchas

- **Missing `id-token: write`.** The single most common first-setup failure. Without that
  permission the runner injects no token endpoint and `informer-ci` stops immediately,
  naming the missing block. It has to be on the job (or workflow) that runs the publish.
- **Missing `workflow_dispatch`, discovered far too late.** Without it in `on:`, a tag can
  only ever publish by being pushed — `gh workflow run` and Studio's Publish button both get
  a 422 (`does not have workflow_dispatch trigger`). What makes this expensive is *when* you
  find out: a dispatch runs the workflow from the ref it targets, so **adding the trigger
  today does nothing for tags already cut**. Those can only be published locally with
  `informer-publish`, or by tagging a fresh version that contains it. Put it in from the
  start even if you never expect to dispatch.
- **"… is not a trusted publisher on this marketplace."** The token verified fine; that LM
  just has no record for this repository. Add one there — and check the value is in
  `owner/repo` form (case doesn't matter; shape does).
- **"… is registered as a trusted publisher but not yet verified."** A *different* error
  with a different fix, and the most likely place to strand a first setup. The binding
  exists but is still pending — run the verification step from the repo's CI (see **Where
  you publish**). Registering *again* is the wrong move: it returns the same pending binding,
  not a working one.
- **"GitHub OIDC trusted publishing is not enabled on this marketplace" (503).** That LM has
  no `trustedPublisherAudience` configured, so it refuses OIDC publishing entirely rather
  than skipping the audience check. Nothing to fix on your side — ask the LM's operator to
  configure it, or publish to that one with a key.
- **"… is already registered as a trusted publisher" (409).** A verified binding for that
  repository already exists *on that LM under some account* — the binding is globally
  unique, and the error deliberately won't say whose it is. If it's yours on another account,
  delete it there first.
- **`http://` marketplace URLs are rejected.** `INFORMER_MARKETPLACES` entries must be
  `https:` — the URL is both the OIDC audience and the endpoint that receives the token, so
  plaintext would put a publishing credential on the wire. Loopback (`localhost`,
  `127.0.0.0/8`, `[::1]`) is exempt for local development. An on-prem LM served over plain
  http fails at parse time with `Marketplace URL must be https`, before anything is minted.
- **`informer-ci` outside GitHub Actions** can't work — no OIDC endpoint exists. Locally, or
  on GitLab/Jenkins, use `informer-publish` with a publish key.
- **A repo variable, not a secret.** `INFORMER_MARKETPLACES` holds URLs, nothing sensitive.
  Stored as a secret it still works, but it's needlessly awkward to read and edit.
- **`INFORMER_MARKETPLACE_URL` includes the cloud-api root.** The CLI appends `/packs/publish`
  — so the value must already resolve there (`…/cloud-api` for a direct LM; the gateway root
  if one fronts it). A wrong base shows up as a 404 on publish.
- **CI needs the registry dep, not `file:`.** A local `file:../…` path resolves for dev but
  not on a CI runner — switch to a published version before relying on the workflow.
- **`lm_` vs `lmpub_`.** A `401 Invalid token structure` on publish almost always means a
  personal API token (`lm_…`) was used instead of a vendor publish key (`lmpub_…`).
- **Beta-only listings are normal.** A pack can have only beta versions (no stable yet) — the
  consumer surface handles "Try beta" with no stable to install.
- **"It published but it isn't on the shelf."** Usually not a failure. New packs are
  **private** by default, and on a **public** pack every version lands `pending` for review
  (see **After a publish**). Check the pack's visibility and the version's review status
  before re-publishing — the version number is already consumed, so a retry just 409s.
- **Version uniqueness.** Re-publishing the same version 409s — bump the tag.
- **Re-running a failed workflow re-reads secrets** at re-run time; it doesn't cache the token.
  A "looks cached" symptom is usually a repo-vs-environment secret-scope mismatch.
