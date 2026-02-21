#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/docker-compose.yml}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-ai-postgres}"
DB_USER="${DB_USER:-ai_user}"
DB_NAME="${DB_NAME:-ai_memory}"
DATA_DIR="${DATA_DIR:-$ROOT_DIR/postgres}"
BACKUP_BASE="${BACKUP_BASE:-$ROOT_DIR/backups/postgres-upgrade}"
ASSUME_YES="${ASSUME_YES:-false}"

if [[ "${1:-}" == "--yes" ]]; then
  ASSUME_YES="true"
fi

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

wait_for_pg() {
  local timeout="${1:-120}"
  local start now elapsed
  start="$(date +%s)"
  while true; do
    if docker exec "${POSTGRES_CONTAINER}" pg_isready -U "${DB_USER}" -d "${DB_NAME}" >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    elapsed=$((now - start))
    if [[ "${elapsed}" -ge "${timeout}" ]]; then
      return 1
    fi
    sleep 2
  done
}

query_pg() {
  local sql="$1"
  docker exec "${POSTGRES_CONTAINER}" \
    env PGPASSWORD="${POSTGRES_PASSWORD}" \
    psql -U "${DB_USER}" -d "${DB_NAME}" -tA -c "${sql}"
}

main() {
  require_cmd docker

  if ! docker compose version >/dev/null 2>&1; then
    echo "docker compose command is required." >&2
    exit 1
  fi

  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    echo "Compose file not found: ${COMPOSE_FILE}" >&2
    exit 1
  fi

  if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
    echo "POSTGRES_PASSWORD is required in environment." >&2
    exit 1
  fi

  echo "== PostgreSQL 16 -> 18 Upgrade (safe mode) =="
  echo "Root: ${ROOT_DIR}"
  echo "Compose: ${COMPOSE_FILE}"
  echo "Container: ${POSTGRES_CONTAINER}"
  echo "Database: ${DB_NAME}"
  echo "Data dir: ${DATA_DIR}"

  mkdir -p "${BACKUP_BASE}"
  local ts backup_dir dump_file meta_file old_data_backup
  ts="$(date +%Y%m%d_%H%M%S)"
  backup_dir="${BACKUP_BASE}/${ts}"
  dump_file="${backup_dir}/ai_memory.sql"
  meta_file="${backup_dir}/meta.txt"
  old_data_backup="${backup_dir}/postgres16_data"
  mkdir -p "${backup_dir}"

  if [[ "${ASSUME_YES}" != "true" ]]; then
    echo
    echo "This operation will:"
    echo "  1) Stop app writes (n8n/caddy/executor/opa/redis)"
    echo "  2) Dump database to ${dump_file}"
    echo "  3) Move current data dir to ${old_data_backup}"
    echo "  4) Start PostgreSQL 18 and restore data"
    echo
    read -r -p "Continue? (yes/no): " reply
    if [[ "${reply}" != "yes" ]]; then
      echo "Cancelled."
      exit 0
    fi
  fi

  echo
  echo "[1/8] Ensure postgres is running..."
  docker compose -f "${COMPOSE_FILE}" up -d postgres >/dev/null
  wait_for_pg 180 || {
    echo "Postgres did not become ready." >&2
    exit 1
  }

  local version_num version_major
  version_num="$(query_pg "SHOW server_version_num;")"
  version_major="${version_num:0:2}"
  echo "Current server_version_num=${version_num}"

  if [[ "${version_major}" -ge 18 ]]; then
    echo "PostgreSQL is already ${version_major}. No upgrade needed."
    exit 0
  fi

  if [[ "${version_major}" -ne 16 ]]; then
    echo "Expected major version 16 before upgrade, got ${version_major}." >&2
    echo "Abort for safety."
    exit 1
  fi

  {
    echo "timestamp=${ts}"
    echo "from_version_num=${version_num}"
    echo "db_user=${DB_USER}"
    echo "db_name=${DB_NAME}"
    echo "data_dir=${DATA_DIR}"
  } > "${meta_file}"

  echo "[2/8] Stop write path services..."
  docker compose -f "${COMPOSE_FILE}" stop n8n caddy executor opa redis >/dev/null 2>&1 || true

  echo "[3/8] Create logical backup..."
  docker exec "${POSTGRES_CONTAINER}" \
    env PGPASSWORD="${POSTGRES_PASSWORD}" \
    pg_dump -U "${DB_USER}" -d "${DB_NAME}" \
    --format=plain --clean --if-exists --no-owner --no-privileges \
    > "${dump_file}"

  if [[ ! -s "${dump_file}" ]]; then
    echo "Backup file is empty: ${dump_file}" >&2
    exit 1
  fi

  echo "[4/8] Stop postgres..."
  docker compose -f "${COMPOSE_FILE}" stop postgres >/dev/null

  echo "[5/8] Preserve PG16 data directory..."
  if [[ -d "${DATA_DIR}" ]]; then
    mv "${DATA_DIR}" "${old_data_backup}"
  fi
  mkdir -p "${DATA_DIR}"

  echo "[6/8] Start PostgreSQL 18..."
  docker compose -f "${COMPOSE_FILE}" up -d postgres >/dev/null
  wait_for_pg 180 || {
    echo "PostgreSQL 18 did not become ready." >&2
    exit 1
  }

  local new_version_num new_version_major
  new_version_num="$(query_pg "SHOW server_version_num;")"
  new_version_major="${new_version_num:0:2}"
  echo "New server_version_num=${new_version_num}"
  if [[ "${new_version_major}" -ne 18 ]]; then
    echo "Expected PostgreSQL 18 after upgrade, got ${new_version_major}." >&2
    exit 1
  fi

  echo "[7/8] Restore logical backup..."
  cat "${dump_file}" | docker exec -i "${POSTGRES_CONTAINER}" \
    env PGPASSWORD="${POSTGRES_PASSWORD}" \
    psql -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 >/dev/null

  echo "[8/8] Start full stack and verify..."
  docker compose -f "${COMPOSE_FILE}" up -d >/dev/null

  local vector_ext
  vector_ext="$(query_pg "SELECT extversion FROM pg_extension WHERE extname='vector';")"
  if [[ -z "${vector_ext}" ]]; then
    echo "WARNING: pgvector extension was not found in ${DB_NAME}."
  else
    echo "pgvector extension version: ${vector_ext}"
  fi

  echo
  echo "Upgrade completed successfully."
  echo "Backup directory: ${backup_dir}"
  echo "Rollback data dir: ${old_data_backup}"
  echo
  echo "Rollback (if needed):"
  echo "  1) docker compose -f ${COMPOSE_FILE} down"
  echo "  2) rm -rf ${DATA_DIR}"
  echo "  3) mv ${old_data_backup} ${DATA_DIR}"
  echo "  4) set POSTGRES_IMAGE=pgvector/pgvector:pg16 in .env"
  echo "  5) docker compose -f ${COMPOSE_FILE} up -d"
}

main "$@"
