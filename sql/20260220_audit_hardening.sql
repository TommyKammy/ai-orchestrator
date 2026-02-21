BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

ALTER TABLE audit_events
  ADD COLUMN IF NOT EXISTS request_id TEXT,
  ADD COLUMN IF NOT EXISTS policy_id TEXT,
  ADD COLUMN IF NOT EXISTS policy_version TEXT,
  ADD COLUMN IF NOT EXISTS policy_reason TEXT,
  ADD COLUMN IF NOT EXISTS risk_score INTEGER,
  ADD COLUMN IF NOT EXISTS prev_hash TEXT,
  ADD COLUMN IF NOT EXISTS event_hash TEXT;

CREATE OR REPLACE FUNCTION audit_events_immutable_guard()
RETURNS trigger AS $$
BEGIN
  RAISE EXCEPTION 'audit_events is append-only';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_audit_events_block_update ON audit_events;
CREATE TRIGGER trg_audit_events_block_update
BEFORE UPDATE ON audit_events
FOR EACH ROW
EXECUTE FUNCTION audit_events_immutable_guard();

DROP TRIGGER IF EXISTS trg_audit_events_block_delete ON audit_events;
CREATE TRIGGER trg_audit_events_block_delete
BEFORE DELETE ON audit_events
FOR EACH ROW
EXECUTE FUNCTION audit_events_immutable_guard();

CREATE OR REPLACE FUNCTION audit_events_chain_hash()
RETURNS trigger AS $$
DECLARE
  latest_hash TEXT;
BEGIN
  SELECT event_hash
  INTO latest_hash
  FROM audit_events
  ORDER BY created_at DESC
  LIMIT 1;

  NEW.prev_hash := COALESCE(NEW.prev_hash, latest_hash, '');
  NEW.event_hash := encode(
    digest(
      COALESCE(NEW.prev_hash, '') ||
      COALESCE(NEW.actor, '') ||
      COALESCE(NEW.action, '') ||
      COALESCE(NEW.target, '') ||
      COALESCE(NEW.decision, '') ||
      COALESCE(NEW.policy_id, '') ||
      COALESCE(NEW.policy_version, '') ||
      COALESCE(NEW.request_id, '') ||
      COALESCE(NEW.created_at::text, now()::text),
      'sha256'
    ),
    'hex'
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_audit_events_chain_hash ON audit_events;
CREATE TRIGGER trg_audit_events_chain_hash
BEFORE INSERT ON audit_events
FOR EACH ROW
EXECUTE FUNCTION audit_events_chain_hash();

COMMIT;
