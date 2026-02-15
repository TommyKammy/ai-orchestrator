#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo "N8N Import + Execution Test"
echo "=========================================="
echo ""

N8N_IMAGE="n8nio/n8n:1.74.1"
CONTAINER_NAME="n8n-ci-test"
N8N_DATA_VOLUME="n8n-ci-data"
WORKFLOW_DIR="${PWD}/n8n/workflows-v3"
TIMEOUT=240

WORKFLOW_FILES=(
  "slack_chat_minimal_v1.json"
  "chat_router_v1.json"
)

CI_IMPORT_DIR=""

cleanup() {
  echo "[cleanup] Removing container and volume..."
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
  docker volume rm -f "$N8N_DATA_VOLUME" 2>/dev/null || true
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
        obj["active"] = False
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
  echo "      Normalized $(basename "$src") (ensured active=false; wrapped as array)"
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

echo "[1/8] Starting n8n container with CI settings..."
docker run -d --name "$CONTAINER_NAME" \
  -p 5678:5678 \
  -e N8N_BASIC_AUTH_ACTIVE=false \
  -e N8N_DIAGNOSTICS_ENABLED=false \
  -e N8N_PERSONALIZATION_ENABLED=false \
  -e N8N_USER_MANAGEMENT_DISABLED=true \
  -e N8N_ENCRYPTION_KEY=test-key-for-ci-only \
  -e SLACK_SIG_VERIFY_ENABLED=false \
  -v "$N8N_DATA_VOLUME":/home/node/.n8n \
  -v "$CI_IMPORT_DIR:/import:ro" \
  "$N8N_IMAGE" 2>&1

if [ $? -ne 0 ]; then
  echo "ERROR: Failed to start n8n container"
  exit 1
fi

echo "[2/8] Waiting for n8n to be ready (timeout=${TIMEOUT}s)..."
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

echo "[3/8] Importing workflows..."

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

echo "[4/8] Stopping n8n to apply activation..."
docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "Activating workflows via n8n CLI (while n8n is stopped)..."
docker run --rm \
  -v "$N8N_DATA_VOLUME":/home/node/.n8n \
  -e N8N_ENCRYPTION_KEY=test-key-for-ci-only \
  "$N8N_IMAGE" \
  n8n update:workflow --all --active=true 2>&1

echo "Activation complete (applied while n8n stopped)."

echo "[5/8] Starting n8n container again..."
docker run -d --name "$CONTAINER_NAME" \
  -p 5678:5678 \
  -e N8N_BASIC_AUTH_ACTIVE=false \
  -e N8N_DIAGNOSTICS_ENABLED=false \
  -e N8N_PERSONALIZATION_ENABLED=false \
  -e N8N_USER_MANAGEMENT_DISABLED=true \
  -e N8N_ENCRYPTION_KEY=test-key-for-ci-only \
  -e SLACK_SIG_VERIFY_ENABLED=false \
  -v "$N8N_DATA_VOLUME":/home/node/.n8n \
  "$N8N_IMAGE" 2>&1

echo "[6/8] Waiting for n8n to be ready after restart..."
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

echo "[7/8] Verifying webhook registrations..."
WEBHOOKS=$(curl -fsS "http://localhost:5678/rest/active-workflows" 2>/dev/null || echo "")

if echo "$WEBHOOKS" | grep -q "slack-command"; then
  echo ""
  echo "✓ Webhook 'slack-command' registered successfully"
else
  echo ""
  echo "ERROR: Webhook 'slack-command' not found"
  echo "Response: $WEBHOOKS"
  exit 1
fi

echo "[8/8] Testing webhook execution..."
echo "      POST to /webhook/slack-command..."

RESPONSE=$(curl -s -i -X POST "http://localhost:5678/webhook/slack-command" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data "user_id=U_CI_TEST&channel_id=C_CI_TEST&text=hello&response_url=https%3A%2F%2Fexample.com" 2>&1)

HTTP_STATUS=$(echo "$RESPONSE" | head -1 | grep -oE '[0-9]{3}' | head -1)
BODY=$(echo "$RESPONSE" | tail -n +$(echo "$RESPONSE" | grep -n '^$' | head -1 | cut -d: -f1))

echo "      HTTP Status: $HTTP_STATUS"
echo "      Response Body: $BODY"

if [ "$HTTP_STATUS" != "200" ]; then
  echo ""
  echo "ERROR: Expected HTTP 200, got $HTTP_STATUS"
  echo ""
  echo "Last 50 lines of n8n logs:"
  docker logs "$CONTAINER_NAME" --tail 50
  exit 1
fi

if echo "$BODY" | grep -q "Processing your request"; then
  echo ""
  echo "✓ Webhook execution successful - received immediate ACK"
else
  echo ""
  echo "ERROR: Response does not contain 'Processing your request'"
  echo ""
  echo "Full response:"
  echo "$RESPONSE"
  echo ""
  echo "Last 100 lines of n8n logs:"
  docker logs "$CONTAINER_NAME" --tail 100
  exit 1
fi

echo "[8/8] All tests complete!"
echo ""
echo "=========================================="
echo "✓ ALL CHECKS PASSED"
echo "=========================================="
echo ""
echo "Summary:"
echo "  - Container started successfully"
echo "  - Workflows imported"
echo "  - Activation applied (n8n stopped during activation)"
echo "  - Container restarted with active workflows"
echo "  - Webhook 'slack-command' registered"
echo "  - Webhook execution returned immediate ACK"
echo ""

exit 0
