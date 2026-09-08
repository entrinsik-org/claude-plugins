# CLAUDE.md

Skills for Informer development, published as Claude Code plugins. One plugin
(`plugins/informer`), several skills under `plugins/informer/skills/<skill>/`,
each an orientation `SKILL.md` plus a `references/` library. `README.md` is the
human guide to channels, release flow, and contributing; this file is the
working rules.

## Where a change goes

Branch by the Informer release the feature ships in, never by convenience:

| Feature ships in | Branch | Plugin | Version |
|---|---|---|---|
| A released Informer version | `main` | `informer` | `5.N.0` |
| The next Informer release | `beta` | `informer-beta` | `5.N.0-beta.M` |
| The release after that | `alpha` | `informer-alpha` | `5.(N+1).0-alpha.M` |

- `alpha` stacks on `beta` stacks on `main`, linearly. Rebase, never merge, when
  moving content between them. Both channels are force-pushed on rebase.
- Docs for an unshipped feature never branch from `main`.
- Confirm the target release from the product PR's base branch
  (`gh pr view <n> --json baseRefName` in the i5 repo) or ask. Never infer it
  from git history.
- `git worktree list` first. Never rewrite a branch that another worktree has
  checked out; start a new branch instead.
- Take a `backup/<branch>-pre-<what>` ref before any history rewrite.
- Promotion at GA is a three-step recipe in `README.md` under Release flow.

## Writing a reference

- Sources, in order of trust: the product PR's `packages/docs` diff, its route
  and sandbox specs, the sandbox source for what the handler bag actually
  binds, and the demo app when one exists. Name the ticket in the commit.
- Every reference opens with the three-part header the others use: **Load this
  reference when**, **Not in this file**, **Availability** (the Informer
  version floor, the Vite-plugin floor if dev emulation needs one, and how to
  feature-detect on older servers).
- Update every hook when adding or changing a reference: the `SKILL.md`
  frontmatter description, the reference index row, the after-bootstrap step
  if scaffolding changes, the overview section, the reference-files table, and
  in `server-routes.md` the bag table plus the sandbox-constraints bullet for
  any handler helper.
- A reference on one channel must not point at a file that only exists on a
  higher channel.
- The references use em dashes freely; match the file you are in.
- No new documentation files outside `references/` unless asked.

## Commits, bumps, and PRs

- Subjects: `docs(<skill>): <what> (I5-xxxxx)` for content,
  `chore(informer): <version>` for bumps, `chore(marketplace): <what>` for
  manifest changes. Bodies say what changed and why in a few lines.
- The bump is the last commit on a channel branch and touches only
  `plugins/informer/.claude-plugin/plugin.json` and
  `plugins/informer/.codex-plugin/plugin.json`. On `main` it also moves the
  stable entry's `version` in `.claude-plugin/marketplace.json`, which is what
  gates stable updates. Channel entries carry no `version` on purpose: every
  commit on the branch is an update, and the suffix is the visible label.
- Any change to `beta` is followed by rebasing `alpha` onto it and amending
  alpha's tip bump to the next suffix.
- PRs target the channel branch and use rebase-merge so the branches stay
  linear. A doc for an unreleased feature merges when the product PR merges,
  not before.
- `.agents/plugins/marketplace.json` mirrors `.claude-plugin/marketplace.json`
  entry for entry; change both together.

## Validation

- `claude plugin validate plugins/informer` on every branch you touched. The
  only accepted warning is the missing `author`.
- Try the skill before pushing: `claude --plugin-dir plugins/informer` from the
  branch, then ask for something the new section should answer and check the
  right reference loads.
- `git grep -l '<<<<<<<' <branch> -- plugins` before any push after a rebase.

## Pushing

- Channel rebases push with `git push --force-with-lease`. If the harness
  denies a force push, hand the exact command to the user; do not work around
  it.
- Never push to a branch checked out in another worktree.
