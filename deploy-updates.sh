#!/bin/bash
# Host update script (Git-based, no manual file copy).
# Run this script inside /opt/ai-orchestrator on the host server.

set -euo pipefail

REPO_DIR="${REPO_DIR:-/opt/ai-orchestrator}"
BRANCH="${BRANCH:-main}"
REMOTE="${REMOTE:-origin}"
STASH_NAME="autostash-before-deploy-$(date +%Y%m%d-%H%M%S)"

echo "=== AI Orchestrator Host Update ==="
echo "Date: $(date)"
echo "Repo: ${REPO_DIR}"
echo "Remote/Branch: ${REMOTE}/${BRANCH}"
echo ""

cd "${REPO_DIR}"

if [ ! -d ".git" ]; then
  echo "ERROR: ${REPO_DIR} is not a git repository." >&2
  exit 1
fi

echo "[1/4] Fetching latest changes..."
git fetch "${REMOTE}" "${BRANCH}"

if [ -n "$(git status --porcelain)" ]; then
  echo "Local uncommitted changes detected. Stashing before rebase..."
  git stash push -u -m "${STASH_NAME}" >/dev/null
fi

echo "[2/4] Rebasing to ${REMOTE}/${BRANCH}..."
git rebase "${REMOTE}/${BRANCH}"

echo "[3/4] Running one-command deploy with validations..."
bash ./deploy.sh

echo "[4/4] Final status..."
docker compose ps

echo ""
echo "=== Host Update Complete ==="
echo "If you need previous local changes, recover with:"
echo "  git stash list"
echo "  git stash pop"
echo ""
