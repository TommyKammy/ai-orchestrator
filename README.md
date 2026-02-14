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

## ⚠️ Known Issues / Workarounds

### Slack Signature Verification Temporarily Disabled

**Issue**: n8n 2.7.4 blocks the `crypto` module in Code nodes due to security restrictions.
**Impact**: Slack signature verification cannot use `require('crypto')`.
**Workaround**: Set `SLACK_SIG_VERIFY_ENABLED=false` in docker-compose.yml to bypass verification.

```yaml
environment:
  # Slack signature verification (TEMPORARILY DISABLED)
  SLACK_SIG_VERIFY_ENABLED: "false"
```

**⚠️ SECURITY WARNING**: This disables Slack request signature verification. Only use this in controlled environments or for debugging. Re-enable after:
- Upgrading n8n to a version that allows crypto module
- Moving signature verification to an external service
- Using n8n's built-in Slack trigger node instead of custom Code node

**To re-enable**: Set `SLACK_SIG_VERIFY_ENABLED=true` (default) and ensure crypto module is available.

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

## Development Workflow

### Pre-commit Hooks (Recommended)

Install git hooks to validate workflows before committing:

```bash
./tools/install-git-hooks.sh
```

This installs a pre-commit hook that:
- Validates Slack workflow JSON files
- Ensures "Immediate ACK" node is correctly configured
- Prevents the `{"myField":"value"}` placeholder regression

To run validation manually:

```bash
python3 scripts/validate_slack_workflows.py
```

### CI Validation

GitHub Actions runs validation on every push and PR:
- Validates Slack workflow configurations
- Fails CI if ACK node is broken or uses expressions

See `.github/workflows/validate-workflows.yml`

### CI Import Test (Extended Validation)

In addition to JSON validation, CI also tests actual n8n import:

```bash
bash scripts/ci/n8n_import_test.sh
```

This test:
1. Starts a temporary n8n container
2. Imports workflows from `n8n/workflows-v3/`
3. Verifies webhook registration for `/webhook/slack-command`
4. Ensures import-time transformations don't break workflows

Run locally before pushing:
```bash
python3 scripts/validate_slack_workflows.py  # JSON validation
bash scripts/ci/n8n_import_test.sh          # Import test
```

### CI Signature Verification Bypass (Safe)

For CI testing only, the workflow supports disabling Slack signature verification via environment variable:

```bash
SLACK_SIG_VERIFY_ENABLED=false  # CI only - skips signature check
SLACK_SIG_VERIFY_ENABLED=true   # Production default - verifies signatures
```

This allows CI to test the webhook execution path without real Slack secrets. Production remains fully verified.

### NO-BRAIN Fallback Behavior

When no LLM provider API keys are configured, the system returns a clear fallback message instead of failing silently:

**Detection:** The `chat_router_v1` workflow checks for `KIMI_API_KEY` and `OPENAI_API_KEY` environment variables before attempting to call any brain provider.

**Fallback Response:**
```json
{
  "status": "no_brain_configured",
  "provider": "none",
  "answer": "⚠️ AI brain is not configured yet.\n\nPlease configure one of the following environment variables:\n- KIMI_API_KEY\n- OPENAI_API_KEY\n\nThe system infrastructure is working correctly, but no LLM provider is available."
}
```

**Configuration:**
Add one of these to your `.env` file:
```bash
# Option 1: Kimi (Moonshot AI)
KIMI_API_KEY=your_kimi_api_key_here
KIMI_BASE_URL=https://api.moonshot.cn/v1

# Option 2: OpenAI
OPENAI_API_KEY=your_openai_api_key_here
OPENAI_BASE_URL=https://api.openai.com/v1
```

The system works without LLM keys for testing infrastructure, but will return the fallback message for all chat requests until configured.

### Slack Integration Note

When exporting Slack workflow from n8n, ensure the "Immediate ACK" node uses **hard-coded JSON**, not expressions:

```json
{"response_type": "ephemeral", "text": "Processing your request..."}
```

Using expression mode (e.g., `={{JSON.stringify(...)}}`) causes n8n to fall back to `{"myField":"value"}` on import, breaking Slack responses.
