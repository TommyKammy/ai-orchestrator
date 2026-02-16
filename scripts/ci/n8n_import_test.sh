#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo "N8N Import + Execution Test (Postgres)"
echo "=========================================="
echo ""

# Images
N8N_IMAGE="${N8N_IMAGE:-n8nio/n8n:1.74.1}"
POSTGRES_IMAGE="${POSTGRES_IMAGE:-postgres:15-alpine}"

# Docker resources
NETWORK_NAME="${NETWORK_NAME:-n8n-ci-net}"
N8N_CONTAINER="${N8N_CONTAINER:-n8n-ci-test}"
POSTGRES_CONTAINER="${POSTGRES_CONTAINER:-n8n-ci-postgres}"

# Postgres settings (CI only)
POSTGRES_DB="${POSTGRES_DB:-n8n}"
POSTGRES_USER="${POSTGRES_USER:-n8n}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-n8n}"

# n8n settings
N8N_PORT="${N8N_PORT:-5678}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-480}"
N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY:-test-key-for-ci-only}"
WEBHOOK_BASE_URL="${WEBHOOK_BASE_URL:-http://localhost:${N8N_PORT}}"

# Workflows
WORKFLOW_DIR="${PWD}/n8n/workflows-v3"
WORKFLOW_FILES=(
  "slack_chat_minimal_v1.json"
  "chat_router_v1.json"
)

CI_IMPORT_DIR=""
WORKLOG="${WORKLOG:-/dev/null}"

cleanup() {
  echo ""
  echo "[cleanup] Removing containers/network/tmp..."
  docker rm -f "${N8N_CONTAINER}" >/dev/null 2>&1 || true
  docker rm -f "${POSTGRES_CONTAINER}" >/dev/null 2>&1 || true
  docker network rm "${NETWORK_NAME}" >/dev/null 2>&1 || true
  if [[ -n "${CI_IMPORT_DIR}" && -d "${CI_IMPORT_DIR}" ]]; then
    rm -rf "${CI_IMPORT_DIR}" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

die() {
  echo "ERROR: $*" >&2
  echo ""
  echo "[debug] n8n logs (tail 200):"
  docker logs "${N8N_CONTAINER}" --tail 200 2>/dev/null || true
  echo ""
  echo "[debug] postgres logs (tail 200):"
  docker logs "${POSTGRES_CONTAINER}" --tail 200 2>/dev/null || true
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Missing required command: $1"
}

wait_for_http_200() {
  local url="$1"
  local timeout="$2"
  local start now elapsed
  start="$(date +%s)"
  while true; do
    if curl -fsS "$url" >/dev/null 2>&1; then
      return 0
    fi
    now="$(date +%s)"
    elapsed=$((now - start))
    if [[ "$elapsed" -ge "$timeout" ]]; then
      return 1
    fi
    sleep 2
  done
}

wait_for_n8n_ready() {
  local timeout="$1"
  local label="$2"
  local start now elapsed
  start="$(date +%s)"
  
  echo "      Waiting for n8n readiness (${label})..."
  while true; do
    # Try /healthz/readiness first (preferred, no auth)
    if curl -fsS "${WEBHOOK_BASE_URL}/healthz/readiness" >/dev/null 2>&1; then
      echo "      n8n ready via /healthz/readiness"
      return 0
    fi
    # Fallback to /healthz
    if curl -fsS "${WEBHOOK_BASE_URL}/healthz" >/dev/null 2>&1; then
      echo "      n8n ready via /healthz"
      return 0
    fi
    # Fallback to /rest/health
    if curl -fsS "${WEBHOOK_BASE_URL}/rest/health" >/dev/null 2>&1; then
      echo "      n8n ready via /rest/health"
      return 0
    fi
    now="$(date +%s)"
    elapsed=$((now - start))
    if [[ "$elapsed" -ge "$timeout" ]]; then
      return 1
    fi
    sleep 2
  done
}

normalize_and_write() {
  local src="$1"
  local dst="$2"

  python3 - "$src" "$dst" <<'PY'
import json, sys

src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)

def normalize_workflow(obj):
    # Ensure required fields exist for import stability
    if isinstance(obj, dict):
        obj.setdefault("active", False)  # import may ignore; we activate later via CLI
    return obj

if isinstance(data, dict):
    out = [normalize_workflow(data)]
elif isinstance(data, list):
    out = [normalize_workflow(x) for x in data]
else:
    raise SystemExit(f"Unsupported JSON root type: {type(data)}")

with open(dst, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False)
PY
}

extract_router_path() {
  python3 - <<'PY'
import json, sys
p = "n8n/workflows-v3/chat_router_v1.json"
with open(p, "r", encoding="utf-8") as f:
    w = json.load(f)

nodes = w.get("nodes", [])
for n in nodes:
    if n.get("type") == "n8n-nodes-base.webhook":
        path = (n.get("parameters") or {}).get("path")
        if path:
            # Normalize leading slash if any
            path = path.lstrip("/")
            print(path)
            sys.exit(0)

sys.exit("No webhook node path found in chat_router_v1.json")
PY
}

main() {
  require_cmd docker
  require_cmd curl
  require_cmd python3

  [[ -d "${WORKFLOW_DIR}" ]] || die "Workflow directory not found: ${WORKFLOW_DIR}"

  echo "WORKFLOW_DIR=${WORKFLOW_DIR}"
  ls -la "${WORKFLOW_DIR}" || true
  echo ""

  echo "Creating CI import files..."
  CI_IMPORT_DIR="$(mktemp -d)"
  [[ -w "${CI_IMPORT_DIR}" ]] || die "Temp dir not writable: ${CI_IMPORT_DIR}"

  for wf in "${WORKFLOW_FILES[@]}"; do
    if [[ -f "${WORKFLOW_DIR}/${wf}" ]]; then
      normalize_and_write "${WORKFLOW_DIR}/${wf}" "${CI_IMPORT_DIR}/${wf}"
      echo "  - Normalized ${wf} -> ${CI_IMPORT_DIR}/${wf}"
    else
      echo "  - WARNING: missing workflow file: ${wf} (skipping)"
    fi
  done

  chmod -R a+rX "${CI_IMPORT_DIR}"
  ls -la "${CI_IMPORT_DIR}" || true
  echo ""

  echo "[CI] Creating docker network: ${NETWORK_NAME}"
  docker network create "${NETWORK_NAME}" >/dev/null

  echo "[CI] Starting Postgres container..."
  docker run -d --name "${POSTGRES_CONTAINER}" --network "${NETWORK_NAME}" \
    -e POSTGRES_DB="${POSTGRES_DB}" \
    -e POSTGRES_USER="${POSTGRES_USER}" \
    -e POSTGRES_PASSWORD="${POSTGRES_PASSWORD}" \
    "${POSTGRES_IMAGE}" >/dev/null

  echo "[CI] Waiting for Postgres readiness..."
  local start now elapsed
  start="$(date +%s)"
  while true; do
    if docker exec "${POSTGRES_CONTAINER}" pg_isready -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" >/dev/null 2>&1; then
      echo "Postgres ready."
      break
    fi
    now="$(date +%s)"
    elapsed=$((now - start))
    if [[ "$elapsed" -ge "${TIMEOUT_SECONDS}" ]]; then
      die "Postgres failed to become ready within ${TIMEOUT_SECONDS}s"
    fi
    sleep 2
  done
  echo ""

  echo "[1/5] Starting n8n container with Postgres backend..."
  docker run -d --name "${N8N_CONTAINER}" --network "${NETWORK_NAME}" \
    -p "${N8N_PORT}:5678" \
    -e DB_TYPE=postgresdb \
    -e DB_POSTGRESDB_HOST="${POSTGRES_CONTAINER}" \
    -e DB_POSTGRESDB_PORT=5432 \
    -e DB_POSTGRESDB_DATABASE="${POSTGRES_DB}" \
    -e DB_POSTGRESDB_USER="${POSTGRES_USER}" \
    -e DB_POSTGRESDB_PASSWORD="${POSTGRES_PASSWORD}" \
    -e N8N_DIAGNOSTICS_ENABLED=false \
    -e N8N_PERSONALIZATION_ENABLED=false \
    -e N8N_USER_MANAGEMENT_DISABLED=true \
    -e N8N_BASIC_AUTH_ACTIVE=false \
    -e N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY}" \
    -e WEBHOOK_URL="${WEBHOOK_BASE_URL}" \
    -e N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=false \
    -e SLACK_SIG_VERIFY_ENABLED=false \
    -e N8N_PUBLIC_API_DISABLED=true \
    -v "${CI_IMPORT_DIR}:/import:ro" \
    "${N8N_IMAGE}" >/dev/null

  echo "[2/5] Waiting for n8n to be ready (timeout=${TIMEOUT_SECONDS}s)..."
  if wait_for_n8n_ready "${TIMEOUT_SECONDS}" "first start"; then
    :
  else
    die "n8n failed to become ready within ${TIMEOUT_SECONDS}s"
  fi
  echo ""

  echo "[3/5] Importing workflows..."
  for wf in "${WORKFLOW_FILES[@]}"; do
    if [[ -f "${WORKFLOW_DIR}/${wf}" ]]; then
      echo "      Importing ${wf}..."
      # NOTE: n8n may deactivate workflows on import; we activate in next step.
      docker exec "${N8N_CONTAINER}" n8n import:workflow --input="/import/${wf}" >/dev/null
      echo "      Imported ${wf}"
    fi
  done
  echo ""

  echo "[4/5] Stopping n8n and inspecting schema before activation..."
  docker stop "${N8N_CONTAINER}" > /dev/null 2>&1 || true
  docker rm -f "${N8N_CONTAINER}" > /dev/null 2>&1 || true
  
  echo "      Inspecting workflow_entity schema..."
  docker exec -i "${POSTGRES_CONTAINER}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c "\d workflow_entity" 2>&1 | tee -a "$WORKLOG"
  
  echo "      Current workflows in DB (before activation):"
  docker exec -i "${POSTGRES_CONTAINER}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c "
SELECT id, name, active FROM workflow_entity ORDER BY id;
" 2>&1 | tee -a "$WORKLOG"
  
  echo "      Activating workflows via SQL (schema-safe)..."
  # Schema-safe activation: only set active=true, no timestamp assumptions
  docker exec -i "${POSTGRES_CONTAINER}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" <<'SQL' | tee -a "$WORKLOG"
-- Activate most recently imported workflows
UPDATE workflow_entity 
SET active = true 
WHERE id IN (
  SELECT id FROM workflow_entity ORDER BY id DESC LIMIT 2
);

-- Verify activation
SELECT id, name, active FROM workflow_entity WHERE active = true;
SQL
  
  echo "      Activation complete."
  echo ""

  echo "[5/5] Starting n8n to register webhooks..."
  docker run -d --name "${N8N_CONTAINER}" --network "${NETWORK_NAME}" \
    -p "${N8N_PORT}:5678" \
    -e DB_TYPE=postgresdb \
    -e DB_POSTGRESDB_HOST="${POSTGRES_CONTAINER}" \
    -e DB_POSTGRESDB_PORT=5432 \
    -e DB_POSTGRESDB_DATABASE="${POSTGRES_DB}" \
    -e DB_POSTGRESDB_USER="${POSTGRES_USER}" \
    -e DB_POSTGRESDB_PASSWORD="${POSTGRES_PASSWORD}" \
    -e N8N_DIAGNOSTICS_ENABLED=false \
    -e N8N_PERSONALIZATION_ENABLED=false \
    -e N8N_USER_MANAGEMENT_DISABLED=true \
    -e N8N_BASIC_AUTH_ACTIVE=false \
    -e N8N_ENCRYPTION_KEY="${N8N_ENCRYPTION_KEY}" \
    -e WEBHOOK_URL="${WEBHOOK_BASE_URL}" \
    -e N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS=false \
    -e SLACK_SIG_VERIFY_ENABLED=false \
    -e N8N_PUBLIC_API_DISABLED=true \
    "${N8N_IMAGE}" > /dev/null

  if wait_for_n8n_ready "${TIMEOUT_SECONDS}" "after activation"; then
    :
  else
    die "n8n failed to become ready after restart within ${TIMEOUT_SECONDS}s"
  fi
  echo ""

  echo "[5/5] Verifying activation and router webhook (no creds)..."
  
  # Deterministic verification 1: DB shows workflows active (already verified in step 4)
  echo "      Checking DB activation state..."
  docker exec -i "${POSTGRES_CONTAINER}" psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c "
SELECT id, name, active FROM workflow_entity WHERE active = true;
" 2>&1 | tee -a "$WORKLOG"
  
  # Deterministic verification 2: n8n logs show workflows started
  echo "      Checking n8n logs for workflow activation..."
  docker logs --tail 200 "${N8N_CONTAINER}" 2>&1 | tee /tmp/n8n_tail.log | tee -a "$WORKLOG"
  if ! grep -q "Start Active Workflows" /tmp/n8n_tail.log; then
    die "n8n logs do not show 'Start Active Workflows' - activation may have failed"
  fi
  if ! grep -q "slack_chat_minimal_v1" /tmp/n8n_tail.log; then
    die "n8n logs do not mention 'slack_chat_minimal_v1' - workflow not loaded"
  fi
  if ! grep -q "Chat Router v1" /tmp/n8n_tail.log; then
    die "n8n logs do not mention 'Chat Router v1' - workflow not loaded"
  fi
  echo "      Activation verified via n8n logs."
  
  # Extract router path and call webhook
  local router_path
  router_path="$(extract_router_path)" || die "Failed to extract router webhook path from chat_router_v1.json"
  [[ -n "${router_path}" ]] || die "Empty router webhook path extracted"
  echo "Router webhook path: ${router_path}"

  WEBHOOK_URL="${WEBHOOK_BASE_URL}/webhook/${router_path}"
  PAYLOAD='{"text":"ci test","brain_enabled":false,"user_id":"UCI","channel_id":"CCI"}'

  echo "      Calling webhook: ${WEBHOOK_URL}"
  # Use curl write-out for deterministic HTTP status extraction (avoids tail -n + parsing)
  HTTP_STATUS="$(curl -sS -o /tmp/webhook_body.txt -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' -d "${PAYLOAD}" "${WEBHOOK_URL}" \
    2>/tmp/webhook_err.txt || true)"
  BODY="$(cat /tmp/webhook_body.txt 2>/dev/null || true)"
  ERR="$(cat /tmp/webhook_err.txt 2>/dev/null || true)"
  
  echo "      HTTP Status: ${HTTP_STATUS}"
  echo "      Body: ${BODY}"
  if [[ -n "${ERR}" ]]; then
    echo "      Curl stderr: ${ERR}"
  fi
  
  if [[ "${HTTP_STATUS}" != "200" ]]; then
    echo ""
    echo "ERROR: Webhook endpoint is auth-protected or unreachable; CI must disable auth via env vars"
    die "router webhook call failed, expected 200 got ${HTTP_STATUS}"
  fi

  if ! echo "${BODY}" | grep -q '"status"[[:space:]]*:[[:space:]]*"NO_BRAIN"'; then
    die "router webhook did not return status=NO_BRAIN"
  fi

  echo ""
  echo "=========================================="
  echo "✓ ALL CHECKS PASSED"
  echo "=========================================="
}

main "$@"
