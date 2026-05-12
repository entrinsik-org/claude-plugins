# Entrinsik Claude Code Plugins

Claude Code plugins for Informer development.

## Installation

```
/plugin marketplace add entrinsik-org/claude-plugins
/plugin install informer@entrinsik-plugins
```

## Available Plugins

### informer

A growing collection of Informer-development skills under one plugin. Skills are addressed as `/informer:<skill-name>` and auto-load when the conversation touches relevant topics.

Current skills:

- **`/informer:magic-apps`** — Building Informer Apps with local Vite development. Covers the bootstrap recipe, the typed-slot dependency model (`context.<slot>` in server handlers; runtime binding discovery from the frontend), `informer.yaml` manifest format, widgets, the SQL workspace, server-side route handlers, webhooks, and event-driven AI agents.

Future skills will be added under the same plugin (e.g. `/informer:datasets`, `/informer:agents`, `/informer:troubleshooting`).

## Migrating from `magic-reports` (v3.x)

Prior versions shipped as a plugin called `magic-reports` containing two skills: `magic-apps` and a legacy `magic-reports` skill. The platform no longer distinguishes Magic Reports from Apps, so the legacy skill has been removed and the plugin has been renamed:

```
# Old (v3.x — remove this)
/plugin uninstall magic-reports@entrinsik-plugins

# New (v4.0.0+)
/plugin install informer@entrinsik-plugins
```

The `magic-apps` skill keeps its name and content — only the plugin wrapper changed.
