#!/bin/bash
# Rollback n8n to previous version - use if upgrade fails

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <backup-directory>"
    echo "Example: $0 ./backups/n8n-upgrade-20250218-120000"
    exit 1
fi

BACKUP_DIR="$1"

if [ ! -d "$BACKUP_DIR" ]; then
    echo "Error: Backup directory not found: $BACKUP_DIR"
    exit 1
fi

echo "=== n8n Rollback ==="
echo "Backup: $BACKUP_DIR"
echo ""

cd /opt/ai-orchestrator

echo "1. Stopping all services..."
docker compose down

echo ""
echo "2. Restoring database..."
docker compose up -d postgres
echo "   Waiting for PostgreSQL..."
sleep 5
docker compose exec postgres psql -U ai_user -c "DROP DATABASE IF EXISTS ai_memory;"
docker compose exec postgres psql -U ai_user -c "CREATE DATABASE ai_memory;"
cat "$BACKUP_DIR/database.sql" | docker compose exec -T postgres psql -U ai_user ai_memory
echo "   Database restored"

echo ""
echo "3. Restoring n8n data..."
tar xzf "$BACKUP_DIR/n8n-data.tar.gz"
echo "   n8n data restored"

echo ""
echo "4. Restoring docker-compose.yml..."
cp "$BACKUP_DIR/docker-compose.yml.backup" docker-compose.yml
echo "   Compose config restored"

echo ""
echo "5. Starting services..."
docker compose up -d

echo ""
echo "=== ROLLBACK COMPLETE ==="
echo "n8n restored to version: $(cat "$BACKUP_DIR/version.txt")"
echo "Check status: docker compose ps"
