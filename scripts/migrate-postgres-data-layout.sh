#!/usr/bin/env bash
set -euo pipefail

# Migrate legacy PostgreSQL bind layout to ./postgres/data if needed.
# Safe to run multiple times.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PG_ROOT="${ROOT_DIR}/postgres"
PG_DATA_DIR="${PG_ROOT}/data"
TS="$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="${ROOT_DIR}/backups/postgres-layout-migration/${TS}"

mkdir -p "${BACKUP_DIR}"

echo "[1/6] Ensuring repository root: ${ROOT_DIR}"

if [[ ! -d "${PG_ROOT}" ]]; then
  echo "No postgres directory found at ${PG_ROOT}; nothing to migrate."
  exit 0
fi

# Already migrated if typical PGDATA files exist under postgres/data.
if [[ -f "${PG_DATA_DIR}/PG_VERSION" ]]; then
  echo "Detected existing postgres/data layout. No migration required."
  exit 0
fi

# Legacy layout heuristic: PG_VERSION directly under postgres/
if [[ ! -f "${PG_ROOT}/PG_VERSION" ]]; then
  echo "Legacy layout not detected (PG_VERSION not found in ${PG_ROOT})."
  echo "If this is a fresh environment, no action is required."
  exit 0
fi

echo "[2/6] Stopping PostgreSQL container..."
docker compose stop postgres || true

echo "[3/6] Backing up legacy postgres directory metadata..."
cp -a "${PG_ROOT}" "${BACKUP_DIR}/postgres-legacy"

echo "[4/6] Creating new data directory and moving contents..."
mkdir -p "${PG_DATA_DIR}"
shopt -s dotglob
for item in "${PG_ROOT}"/*; do
  [[ "${item}" == "${PG_DATA_DIR}" ]] && continue
  mv "${item}" "${PG_DATA_DIR}/"
done
shopt -u dotglob

echo "[5/6] Starting PostgreSQL..."
docker compose up -d postgres

echo "[6/6] Verifying PostgreSQL readiness..."
for i in {1..30}; do
  if docker exec ai-postgres pg_isready -U ai_user >/dev/null 2>&1; then
    echo "Migration successful."
    echo "Backup stored at ${BACKUP_DIR}"
    exit 0
  fi
  sleep 1
done

echo "ERROR: PostgreSQL did not become ready after migration." >&2
echo "Backup stored at ${BACKUP_DIR}" >&2
exit 1
