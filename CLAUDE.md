# CLAUDE.md

Skills for Informer development, published as one Claude Code plugin
(`plugins/informer`). Skills live under `plugins/informer/skills/<skill>/`, each
an orientation `SKILL.md` plus a `references/` library. `README.md` is the human
guide to installing, versions, and contributing; this file is the working rules.

## One branch, tagged by Informer release

Customers run a spread of Informer versions, so a feature's floor is part of
its documentation, never of a branch. Everything lives on `main`.

- Every newer feature carries the Informer release that first shipped it, in
  two places: the Feature floors table in `SKILL.md`, and the Availability
  block at the top of its reference (floor, how to feature-detect, what to do
  below it). A later addition to an existing feature carries the floor on its
  own row or sentence, bold, as `**2026.1.4+**`.
- Confirm the release from the product PR's base branch
  (`gh pr view <n> --json baseRefName` in the i5 repo) or ask. Never infer it
  from git history. If the release slips, the tag changes; nothing moves.
- Docs for a feature merged into an Informer release branch go to `main`,
  tagged, even before the release ships. Docs for a feature still on a product
  branch stay on a topic branch here, loaded with `claude --plugin-dir`, and
  merge when the product PR merges.
- `git worktree list` first. Never rewrite a branch another worktree has
  checked out.

## Writing a reference

- Sources, in order of trust: the product PR's `packages/docs` diff, its route
  and sandbox specs, the sandbox source for what the handler bag actually
  binds, and the demo app when one exists. Name the ticket in the commit.
- Every reference opens with the three-part header the others use: **Load this
  reference when**, **Not in this file**, **Availability**.
- Update every hook when adding or changing a reference: the `SKILL.md`
  frontmatter description, the reference index row, the Feature floors row,
  the after-bootstrap step if scaffolding changes, the overview section, the
  reference-files table, and in `server-routes.md` the bag table plus the
  sandbox-constraints bullet for any handler helper.
- The front door is paid for on every load. Overviews stay short; detail goes
  in the reference that loads on demand.
- The references use em dashes freely; match the file you are in.
- No new documentation files outside `references/` unless asked.

## Commits, bumps, and PRs

- Subjects: `docs(<skill>): <what> (I5-xxxxx)` for content,
  `chore(informer): <version>` for bumps, `chore(marketplace): <what>` for
  manifest changes. Bodies say what changed and why in a few lines.
- The bump is the last commit and touches only
  `plugins/informer/.claude-plugin/plugin.json`,
  `plugins/informer/.codex-plugin/plugin.json`, and the stable entry's
  `version` in `.claude-plugin/marketplace.json`, which is what gates
  updates. A new feature is a minor bump; a correction is a patch.
- The manifest `name` is `informer`. Claude Code namespaces skills by that
  name, so it never changes.
- PRs target `main` and use rebase-merge.
- `.agents/plugins/marketplace.json` mirrors `.claude-plugin/marketplace.json`
  entry for entry; change both together.

## Validation

- `claude plugin validate plugins/informer`. The only accepted warning is the
  missing `author`.
- Try the skill before pushing: `claude --plugin-dir plugins/informer`, then
  ask for something the new section should answer and check the right
  reference loads. Ask once more with a target version below the floor and
  check the fallback, not the feature, comes back.
- `git grep -l '<<<<<<<' HEAD -- plugins` before any push after a rebase.

## Pushing

- If the harness denies a push, hand the exact command to the user; do not
  work around it.
- Never push to a branch checked out in another worktree.
