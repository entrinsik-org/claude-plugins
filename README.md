# Entrinsik Claude Code Plugins

Claude Code plugins for Informer development.

## Installation

```
/plugin marketplace add entrinsik-org/claude-plugins
/plugin install informer@entrinsik-plugins
```

## Channels

The stable plugin tracks what has shipped. Docs for features in unreleased
Informer versions live on two integration branches, each published from this
same marketplace as its own plugin:

| Channel | Branch | Plugin | Version | Carries |
|---|---|---|---|---|
| Stable | `main` | `informer` | `5.N.0` | Docs for shipped Informer releases |
| Beta | `beta` | `informer-beta` | `5.3.0-beta.N` | The next Informer release (2026.1.3: App Channels, App Embeddings, App Streams) |
| Alpha | `alpha` | `informer-alpha` | `5.4.0-alpha.N` | Everything on beta plus the release after it (2026.2.0: warehouses and ETL, row security, semantics, app accounts) |

Alpha stacks on beta, so an alpha install already has everything beta has.
Pick the channel that matches the Informer version your app targets:

```
/plugin install informer-beta@entrinsik-plugins     # or informer-alpha@entrinsik-plugins
/plugin disable informer@entrinsik-plugins          # while testing: every channel advertises the same skill triggers
```

Channel skills are addressed as `/informer-beta:<skill-name>` and
`/informer-alpha:<skill-name>`; the namespace comes from the marketplace entry,
not the plugin manifest. Third-party marketplaces do not auto-update:

```
/plugin marketplace update entrinsik-plugins
/plugin update informer-beta                        # or informer-alpha
```

The channel entries carry no `version`, so every new commit on the branch is
an update. The prerelease suffix in `plugin.json` is the label you see in
`/plugin`, and the only way to tell which build you have, since the plugin
manager shows no commit.

Requires a Claude Code newer than 2.1.66: older builds do not understand the
`git-subdir` marketplace source and reject the whole marketplace file.

### Two channels side by side

**Per project, from the marketplace.** Install both channels once, then choose
per repo in `.claude/settings.local.json` (git-ignored, overrides user and
project scope):

```json
{
  "enabledPlugins": {
    "informer@entrinsik-plugins": false,
    "informer-beta@entrinsik-plugins": true,
    "informer-alpha@entrinsik-plugins": false
  }
}
```

Keep one channel enabled per project. Explicit invocation by prefix always
works, but which skill auto-loads when two enabled ones share a trigger
description is not defined.

**Per terminal, from checkouts.** One worktree per branch, one session per
worktree; nothing is installed and `git pull` is the update:

```
git worktree add ../claude-plugins-beta beta
git worktree add ../claude-plugins-alpha alpha
claude --plugin-dir ../claude-plugins-beta/plugins/informer     # terminal 1
claude --plugin-dir ../claude-plugins-alpha/plugins/informer    # terminal 2
```

The manifest in every branch is named `informer`, so each session's
`/informer:magic-apps` is that checkout, overriding the installed stable plugin
for that session only. This is also the route for working on the skills
themselves: validate with `claude plugin validate plugins/informer` before
pushing.

## Release flow

The marketplace manifest never changes across releases; the channel entries
point at branch names. Only versions move.

Between releases:

- A doc for the **next** release lands on `beta`: PR base `beta`, rebase-merge,
  suffix bump as the last commit. Then rebase `alpha` onto `beta`, amend
  alpha's tip bump, force-push alpha.
- A doc for the **release after** lands on `alpha` only.
- A fix to **shipped** docs lands on `main`. Then rebase `beta` onto `main` and
  `alpha` onto `beta`; already-merged commits drop out on their own.
- A feature that **slips** a release: drop its commits from `beta`, rebase
  `alpha`, re-apply them on `alpha`.

When the next Informer release goes GA:

1. Cut `release/5.3.0` from beta's tip with one commit that drops the suffix in
   both plugin manifests and the stable marketplace entry. PR to `main`, merge.
2. Point `beta` at alpha's tip, rebase it onto `main`, replace the tip bump with
   `5.4.0-beta.1`, force-push.
3. Fast-forward `alpha` to `beta`. Alpha diverges again with the first doc for
   the following release, starting `5.5.0-alpha.1`.

| Moment | `main` | `beta` | `alpha` |
|---|---|---|---|
| Now | 5.2.0 | 5.3.0-beta.N (2026.1.3) | 5.4.0-alpha.N (2026.2.0) |
| 2026.1.3 GA | 5.3.0 | 5.4.0-beta.1 (2026.2.0) | same as beta |
| First doc past 2026.2.0 | 5.3.0 | 5.4.0-beta.N | 5.5.0-alpha.1 |
| 2026.2.0 GA | 5.4.0 | 5.5.0-beta.1 | same as beta |

## Contributing a doc for a ticket

1. The product PR names the reference it changes and this repo's branch that
   carries it. Push that branch before the product PR merges.
2. Branch from the channel matching the release: `beta` for the next Informer
   version, `alpha` for the one after. A worktree keeps it out of your main
   checkout: `git worktree add ../claude-plugins-wt-<topic> -b docs/<topic> origin/beta`.
3. Write from the product PR's `packages/docs` diff, its route and sandbox
   specs, and the demo app if there is one. Update every hook the skill relies
   on: the reference itself, the `SKILL.md` index row, the overview section,
   the reference-files table, and the bag table in `server-routes.md` when a
   handler helper changes. State the version floor whenever it differs from the
   channel's release.
4. Commit as `docs(magic-apps): <what> (I5-xxxxx)`, then
   `chore(informer): 5.3.0-beta.N` as the last commit, touching only the two
   plugin manifests.
5. Validate and try it: `claude plugin validate plugins/informer`, then
   `claude --plugin-dir plugins/informer` and ask for something the new section
   should answer.
6. PR with base `beta` (or `alpha`), rebase-merge, merged when the product PR
   merges. For a beta landing, rebase `alpha` afterwards.
7. Testers run `/plugin marketplace update entrinsik-plugins` and
   `/plugin update informer-beta`. Nothing further happens at GA: the release
   commit carries the doc to `main`.

`CLAUDE.md` in this repo carries the same rules in the form Claude follows when
working here.

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
