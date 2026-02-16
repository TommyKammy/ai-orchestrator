#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo "N8N Import + Execution Test"
echo "=========================================="
echo ""

N8N_IMAGE="n8nio/n8n:1.74.1"
CONTAINER_NAME="n8n-ci-test"
POSTGRES_CONTAINER="n8n-ci-postgres"
POSTGRES_DB="n8n"
POSTGRES_USER="n8n"
POSTGRES_PASSWORD="n8n"
WORKFLOW_DIR="${PWD}/n8n/workflows-v3"
TIMEOUT=240

WORKFLOW_FILES=(
  "slack_chat_minimal_v1.json"
  "chat_router_v1.json"
)

CI_IMPORT_DIR=""

cleanup() {
  echo "[cleanup] Removing containers..."
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker rm -f "$POSTGRES_CONTAINER" 2>/dev/null || true
  if [ -n "$CI_IMPORT_DIR" ] && [ -d "$CI_IMPORT_DIR" ]; then
    rm -rf "$CI_IMPORT_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if [ ! -d "$WORKFLOW_DIR" ]; then
  echo "ERROR: Workflow directory not found: $WORKFLOW_DIR"
  exit 1
fi

# Debug: show workflow directory info
echo "WORKFLOW_DIR=$WORKFLOW_DIR"
ls -la "$WORKFLOW_DIR" || true

# Create temp directory for CI import files (n8n 1.74.1 CLI expects array format)
CI_IMPORT_DIR="$(mktemp -d)"
echo "Creating CI import files in: $CI_IMPORT_DIR"

# Ensure temp dir is writable
if [ ! -w "$CI_IMPORT_DIR" ]; then
  echo "ERROR: temp dir not writable: $CI_IMPORT_DIR"
  exit 1
fi

normalize_and_write() {
  local src="$1"
  local dst="$2"

  python3 -c '
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, "r", encoding="utf-8") as f:
    data = json.load(f)

def ensure_active(obj):
    if isinstance(obj, dict) and "active" not in obj:
        obj["active"] = True
    return obj

# CLI import may receive either a single object or a list
if isinstance(data, dict):
    data = ensure_active(data)
    out = [data]  # wrap object into list for import
elif isinstance(data, list):
    out = [ensure_active(x) for x in data]
else:
    raise SystemExit(f"Unsupported JSON root type: {type(data)}")

with open(dst, "w", encoding="utf-8") as f:
    json.dump(out, f, ensure_ascii=False)
' "$src" "$dst"
}

wrap_workflow() {
  local src="$1"
  local dst="$2"

  if [ ! -f "$src" ]; then
    echo "ERROR: missing $src"
    exit 1
  fi
  if [ ! -r "$src" ]; then
    echo "ERROR: unreadable $src"
    ls -la "$src" || true
    exit 1
  fi

  normalize_and_write "$src" "$dst"
  echo "      Normalized $(basename "$src") (ensured active=true; wrapped as array)"
}

for wf in "${WORKFLOW_FILES[@]}"; do
  if [ -f "$WORKFLOW_DIR/$wf" ]; then
    wrap_workflow "$WORKFLOW_DIR/$wf" "$CI_IMPORT_DIR/$wf"
  fi
done

# Ensure container user (node UID=1000) can read files
chmod -R a+rX "$CI_IMPORT_DIR"

# Debug: show permissions
ls -la "$CI_IMPORT_DIR"

echo "[CI] Starting Postgres container..."
docker rm -f "$POSTGRES_CONTAINER" 2>/dev/null || true
docker run -d \
  --name "$POSTGRES_CONTAINER" \
  -e POSTGRES_DB="$POSTGRES_DB" \
  -e POSTGRES_USER="$POSTGRES_USER" \
  -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" \
  -p 5432:5432 \
  postgres:15-alpine

echo "[CI] Waiting for Postgres readiness..."
until docker exec "$POSTGRES_CONTAINER" pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; do
  sleep 1
done
echo "Postgres ready."

echo "[1/6] Starting n8n container with CI settings..."
docker run -d --name "$CONTAINER_NAME" \
  --link "$POSTGRES_CONTAINER":postgres \
  -p 5678:5678 \
  -e DB_TYPE=postgresdb \
  -e DB_POSTGRESDB_HOST=postgres \
  -e DB_POSTGRESDB_PORT=5432 \
  -e DB_POSTGRESDB_DATABASE="$POSTGRES_DB" \
  -e DB_POSTGRESDB_USER="$POSTGRES_USER" \
  -e DB_POSTGRESDB_PASSWORD="$POSTGRES_PASSWORD" \
  -e N8N_DIAGNOSTICS_ENABLED=false \
  -e N8N_PERSONALIZATION_ENABLED=false \
  -v "$CI_IMPORT_DIR:/import:ro" \
  "$N8N_IMAGE" 2>&1

if [ $? -ne 0 ]; then
  echo "ERROR: Failed to start n8n container"
  exit 1
fi

echo "[2/6] Waiting for n8n to be ready (timeout=${TIMEOUT}s)..."
READY_TIMEOUT_SECONDS=${TIMEOUT:-240}
START_TS=$(date +%s)

while true; do
  # 1) HTTP health check via /healthz (preferred)
  if docker exec "$CONTAINER_NAME" wget -qO- http://localhost:5678/healthz 2>/dev/null | grep -q "ok"; then
    echo "      n8n ready via /healthz"
    break
  fi

  # 2) HTTP health check via /rest/health (fallback)
  if curl -fsS "http://localhost:5678/rest/health" >/dev/null 2>&1; then
    echo "      n8n ready via /rest/health"
    break
  fi

  # 3) Log fallback - check for "Editor is now accessible" signal
  if docker logs "$CONTAINER_NAME" 2>&1 | tail -n 200 | grep -q "Editor is now accessible"; then
    echo "      n8n ready via log signal"
    break
  fi

  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TS))
  if [ "$ELAPSED" -ge "$READY_TIMEOUT_SECONDS" ]; then
    echo "ERROR: n8n failed to start within ${READY_TIMEOUT_SECONDS}s"
    echo "---- last logs ----"
    docker logs "$CONTAINER_NAME" --tail 200
    exit 1
  fi

  sleep 2
done

echo "[3/6] Importing workflows..."

for workflow in "${WORKFLOW_FILES[@]}"; do
  if [ -f "$WORKFLOW_DIR/$workflow" ]; then
    echo "      Importing $workflow..."
    docker exec "$CONTAINER_NAME" n8n import:workflow --input="/import/$workflow" 2>&1
    if [ $? -ne 0 ]; then
      echo "ERROR: Failed to import $workflow"
      exit 1
    fi
  else
    echo "WARNING: Workflow file not found: $workflow"
  fi
done

echo "[4/6] Restarting n8n to register webhooks with Postgres..."
docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "[5/6] Starting n8n to register webhooks..."
docker run -d --name "$CONTAINER_NAME" \
  --link "$POSTGRES_CONTAINER":postgres \
  -p 5678:5678 \
  -e DB_TYPE=postgresdb \
  -e DB_POSTGRESDB_HOST=postgres \
  -e DB_POSTGRESDB_PORT=5432 \
  -e DB_POSTGRESDB_DATABASE="$POSTGRES_DB" \
  -e DB_POSTGRESDB_USER="$POSTGRES_USER" \
  -e DB_POSTGRESDB_PASSWORD="$POSTGRES_PASSWORD" \
  -e N8N_DIAGNOSTICS_ENABLED=false \
  -e N8N_PERSONALIZATION_ENABLED=false \
  -v "$CI_IMPORT_DIR:/import:ro" \
  "$N8N_IMAGE" 2>&1

echo "[5/6] Waiting for n8n to be ready after restart..."
READY_TIMEOUT_SECONDS=${TIMEOUT:-240}
START_TS=$(date +%s)

while true; do
  if docker exec "$CONTAINER_NAME" wget -qO- http://localhost:5678/healthz 2>/dev/null | grep -q "ok"; then
    echo "      n8n ready via /healthz"
    break
  fi
  if curl -fsS "http://localhost:5678/rest/health" >/dev/null 2>&1; then
    echo "      n8n ready via /rest/health"
    break
  fi
  if docker logs "$CONTAINER_NAME" 2>&1 | tail -n 200 | grep -q "Editor is now accessible"; then
    echo "      n8n ready via log signal"
    break
  fi

  NOW=$(date +%s)
  ELAPSED=$((NOW - START_TS))
  if [ "$ELAPSED" -ge "$READY_TIMEOUT_SECONDS" ]; then
    echo "ERROR: n8n failed to start within ${READY_TIMEOUT_SECONDS}s"
    docker logs "$CONTAINER_NAME" --tail 200
    exit 1
  fi

  sleep 2
done

echo "[6/6] Verifying router webhook by direct invocation (no creds)..."

# Extract router webhook path from chat_router_v1.json
ROUTER_PATH="$(python3 -c '
import json, sys
try:
    with open("n8n/workflows-v3/chat_router_v1.json", "r", encoding="utf-8") as f:
        w = json.load(f)
    for n in w.get("nodes", []):
        if n.get("type") == "n8n-nodes-base.webhook":
            path = n.get("parameters", {}).get("path")
            if path:
                print(path)
                sys.exit(0)
    sys.exit("No webhook path found")
except Exception as e:
    sys.exit(f"Error: {e}")
')"

if [ -z "$ROUTER_PATH" ]; then
  echo "ERROR: Failed to extract router webhook path"
  exit 1
fi

echo "Router webhook path: $ROUTER_PATH"

WEBHOOK_URL="http://localhost:5678/webhook/${ROUTER_PATH}"
PAYLOAD='{"text":"ci test","brain_enabled":false,"user_id":"UCI","channel_id":"CCI"}'

RESP="$(curl -sS -w "\nHTTP_STATUS:%{http_code}\n" -H 'Content-Type: application/json' -d "$PAYLOAD" "$WEBHOOK_URL" || true)"
STATUS="$(echo "$RESP" | sed -n 's/^HTTP_STATUS://p' | tail -n 1)"
BODY="$(echo "$RESP" | sed '/^HTTP_STATUS:/d')"

echo "Status: $STATUS"
echo "Body: $BODY"

if [ "$STATUS" != "200" ]; then
  echo "ERROR: router webhook call failed, expected 200 got $STATUS"
  exit 1
fi

if ! echo "$BODY" | grep -q '"status"[[:space:]]*:[[:space:]]*"NO_BRAIN"'; then
  echo "ERROR: router webhook did not return status=NO_BRAIN"
  exit 1
fi

echo "Router direct invocation OK."

echo "[6/6] All tests complete!"
echo ""
echo "=========================================="
echo "✓ ALL CHECKS PASSED"
echo "=========================================="
echo ""
echo "Summary:"
echo "  - Postgres container started successfully"
echo "  - n8n container started with Postgres backend"
echo "  - Workflows imported"
echo "  - Container restarted (webhooks registered on startup)"
echo "  - Router webhook executed successfully (NO_BRAIN response)"
echo ""

exit 0
