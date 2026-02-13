#!/bin/bash
set -e

SRC="$(cd "$(dirname "$0")" && pwd)"
TARGET="/opt/ai-orchestrator"

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
docker compose up -d

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
