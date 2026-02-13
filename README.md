# AI Orchestrator Infrastructure

Secure AI orchestration system using Docker Compose with n8n workflow automation, PostgreSQL semantic memory, Redis caching, and isolated executor sandbox.

## Architecture

```
Internet
    ↓
Caddy (HTTPS, API Key Auth)
    ↓
n8n (Workflow Orchestration)
    ↓
├─→ PostgreSQL + pgvector (Persistent Memory)
├─→ Redis (Short-term Cache)
└─→ Executor (Isolated Task Runner)
```

## Components

| Component | Purpose | Security Features |
|-----------|---------|-------------------|
| **n8n** | Workflow automation | Basic auth, webhook API keys |
| **PostgreSQL** | Persistent storage with pgvector | Localhost-only access |
| **Redis** | Short-term caching | Localhost-only access |
| **Executor** | Isolated task execution | Network isolation, read-only filesystem, no-new-privileges |
| **Caddy** | Reverse proxy with HTTPS | Automatic TLS, API key validation |

## Security Features

- **Executor Network Isolation**: `network_mode: "none"` prevents all network access
- **Read-Only Filesystem**: Executor container cannot modify its filesystem
- **No-New-Privileges**: Prevents privilege escalation
- **Webhook Authentication**: API key required for all webhook endpoints
- **Environment-Based Secrets**: No hardcoded credentials
- **Append-Only Audit Logging**: Tamper-proof audit trail
- **Task Allowlist**: Executor only accepts predefined task types

## Repository Structure

```
.
├── docker-compose.yml      # Infrastructure configuration
├── Caddyfile              # Reverse proxy configuration
├── deploy.sh              # Deployment script
├── .env.example           # Environment template
├── executor/
│   ├── executor_api.py    # Secure executor wrapper
│   └── run_task.py        # Task handler with allowlist
└── n8n/workflows/
    ├── 01_memory_ingest.json      # Memory storage workflow
    ├── 02_vector_search.json      # Semantic search workflow
    ├── 03_audit_append.json       # Audit logging workflow
    ├── 04_executor_dispatch.json  # Task execution workflow
    └── README.md                   # Workflow documentation
```

## Quick Start

### 1. Clone and Configure

```bash
git clone <repository-url>
cd ai-orchestrator
cp .env.example .env
```

### 2. Generate Secrets

Edit `.env` and replace all `CHANGE_ME` values with secure random strings:

```bash
# Generate secure passwords
openssl rand -base64 32
openssl rand -hex 32
```

Required environment variables:
- `POSTGRES_PASSWORD` - Database password
- `N8N_ENCRYPTION_KEY` - n8n encryption key (hex, 64 chars)
- `N8N_BASIC_AUTH_PASSWORD` - n8n admin password
- `N8N_WEBHOOK_API_KEY` - Webhook API key (hex, 64 chars)
- `N8N_HOST` - Your domain (e.g., n8n.example.com)

### 3. Deploy

```bash
./deploy.sh
```

### 4. Verify

```bash
docker ps
```

All 5 services should be running:
- ai-postgres
- ai-redis
- ai-n8n
- ai-executor
- ai-caddy

## API Usage

### Webhook Authentication

All webhook endpoints require the `X-API-Key` header:

```bash
curl -X POST https://your-domain/webhook/memory/ingest \
  -H "Content-Type: application/json" \
  -H "X-API-Key: $N8N_WEBHOOK_API_KEY" \
  -d '{"tenant_id":"t1","scope":"user:123","text":"Hello","source":"api"}'
```

### Available Workflows

| Workflow | Endpoint | Purpose |
|----------|----------|---------|
| Memory Ingest | `/webhook/memory/ingest` | Store facts and memories |
| Vector Search | `/webhook/memory/search` | Semantic search with pgvector |
| Audit Append | `/webhook/audit/append` | Log audit events |
| Executor Run | `/webhook/executor/run` | Execute allowed tasks |

## Security Notice

**NEVER commit the following to Git:**
- `.env` files
- Any file containing real passwords or API keys
- Runtime data directories (`postgres/`, `redis/`, `logs/`)
- SSL certificates (`caddy_data/`)

This repository is configured with `.gitignore` to prevent accidental commits of sensitive data.

## Deployment

The `deploy.sh` script safely deploys to production:

1. Creates required runtime directories
2. Syncs source files (excluding secrets and runtime data)
3. Sets proper permissions
4. Restarts services with `docker compose`

## Development

### Testing Executor

```bash
echo '{"type":"ping","message":"test"}' | docker exec -i ai-executor python /workspace/executor_api.py
```

### Database Access

```bash
docker exec -it ai-postgres psql -U ai_user -d ai_memory
```

### View Logs

```bash
docker compose logs -f [service-name]
```

## License

MIT License

## Contributing

1. Ensure no secrets are committed
2. Run security checks: `grep -r "CHANGE_ME\|password\|secret" . --include="*.yml" --include="*.py"`
3. Test deployment locally before submitting PR
