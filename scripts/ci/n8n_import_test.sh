#!/usr/bin/env bash
set -euo pipefail

echo "=========================================="
echo "N8N Import Test - Webhook Verification"
echo "=========================================="
echo ""

N8N_IMAGE="n8nio/n8n:1.74.1"
CONTAINER_NAME="n8n-ci-test"
WORKFLOW_DIR="${PWD}/n8n/workflows-v3"
TIMEOUT=60

cleanup() {
  echo "[cleanup] Removing container..."
  docker rm -f "$CONTAINER_NAME" 2>/dev/null || true
}
trap cleanup EXIT

if [ ! -d "$WORKFLOW_DIR" ]; then
  echo "ERROR: Workflow directory not found: $WORKFLOW_DIR"
  exit 1
fi

echo "[1/6] Starting n8n container..."
docker run -d --name "$CONTAINER_NAME" \
  -p 5678:5678 \
  -e N8N_BASIC_AUTH_ACTIVE=false \
  -e N8N_DIAGNOSTICS_ENABLED=false \
  -e N8N_PERSONALIZATION_ENABLED=false \
  -e N8N_USER_MANAGEMENT_DISABLED=true \
  -e N8N_ENCRYPTION_KEY=test-key-for-ci-only-do-not-use-in-production \
  -v "$WORKFLOW_DIR:/import:ro" \
  "$N8N_IMAGE" 2>&1

if [ $? -ne 0 ]; then
  echo "ERROR: Failed to start n8n container"
  exit 1
fi

echo "[2/6] Waiting for n8n to be ready..."
for i in $(seq 1 $TIMEOUT); do
  if docker exec "$CONTAINER_NAME" wget -qO- http://localhost:5678/healthz 2>/dev/null | grep -q "ok"; then
    echo "      n8n is ready!"
    break
  fi
  if [ $i -eq $TIMEOUT ]; then
    echo "ERROR: n8n failed to start within ${TIMEOUT}s"
    docker logs "$CONTAINER_NAME" --tail 50
    exit 1
  fi
  sleep 1
done

echo "[3/6] Importing workflows..."
WORKFLOW_FILES=(
  "slack_chat_minimal_v1.json"
  "chat_router_v1.json"
)

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

echo "[4/6] Activating workflows..."
docker exec "$CONTAINER_NAME" sh -c '
  sqlite3 /home/node/.n8n/database.sqlite "UPDATE workflow_entity SET active = 1 WHERE name LIKE '%slack%';"
' 2>&1

echo "[5/6] Verifying webhook registrations..."
WEBHOOKS=$(docker exec "$CONTAINER_NAME" sh -c '
  sqlite3 /home/node/.n8n/database.sqlite "SELECT webhookPath FROM webhook_entity;" 2>/dev/null || echo ""
' 2>&1)

echo "      Registered webhooks:"
echo "$WEBHOOKS" | while read -r line; do
  if [ -n "$line" ]; then
    echo "        - $line"
  fi
done

if echo "$WEBHOOKS" | grep -q "slack-command"; then
  echo ""
  echo "✓ Webhook 'slack-command' registered successfully"
else
  echo ""
  echo "ERROR: Webhook 'slack-command' not found in registrations"
  echo ""
  echo "Registered webhooks:"
  echo "$WEBHOOKS"
  echo ""
  echo "[diagnostic] Database contents:"
  docker exec "$CONTAINER_NAME" sh -c '
    sqlite3 /home/node/.n8n/database.sqlite "SELECT name FROM workflow_entity;"
  ' 2>&1 || true
  exit 1
fi

echo "[6/6] Verification complete!"
echo ""
echo "=========================================="
echo "✓ All checks passed"
echo "=========================================="
echo ""
echo "Summary:"
echo "  - Container started successfully"
echo "  - Workflows imported"
echo "  - Webhook 'slack-command' registered"
echo ""

exit 0
