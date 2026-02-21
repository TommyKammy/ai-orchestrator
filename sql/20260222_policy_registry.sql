-- Policy registry tables for CE Phase 1

CREATE TABLE IF NOT EXISTS policy_workflows (
  id BIGSERIAL PRIMARY KEY,
  workflow_id TEXT NOT NULL,
  task_type TEXT NOT NULL,
  tenant_id TEXT NOT NULL DEFAULT '*',
  scope_pattern TEXT NOT NULL DEFAULT '*',
  constraints_jsonb JSONB NOT NULL DEFAULT '{}'::jsonb,
  enabled BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (workflow_id, task_type, tenant_id, scope_pattern)
);

CREATE TABLE IF NOT EXISTS policy_revisions (
  id BIGSERIAL PRIMARY KEY,
  revision_id TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL CHECK (status IN ('draft', 'published', 'archived')),
  payload_jsonb JSONB NOT NULL,
  notes TEXT,
  author TEXT NOT NULL DEFAULT 'system',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  published_at TIMESTAMPTZ,
  is_active BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE IF NOT EXISTS policy_publish_logs (
  id BIGSERIAL PRIMARY KEY,
  revision_id TEXT NOT NULL,
  action TEXT NOT NULL,
  actor TEXT NOT NULL,
  result TEXT NOT NULL,
  details_jsonb JSONB NOT NULL DEFAULT '{}'::jsonb,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_policy_workflows_enabled ON policy_workflows (enabled);
CREATE INDEX IF NOT EXISTS idx_policy_workflows_task_type ON policy_workflows (task_type);
CREATE INDEX IF NOT EXISTS idx_policy_revisions_status ON policy_revisions (status);
CREATE INDEX IF NOT EXISTS idx_policy_publish_logs_revision ON policy_publish_logs (revision_id);

CREATE OR REPLACE FUNCTION set_updated_at_policy_workflows()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_policy_workflows_updated_at ON policy_workflows;
CREATE TRIGGER trg_policy_workflows_updated_at
BEFORE UPDATE ON policy_workflows
FOR EACH ROW
EXECUTE FUNCTION set_updated_at_policy_workflows();
