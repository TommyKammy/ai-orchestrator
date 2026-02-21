#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_JSON="${ROOT_DIR}/policy/opa/data.json"
MIGRATION_SQL="${ROOT_DIR}/sql/20260222_policy_registry.sql"

if ! command -v docker >/dev/null 2>&1; then
  echo "docker command not found" >&2
  exit 1
fi

if [[ ! -f "${DATA_JSON}" ]]; then
  echo "missing ${DATA_JSON}" >&2
  exit 1
fi

if [[ ! -f "${MIGRATION_SQL}" ]]; then
  echo "missing ${MIGRATION_SQL}" >&2
  exit 1
fi

echo "Applying schema migration..."
docker exec -i ai-postgres psql -U ai_user -d ai_memory < "${MIGRATION_SQL}"

echo "Seeding policy_workflows from policy/opa/data.json..."
if ! command -v jq >/dev/null 2>&1; then
  echo "jq command not found" >&2
  exit 1
fi

while IFS= read -r task_type; do
  [[ -z "${task_type}" ]] && continue
  esc_task_type="${task_type//\'/\'\'}"
  docker exec -i ai-postgres psql -U ai_user -d ai_memory -v ON_ERROR_STOP=1 -c \
    "INSERT INTO policy_workflows (workflow_id, task_type, tenant_id, scope_pattern, constraints_jsonb, enabled)
     VALUES ('*', '${esc_task_type}', '*', '*', '{}'::jsonb, true)
     ON CONFLICT (workflow_id, task_type, tenant_id, scope_pattern) DO NOTHING;"
done < <(jq -r '.policy.allowed_task_types[]? // empty' "${DATA_JSON}")

echo "seed complete"
