#!/bin/bash
set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET="/opt/ai-orchestrator"
HOST_NAME="${N8N_HOST:-}"

echo "Deploying from $SRC to $TARGET"
echo "Source: $SRC"
echo "Target: $TARGET"

# Check if target directory exists
if [ ! -d "$TARGET" ]; then
    echo "Creating target directory: $TARGET"
    sudo mkdir -p "$TARGET"
fi

# Create required runtime directories
sudo mkdir -p "$TARGET/postgres"
sudo mkdir -p "$TARGET/redis"
sudo mkdir -p "$TARGET/logs"
sudo mkdir -p "$TARGET/caddy_data"
sudo mkdir -p "$TARGET/caddy_config"

# Sync files, excluding runtime data and secrets
rsync -av --delete \
    --exclude postgres \
    --exclude redis \
    --exclude logs \
    --exclude backups \
    --exclude caddy_data \
    --exclude caddy_config \
    --exclude ".env*" \
    --exclude WORKLOG-* \
    "$SRC/" "$TARGET/"

# Ensure proper permissions
sudo chown -R 1000:1000 "$TARGET/n8n" 2>/dev/null || true
sudo chmod -R 755 "$TARGET/executor"

echo ""
echo "Files deployed. Starting services..."
echo ""

# Start services
cd "$TARGET"
docker compose up -d --build

echo ""
echo "Recreating gateway components to ensure latest Caddyfile and policy-ui assets are applied..."
docker compose up -d --build --force-recreate caddy policy-bundle-server

echo ""
echo "Running post-deploy validation checks..."

# Validate Caddy config inside container
docker exec ai-caddy caddy validate --config /etc/caddy/Caddyfile

# Validate policy-bundle-server can serve policy-ui directly
if ! curl -fsS http://127.0.0.1:8088/policy-ui/ | grep -q "Policy Registry Console"; then
    echo "ERROR: policy-ui is not served correctly on policy-bundle-server (http://127.0.0.1:8088/policy-ui/)" >&2
    exit 1
fi

# Validate caddy route to policy-ui from host path
if [ -n "$HOST_NAME" ]; then
    POLICY_UI_URL="https://${HOST_NAME}/policy-ui/"
else
    POLICY_UI_URL="http://127.0.0.1/policy-ui/"
fi

if ! curl -fsS "$POLICY_UI_URL" | grep -q "Policy Registry Console"; then
    echo "ERROR: policy-ui route check failed via Caddy (${POLICY_UI_URL})" >&2
    echo "Hint: verify DNS/N8N_HOST and Caddy listener accessibility." >&2
    exit 1
fi

echo ""
echo "================================"
echo "Deployment complete!"
echo "================================"
echo ""
echo "Services starting. Check status with:"
echo "  docker ps"
echo ""
echo "View logs with:"
echo "  docker compose logs -f"
echo ""
echo "Validated:"
echo "  - Caddy config syntax"
echo "  - policy-ui direct endpoint (policy-bundle-server)"
echo "  - policy-ui route through Caddy"
echo ""
