# Entrinsik Claude Code Plugins

Claude Code plugins for Informer development.

## Installation

```
/plugin marketplace add entrinsik-org/claude-plugins
/plugin install informer@entrinsik-plugins
```

## Available Plugins

### informer (v4.0.0)

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
