# AI Orchestrator Infrastructure

Secure AI orchestration system with isolated code execution sandbox, Kubernetes auto-scaling, workflow automation, and semantic memory.

## Overview

This system provides a complete infrastructure for AI-powered applications with:
- **Isolated Code Execution**: Docker-based sandbox for secure code execution (95% E2B parity)
- **Kubernetes Auto-scaling**: HPA, global load balancing, and session persistence
- **Workflow Automation**: n8n with custom workflows for memory, audit, and execution
- **Semantic Memory**: PostgreSQL + pgvector for persistent AI memory
- **Multi-language Support**: Python, Node.js, R, Go, Rust, Java, C++, and more

## Architecture

```
                    Internet / Clients
                            ↓
                    Caddy (HTTPS, Auth)
                            ↓
                  n8n (Webhooks/Orchestration)
                  ├──────────────┬──────────────┬──────────────┐
                  ↓              ↓              ↓              ↓
         PostgreSQL+pgvector   Redis          OPA PDP    Executor API (internal)
      (memory + audit_events) (cache)   (policy decision)         ↓
                                                           Executor Load Balancer
                                                                    ↓
                                                              Executor Pools
                                                         (K8s/Standalone Sandboxes)
                                                                    ↓
                                                               Redis (state)

  Note: External traffic is terminated at Caddy and routed to n8n.
  Executor endpoints are internal-only and invoked by workflows/services.
```

## Components

| Component | Purpose | Technology |
|-----------|---------|------------|
| **n8n** | Workflow automation | Node.js, Docker |
| **PostgreSQL** | Persistent memory with pgvector | PostgreSQL 16 |
| **Redis** | Short-term cache & session state | Redis 7 |
| **OPA** | Central policy decision point | Open Policy Agent |
| **Executor** | Isolated code execution | Docker/Kubernetes |
| **Caddy** | Reverse proxy with HTTPS | Caddy 2 |

## Executor Sandbox System

### Features

- **12 Language Templates**: Python (data science, ML, NLP), Node.js, R, Go, Rust, Java, C++
- **Visualization Support**: Matplotlib and Plotly chart extraction
- **Session Management**: TTL-based sessions with pooling
- **Security**: Read-only filesystem, no-new-privileges, capability dropping, network isolation
- **Auto-scaling**: Kubernetes HPA with custom metrics
- **Global Load Balancing**: Circuit breaker, health checks, session affinity

### Security Features

- **Container Isolation**: Docker with security hardening
- **Path Traversal Protection**: Comprehensive validation
- **Resource Limits**: CPU, memory, disk quotas enforced
- **Network Isolation**: Disabled by default, opt-in only
- **API Authentication**: Optional API key validation
- **Audit Logging**: Complete execution history

## Quick Start

### Docker Compose (Single Node)

\`\`\`bash
# Clone repository
git clone <repository-url>
cd ai-orchestrator

# Configure environment
cp .env.example .env
# Edit .env with your secrets

# Deploy
./deploy.sh
\`\`\`

### Kubernetes (Production)

\`\`\`bash
# Apply CRDs
kubectl apply -f k8s/config/crd/executor-crd.yaml

# Deploy operator and infrastructure
kubectl apply -f k8s/config/deployment/operator-deployment.yaml
kubectl apply -f k8s/config/deployment/opa-deployment.yaml
kubectl apply -f k8s/config/deployment/network-policies.yaml
kubectl apply -f k8s/config/deployment/resource-quotas.yaml

# Create executor pool
kubectl apply -f - <<EOF
apiVersion: executor.ai-orchestrator.io/v1
kind: ExecutorPool
metadata:
  name: python-data-pool
  namespace: executor-system
spec:
  template: python-data
  minReplicas: 2
  maxReplicas: 20
  targetCPUUtilizationPercentage: 70
  sessionTTL: 300
EOF
\`\`\`

## API Usage

### Direct Execution

\`\`\`bash
curl -X POST http://localhost:8080/execute \\
  -H "Content-Type: application/json" \\
  -H "X-API-Key: \$EXECUTOR_API_KEY" \\
  -d '{
    "tenant_id": "t1",
    "scope": "analysis",
    "code": "import pandas as pd; print(pd.__version__)",
    "template": "python-data"
  }'
\`\`\`

### Session-based Execution

\`\`\`bash
# Create session
curl -X POST http://localhost:8080/session/create \\
  -H "Content-Type: application/json" \\
  -d '{
    "tenant_id": "t1",
    "scope": "project-1",
    "template": "python-data",
    "ttl": 600
  }'

# Execute in session
curl -X POST http://localhost:8080/session/execute \\
  -H "Content-Type: application/json" \\
  -d '{
    "session_id": "<session-id>",
    "code": "import matplotlib.pyplot as plt; plt.plot([1,2,3]); plt.show()"
  }'

# Destroy session
curl -X POST http://localhost:8080/session/destroy \\
  -H "Content-Type: application/json" \\
  -d '{"session_id": "<session-id>"}'
\`\`\`

### Metrics (Policy/Executor)

```bash
# JSON metrics
curl http://localhost:8080/metrics

# Prometheus format
curl http://localhost:8080/metrics/prometheus
```

## Available Templates

| Template | Description | Packages | Network |
|----------|-------------|----------|---------|
| \`default\` | Basic Python | - | No |
| \`python-data\` | Data Science | pandas, numpy, matplotlib, seaborn, scipy, scikit-learn | No |
| \`python-ml\` | Machine Learning | torch, transformers, datasets, accelerate | No |
| \`python-nlp\` | NLP | nltk, spacy, textblob, gensim | No |
| \`python-web\` | Web Scraping | requests, beautifulsoup4, selenium, scrapy | Yes |
| \`node-basic\` | Node.js | npm available | No |
| \`r-stats\` | R Statistics | ggplot2, dplyr, tidyr, readr | No |
| \`go-basic\` | Go | Go toolchain | No |
| \`rust-basic\` | Rust | Cargo toolchain | No |
| \`java-basic\` | Java | JDK 21 | No |
| \`cpp-basic\` | C++ | GCC 13, cmake | No |
| \`minimal\` | Minimal Python | None | No |

## Security

### Security Audit Results

**Overall Rating: GOOD** ✅

- **0 Critical** vulnerabilities found
- **0 High** severity issues
- Comprehensive security documentation in [SECURITY.md](SECURITY.md)
- Full audit report in [SECURITY_AUDIT_REPORT.md](SECURITY_AUDIT_REPORT.md)

### Key Security Features

1. **Container Isolation**
   - Read-only root filesystem
   - No-new-privileges flag
   - All capabilities dropped
   - Non-root user execution

2. **Input Validation**
   - Path traversal prevention
   - File size limits (10MB/file, 100MB total)
   - Timeout enforcement
   - Code execution limits

3. **Kubernetes Security**
   - Network policies (default-deny)
   - Security contexts (non-root, read-only)
   - Resource quotas and limits
   - RBAC with least privilege

4. **API Security**
   - Optional API key authentication
   - Security headers (CSP, HSTS, X-Frame-Options)
   - Error message sanitization in production
   - CORS support

See [SECURITY.md](SECURITY.md) for detailed security documentation.

## Repository Structure

\`\`\`
.
├── docker-compose.yml           # Docker Compose configuration
├── docker-compose.executor.yml  # Executor-specific compose
├── k8s/                        # Kubernetes manifests
│   ├── config/
│   │   ├── crd/               # Custom Resource Definitions
│   │   └── deployment/        # Deployment manifests
│   ├── controllers/           # Operator controllers
│   └── README.md              # K8s deployment guide
├── executor/                   # Executor sandbox system
│   ├── sandbox.py             # Core sandbox implementation
│   ├── api_server.py          # HTTP API server
│   ├── session.py             # Session management
│   ├── filesystem.py          # Secure file operations
│   ├── interpreter.py         # Code interpreter with visualization
│   ├── templates.py           # Environment templates
│   └── README.md              # Executor documentation
├── n8n/
│   └── workflows/             # n8n workflow definitions
├── scripts/                   # Utility scripts
├── SECURITY.md                # Security documentation
└── README.md                  # This file
\`\`\`

## Environment Configuration

Required environment variables:

\`\`\`bash
# Database
POSTGRES_PASSWORD=your_secure_password

# n8n
N8N_ENCRYPTION_KEY=your_64_char_hex_key
N8N_BASIC_AUTH_PASSWORD=your_admin_password
N8N_WEBHOOK_API_KEY=your_64_char_hex_key

# Executor (optional)
EXECUTOR_API_KEY=your_api_key_for_production
EXECUTOR_PRODUCTION=true  # Enable production security features
OPA_URL=http://opa:8181
POLICY_MODE=shadow        # shadow or enforce
POLICY_TIMEOUT_MS=800
POLICY_FAIL_MODE=open     # open or closed

# LLM Providers (optional)
KIMI_API_KEY=your_kimi_key
OPENAI_API_KEY=your_openai_key
\`\`\`

## Development

### Testing Executor

\`\`\`bash
# Test sandbox creation
echo '{"type":"ping","message":"test"}' | docker exec -i ai-executor python /workspace/executor_api.py

# Test via API
curl http://localhost:8080/health
\`\`\`

### Kubernetes Development

\`\`\`bash
# Build operator image
docker build -t executor-operator:latest -f k8s/config/deployment/Dockerfile.operator .

# Build load balancer image
docker build -t executor-load-balancer:latest -f k8s/config/deployment/Dockerfile.loadbalancer .

# Port forward for testing
kubectl port-forward -n executor-system svc/executor-load-balancer 8080:80
\`\`\`

### Database Access

\`\`\`bash
docker exec -it ai-postgres psql -U ai_user -d ai_memory
\`\`\`

### View Logs

\`\`\`bash
# Docker Compose
docker compose logs -f [service-name]

# Kubernetes
kubectl logs -n executor-system -l app.kubernetes.io/component=operator -f
\`\`\`

## CI/CD

GitHub Actions workflows:

- **Workflow Validation**: Validates n8n workflow JSON files
- **Import Testing**: Tests n8n workflow imports
- **Security Scanning**: Automated security checks

Run locally:

\`\`\`bash
# Validate workflows
python3 scripts/validate_slack_workflows.py

# Test imports
bash scripts/ci/n8n_import_test.sh
\`\`\`

## Known Issues

### Slack Signature Verification

n8n 2.7.4 blocks the \`crypto\` module in Code nodes. Temporary workaround:

\`\`\`yaml
environment:
  SLACK_SIG_VERIFY_ENABLED: "false"  # Only for debugging
\`\`\`

See [Security Notice](#security-notice) for details.

## Roadmap

- [x] Phase 1: Core sandbox infrastructure
- [x] Phase 2: Enhanced management (sessions, filesystem, templates)
- [x] Phase 3: Visualization and production deployment
- [x] Phase 4: Kubernetes auto-scaling, load balancing, session persistence
- [ ] Phase 5: GPU support for ML workloads
- [ ] Phase 6: Multi-region federation

## Contributing

1. Review [SECURITY.md](SECURITY.md) before contributing
2. Ensure no secrets are committed (use \`.env.example\` as template)
3. Run security checks: \`grep -r "CHANGE_ME\|password\|secret" . --include="*.yml" --include="*.py"\`
4. Test deployment locally before submitting PR
5. Follow conventional commits style

## License

MIT License

## Support

- Documentation: See \`README.md\` files in each component directory
- Security: See [SECURITY.md](SECURITY.md)
- Issues: Create GitHub issue with detailed description
