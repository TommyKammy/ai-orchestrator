#!/bin/bash
# Deployment script for AI Orchestrator updates
# Run this script on the production server

set -e

echo "=== AI Orchestrator Deployment ==="
echo "Date: $(date)"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Source directory (GitHub repo)
SOURCE_DIR="/home/tommy/.dev/ai-orchestrator"
RUNTIME_DIR="/opt/ai-orchestrator"

echo -e "${YELLOW}Step 1: Copying updated files...${NC}"

# Copy Caddyfile with rate limiting
echo "  - Copying Caddyfile (with rate limiting)..."
cp "$SOURCE_DIR/Caddyfile" "$RUNTIME_DIR/Caddyfile"

# Copy updated workflows
echo "  - Copying workflow files..."
mkdir -p "$RUNTIME_DIR/n8n/workflows-v3"
cp "$SOURCE_DIR/n8n/workflows/01_memory_ingest_v3_cached.json" "$RUNTIME_DIR/n8n/workflows-v3/"
cp "$SOURCE_DIR/n8n/workflows/02_vector_search.json" "$RUNTIME_DIR/n8n/workflows-v3/"

echo -e "${GREEN}✓ Files copied${NC}"
echo ""

echo -e "${YELLOW}Step 2: Reloading Caddy...${NC}"
docker exec ai-caddy caddy reload --config /etc/caddy/Caddyfile
echo -e "${GREEN}✓ Caddy reloaded${NC}"
echo ""

echo -e "${YELLOW}Step 3: Importing workflows to n8n...${NC}"
echo "  Note: Workflows must be imported manually through n8n UI"
echo "  URL: https://n8n-s-app01.tmcast.net"
echo "  Steps:"
echo "    1. Workflows → Import from File"
echo "    2. Select: $RUNTIME_DIR/n8n/workflows-v3/01_memory_ingest_v3_cached.json"
echo "    3. Select: $RUNTIME_DIR/n8n/workflows-v3/02_vector_search.json"
echo "    4. Save and Activate each workflow"
echo "    5. Deactivate old workflows to avoid conflicts"
echo ""

echo -e "${YELLOW}Step 4: Verifying deployment...${NC}"

# Check Caddy config
echo "  - Checking Caddy..."
if docker ps | grep -q "ai-caddy"; then
    echo -e "${GREEN}✓ Caddy running${NC}"
else
    echo -e "${RED}✗ Caddy not running${NC}"
fi

# Check n8n
echo "  - Checking n8n..."
if docker ps | grep -q "ai-n8n"; then
    echo -e "${GREEN}✓ n8n running${NC}"
else
    echo -e "${RED}✗ n8n not running${NC}"
fi

# Check database
echo "  - Checking PostgreSQL..."
if docker exec ai-postgres pg_isready -U ai_user >/dev/null 2>&1; then
    echo -e "${GREEN}✓ PostgreSQL ready${NC}"
else
    echo -e "${RED}✗ PostgreSQL not ready${NC}"
fi

echo ""
echo -e "${GREEN}=== Deployment Complete ===${NC}"
echo ""
echo "Next steps:"
echo "  1. Import workflows through n8n UI"
echo "  2. Test E2E: curl -X POST https://n8n-s-app01.tmcast.net/webhook/memory/ingest-v3"
echo "  3. Check logs: docker logs ai-caddy | tail -50"
echo ""

