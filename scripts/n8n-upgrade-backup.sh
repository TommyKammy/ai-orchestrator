#!/bin/bash
# n8n-upgrade-backup.sh - Run this BEFORE upgrading

set -e

echo "=== n8n Pre-Upgrade Backup ==="
echo "Timestamp: $(date)"
echo ""

cd /opt/ai-orchestrator

# Create backup directory
BACKUP_DIR="./backups/n8n-upgrade-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"

echo "1. Stopping n8n container to ensure data consistency..."
docker compose stop n8n

echo ""
echo "2. Backing up PostgreSQL database..."
docker compose exec -T postgres pg_dump -U ai_user ai_memory > "$BACKUP_DIR/database.sql"
echo "   Database backup: $BACKUP_DIR/database.sql ($(du -h "$BACKUP_DIR/database.sql" | cut -f1))"

echo ""
echo "3. Backing up n8n data volume..."
tar czf "$BACKUP_DIR/n8n-data.tar.gz" ./n8n/
echo "   n8n data backup: $BACKUP_DIR/n8n-data.tar.gz ($(du -h "$BACKUP_DIR/n8n-data.tar.gz" | cut -f1))"

echo ""
echo "4. Backing up workflow files..."
cp -r ./n8n/workflows-v3 "$BACKUP_DIR/workflows-backup"
echo "   Workflows backup: $BACKUP_DIR/workflows-backup"

echo ""
echo "5. Saving current docker-compose.yml..."
cp docker-compose.yml "$BACKUP_DIR/docker-compose.yml.backup"
echo "   Compose backup: $BACKUP_DIR/docker-compose.yml.backup"

echo ""
echo "6. Recording current version..."
docker compose exec n8n n8n --version > "$BACKUP_DIR/version.txt" 2>/dev/null || echo "2.7.5" > "$BACKUP_DIR/version.txt"
echo "   Current version: $(cat "$BACKUP_DIR/version.txt")"

echo ""
echo "7. Starting n8n back up..."
docker compose start n8n

echo ""
echo "=== BACKUP COMPLETE ==="
echo "Backup location: $BACKUP_DIR"
echo ""
echo "To rollback if upgrade fails:"
echo "  cd /opt/ai-orchestrator"
echo "  docker compose down"
echo "  docker compose exec postgres psql -U ai_user -c 'DROP DATABASE ai_memory;'"
echo "  docker compose exec postgres psql -U ai_user -c 'CREATE DATABASE ai_memory;'"
echo "  cat $BACKUP_DIR/database.sql | docker compose exec -T postgres psql -U ai_user ai_memory"
echo "  tar xzf $BACKUP_DIR/n8n-data.tar.gz"
echo "  cp $BACKUP_DIR/docker-compose.yml.backup docker-compose.yml"
echo "  docker compose up -d"
