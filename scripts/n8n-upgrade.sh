#!/bin/bash
# Upgrade n8n with safety checks

set -e

NEW_VERSION="${1:-2.9.1}"
BACKUP_DIR="$2"

echo "=== n8n Upgrade ==="
echo "Target version: $NEW_VERSION"
echo "Current version: $(docker compose exec -T n8n n8n --version 2>/dev/null || echo 'unknown')"
echo ""

if [ -z "$BACKUP_DIR" ]; then
    echo "ERROR: Backup directory required for safety"
    echo "Usage: $0 <version> <backup-directory>"
    echo "Example: $0 2.9.1 ./backups/n8n-upgrade-20250218-120000"
    exit 1
fi

cd /opt/ai-orchestrator

echo "1. Pre-upgrade checks..."
if [ ! -d "$BACKUP_DIR" ]; then
    echo "   ERROR: Backup directory not found: $BACKUP_DIR"
    exit 1
fi
echo "   Backup verified: $BACKUP_DIR"

echo ""
echo "2. Checking for breaking changes..."
echo "   ⚠️  Review these potential issues:"
echo "      - Code Node environment variable access may be blocked"
echo "      - Some nodes may have behavior changes"
echo "      - Task runners configuration changed (not using runners)"
echo ""
read -p "   Continue with upgrade? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "   Upgrade cancelled"
    exit 0
fi

echo ""
echo "3. Updating docker-compose.yml..."
sed -i "s|n8nio/n8n:[0-9.]*|n8nio/n8n:$NEW_VERSION|g" docker-compose.yml
echo "   Updated to version $NEW_VERSION"

echo ""
echo "4. Pulling new image..."
docker compose pull n8n

echo ""
echo "5. Stopping n8n..."
docker compose stop n8n

echo ""
echo "6. Starting with new version..."
docker compose up -d n8n

echo ""
echo "7. Waiting for startup..."
sleep 10

echo ""
echo "8. Checking health..."
if docker compose ps n8n | grep -q "healthy\|Up"; then
    echo "   n8n is running"
    NEW_VER=$(docker compose exec -T n8n n8n --version 2>/dev/null || echo "unknown")
    echo "   Version: $NEW_VER"
else
    echo "   WARNING: n8n may not be healthy"
    docker compose logs n8n --tail 20
fi

echo ""
echo "=== UPGRADE COMPLETE ==="
echo "New version: $NEW_VERSION"
echo ""
echo "If issues occur, rollback with:"
echo "  ./scripts/n8n-rollback.sh $BACKUP_DIR"
