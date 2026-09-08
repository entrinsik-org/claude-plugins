# Entrinsik Claude Code Plugins

Claude Code plugins for Informer development.

## Installation

```
/plugin marketplace add entrinsik-org/claude-plugins
/plugin install informer@entrinsik-plugins
```

## Which Informer version

Customers run a spread of Informer versions, so the plugin does not branch by
release. Every newer feature in the skill carries the Informer release that
first shipped it: one table in `SKILL.md` (Feature floors) and an Availability
block at the top of its reference. Claude pins the target version first, reads
the table against it, and offers the fallback for anything the target does not
have. An app records its floor as `requires: { informer: '>=…' }` in
`informer.yaml`; servers from 2026.1.3 refuse a deploy below it and older ones
ignore the key.

Docs for a feature that has merged into an Informer release branch go straight
to `main`, tagged with that release, even before it ships. Docs for a feature
still on a product branch stay on a topic branch here and load with
`claude --plugin-dir plugins/informer` until the product PR merges.

Third-party marketplaces do not auto-update:

```
/plugin marketplace update entrinsik-plugins
/plugin update informer
```

## Contributing a doc for a ticket

1. The product PR names the reference it changes and the branch here that
   carries it.
2. Branch from `main`, in a worktree:
   `git worktree add ../claude-plugins-wt-<topic> -b docs/<topic> origin/main`.
3. Write from the product PR's `packages/docs` diff, its route and sandbox
   specs, and the demo app if there is one. Update every hook the skill relies
   on: the reference and its Availability block, the `SKILL.md` index row, the
   Feature floors row, the overview section, the reference-files table, and
   the bag table in `server-routes.md` when a handler helper changes.
4. Commit as `docs(magic-apps): <what> (I5-xxxxx)`, then
   `chore(informer): 5.N.0` as the last commit, moving the version in both
   plugin manifests and the stable marketplace entry. A new feature is a minor
   bump; a correction is a patch.
5. Validate and try it: `claude plugin validate plugins/informer`, then
   `claude --plugin-dir plugins/informer` and ask for something the new section
   should answer, once more with a target version below the floor to see the
   fallback.
6. PR against `main`, merged when the product PR merges into its release
   branch.

## Available Plugins

### informer

A growing collection of Informer-development skills under one plugin. Skills are addressed as `/informer:<skill-name>` and auto-load whenever the conversation touches a relevant topic (you don't have to type the slash command — mentioning Informer Apps, `informer.yaml`, widgets, agents, etc. is enough).

#### Current skills

- **`/informer:magic-apps`** — Building Informer Apps with local Vite development. Covers:
  - Bootstrap recipe (`npm create vite` + `@entrinsik/vite-plugin-informer` + `npx informer-init`)
  - The typed-slot dependency model — `context.<slot>` in server handlers, runtime binding discovery from the frontend, and the three patterns (server-handler proxy / SPA discovery / forbidden hardcoded UUIDs)
  - `informer.yaml` schema — `dependencies:` slot fields, `defaultBinding` UUID lookups, `$user.*` row-level security, modernizing legacy `access:` blocks
  - Widgets (iframe gallery cards), SQL workspace + migrations, server-side route handlers (V8 sandbox), token-gated webhooks
  - The built-in AI copilot sidebar (`openChat()`, `registerTool()`) and the in-app AI completion endpoints (`_chat`, `_completion`, `_object`)
  - Event-driven AI agents — `tools/*.js`, `emit()` chaining, cron scheduling, toolkits/assistants
  - App roles, HTML5 client-side routing, in-gallery `docs.html`, PDF export

  Structured as an orientation `SKILL.md` plus a `references/` library — Claude loads the deep references on demand when a specific topic comes up, keeping the front-door context light.

Future skills will be added under the same plugin (e.g. `/informer:datasets`, `/informer:license-manager`, `/informer:troubleshooting`).

## Using these skills with OpenAI Codex

`SKILL.md` (YAML frontmatter + markdown body + a `references/` library) is a shared format across coding agents, so the same skill content runs in OpenAI Codex with no edits. The only difference is discovery: Codex looks for skills under a `.agents/skills/` directory and installs bundled plugins from a `.agents/plugins/marketplace.json`, rather than a Claude `plugin.json`.

This repo carries the Codex equivalents of the Claude manifests alongside them, so there are two ways to consume it: a one-command marketplace install (mirrors the Claude flow above), or a manual clone-and-sync.

### Option A — install as a Codex plugin (mirrors the Claude install)

> ⚠️ **Experimental — verify against your Codex version.** These manifests were authored from the [Build plugins docs](https://developers.openai.com/codex/plugins/build) and have not been validated against a live Codex install. If the command below errors, use Option B, which needs no manifest schema to be exact.

```
codex plugin marketplace add entrinsik-org/claude-plugins
/plugins                 # in Codex CLI: browse, select "informer", install
```

The Codex marketplace lives in `.agents/plugins/marketplace.json` (repo root) and the plugin manifest in `plugins/informer/.codex-plugin/plugin.json` — the Codex analogs of `.claude-plugin/marketplace.json` and `plugins/informer/.claude-plugin/plugin.json`. Both point at the same `plugins/informer/skills/` source, so there's no content duplication.

### Option B — clone and sync the skills (no manifest dependency)

`SKILL.md` is a shared format, so the skill content runs in Codex unchanged. The source of truth stays under `plugins/informer/skills/<skill>/`, and a per-skill symlink under `.agents/skills/` points back to it:

```
.agents/skills/magic-apps -> ../../plugins/informer/skills/magic-apps
```

**Repo-level (zero setup):** clone the repo and run Codex from anywhere inside it — it scans `.agents/skills/` from the cwd up to the repo root and finds the skill through the committed symlink. Invoke it as `$magic-apps` (or `@magic-apps`), or just describe the task and let Codex match on the skill `description`.

**User-global (available in every repo):** copy the skills into your Codex home directory:

```
bash scripts/sync-codex-skills.sh --user      # → ~/.agents/skills/
```

**Symlink-hostile environments** (Windows, or a Codex build that doesn't follow symlinked skill dirs): materialize real copies in place instead of symlinks:

```
bash scripts/sync-codex-skills.sh --copy      # → ./.agents/skills/ (real files)
bash scripts/sync-codex-skills.sh             # re-create the symlinks (default)
```

The script auto-discovers every `plugins/*/skills/*/SKILL.md`, so new skills are picked up without editing it.

Each skill also carries an optional `agents/openai.yaml` (Codex display name + implicit-invocation policy). Claude Code ignores that file; the skill works in Codex from `SKILL.md` alone.

## Migrating from `magic-reports` (v3.x)

Prior versions shipped as a plugin called `magic-reports` containing two skills: `magic-apps` and a legacy `magic-reports` skill. The platform no longer distinguishes Magic Reports from Apps, so the legacy skill has been removed and the plugin has been renamed.

**Step 1 — Remove the old `magic-reports` plugin.** The marketplace no longer lists `magic-reports`, so the CLI uninstall hits a marketplace-lookup error:

> Plugin "magic-reports" not found in marketplace "entrinsik-plugins"

Use the plugin manager UI instead — it operates on locally-installed state, not the marketplace catalog:

```
/plugin
```

Open the **Installed** tab, find `magic-reports`, and uninstall it from there.

**Step 2 — Install the renamed `informer` plugin:**

```
/plugin install informer@entrinsik-plugins
```

The `magic-apps` skill keeps its name and content — only the plugin wrapper changed. After installing `informer`, the skill is addressed as `/informer:magic-apps`.
