#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK_DIR="$REPO_ROOT/.git/hooks"

if [ ! -d "$HOOK_DIR" ]; then
  echo "ERROR: .git/hooks not found. Are you in a git repo?"
  exit 1
fi

install -m 755 "$REPO_ROOT/tools/git-hooks/pre-commit" "$HOOK_DIR/pre-commit"
echo "Installed pre-commit hook -> $HOOK_DIR/pre-commit"
echo "Done."
