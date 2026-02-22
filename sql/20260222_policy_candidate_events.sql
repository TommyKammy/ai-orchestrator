CREATE TABLE IF NOT EXISTS policy_candidate_events (
  id BIGSERIAL PRIMARY KEY,
  task_type TEXT NOT NULL,
  tenant_id TEXT NOT NULL DEFAULT '*',
  scope TEXT NOT NULL DEFAULT '*',
  source TEXT NOT NULL DEFAULT 'seed',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_policy_candidate_events_task_type
  ON policy_candidate_events (task_type);

CREATE INDEX IF NOT EXISTS idx_policy_candidate_events_created_at
  ON policy_candidate_events (created_at DESC);
