#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="${COMPOSE_FILE:-$ROOT_DIR/docker-compose.yml}"
REDIS_CONTAINER="${REDIS_CONTAINER:-ai-redis}"
BACKUP_BASE="${BACKUP_BASE:-$ROOT_DIR/backups/redis-upgrade}"
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

wait_for_redis() {
  local timeout="${1:-120}"
  local start now elapsed
  start="$(date +%s)"
  while true; do
    if docker exec "${REDIS_CONTAINER}" redis-cli ping >/dev/null 2>&1; then
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

redis_version() {
  docker exec "${REDIS_CONTAINER}" redis-cli INFO server \
    | awk -F: '/^redis_version:/ {gsub(/\r/,"",$2); print $2}'
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

  echo "== Redis 7 -> 8 Upgrade (safe mode) =="
  echo "Root: ${ROOT_DIR}"
  echo "Compose: ${COMPOSE_FILE}"
  echo "Container: ${REDIS_CONTAINER}"

  local ts backup_dir backup_data_dir version major
  ts="$(date +%Y%m%d_%H%M%S)"
  backup_dir="${BACKUP_BASE}/${ts}"
  backup_data_dir="${backup_dir}/redis-data"
  mkdir -p "${backup_data_dir}"

  if [[ "${ASSUME_YES}" != "true" ]]; then
    echo
    echo "This operation will:"
    echo "  1) Stop write-path services (n8n/caddy/executor/opa)"
    echo "  2) Create a consistent Redis backup in ${backup_data_dir}"
    echo "  3) Restart Redis with redis:8.6-alpine"
    echo
    read -r -p "Continue? (yes/no): " reply
    if [[ "${reply}" != "yes" ]]; then
      echo "Cancelled."
      exit 0
    fi
  fi

  echo
  echo "[1/6] Ensure redis is running..."
  docker compose -f "${COMPOSE_FILE}" up -d redis >/dev/null
  wait_for_redis 120 || {
    echo "Redis did not become ready." >&2
    exit 1
  }

  version="$(redis_version)"
  major="${version%%.*}"
  echo "Current redis_version=${version}"

  if [[ "${major}" -ge 8 ]]; then
    echo "Redis is already major version ${major}. No upgrade needed."
    exit 0
  fi
  if [[ "${major}" -ne 7 ]]; then
    echo "Expected major version 7 before upgrade, got ${major}. Abort for safety." >&2
    exit 1
  fi

  echo "[2/6] Stop write-path services..."
  docker compose -f "${COMPOSE_FILE}" stop n8n caddy executor opa >/dev/null 2>&1 || true

  echo "[3/6] Create consistent backup..."
  docker exec "${REDIS_CONTAINER}" redis-cli SAVE >/dev/null
  docker cp "${REDIS_CONTAINER}:/data/." "${backup_data_dir}/"
  if [[ -z "$(ls -A "${backup_data_dir}" 2>/dev/null)" ]]; then
    echo "Backup directory is empty: ${backup_data_dir}" >&2
    exit 1
  fi

  echo "[4/6] Restart Redis with new image..."
  docker compose -f "${COMPOSE_FILE}" up -d --force-recreate redis >/dev/null
  wait_for_redis 120 || {
    echo "Redis (new image) did not become ready." >&2
    exit 1
  }

  local new_version new_major
  new_version="$(redis_version)"
  new_major="${new_version%%.*}"
  echo "New redis_version=${new_version}"
  if [[ "${new_major}" -ne 8 ]]; then
    echo "Expected Redis 8 after upgrade, got ${new_version}." >&2
    exit 1
  fi

  echo "[5/6] Start full stack..."
  docker compose -f "${COMPOSE_FILE}" up -d >/dev/null

  echo "[6/6] Health check..."
  docker exec "${REDIS_CONTAINER}" redis-cli ping | grep -q PONG

  echo
  echo "Upgrade completed successfully."
  echo "Backup: ${backup_data_dir}"
  echo
  echo "Rollback (if needed):"
  echo "  1) set REDIS_IMAGE=redis:7-alpine in .env"
  echo "  2) docker compose -f ${COMPOSE_FILE} up -d --force-recreate redis"
  echo "  3) docker compose -f ${COMPOSE_FILE} stop redis"
  echo "  4) docker cp ${backup_data_dir}/. ${REDIS_CONTAINER}:/data/"
  echo "  5) docker compose -f ${COMPOSE_FILE} up -d redis"
}

main "$@"
