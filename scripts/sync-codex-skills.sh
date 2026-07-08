#!/usr/bin/env bash
#
# sync-codex-skills.sh — expose the plugin's skills to OpenAI Codex.
#
# Source of truth stays under plugins/<plugin>/skills/<skill>/SKILL.md. Codex
# discovers skills under a `.agents/skills/` directory (repo-level: scanned from
# the cwd up to the repo root; user-level: ~/.agents/skills). This script wires
# the two together without duplicating content.
#
# The repo already commits per-skill SYMLINKS under .agents/skills/, which is all
# Codex needs in most setups. Use this script when symlinks aren't an option:
#   - Windows / filesystems without symlink support
#   - a Codex build that doesn't follow symlinked skill dirs
#   - installing the skills user-globally so they work in every repo
#
# Usage:
#   scripts/sync-codex-skills.sh              # (re)create repo .agents/skills symlinks
#   scripts/sync-codex-skills.sh --copy       # materialize real copies in repo .agents/skills
#   scripts/sync-codex-skills.sh --user       # copy skills into ~/.agents/skills (global)
#
set -euo pipefail

MODE="symlink"
DEST=""
case "${1:-}" in
  --copy) MODE="copy" ;;
  --user) MODE="copy"; DEST="$HOME/.agents/skills" ;;
  "")     MODE="symlink" ;;
  *) echo "unknown option: $1" >&2; echo "use --copy, --user, or no argument" >&2; exit 2 ;;
esac

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${DEST:-$REPO_ROOT/.agents/skills}"

mkdir -p "$DEST"

count=0
# Each skill is a directory containing a SKILL.md, located at plugins/*/skills/*/.
for skill_md in "$REPO_ROOT"/plugins/*/skills/*/SKILL.md; do
  [ -e "$skill_md" ] || continue
  skill_dir="$(dirname "$skill_md")"
  skill_name="$(basename "$skill_dir")"
  target="$DEST/$skill_name"

  rm -rf "$target"
  if [ "$MODE" = "symlink" ]; then
    # Relative symlink so the repo stays portable across clones.
    rel="$(cd "$REPO_ROOT" && python3 -c "import os,sys;print(os.path.relpath(sys.argv[1],sys.argv[2]))" "$skill_dir" "$DEST")"
    ln -s "$rel" "$target"
    echo "linked  $skill_name -> $rel"
  else
    cp -R "$skill_dir" "$target"
    echo "copied  $skill_name -> $target"
  fi
  count=$((count + 1))
done

echo "done: $count skill(s) synced to $DEST ($MODE)"
