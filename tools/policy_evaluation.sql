-- Policy Evaluation Dashboard Queries
-- Use against ai_memory database to evaluate policy quality before enforce mode.

-- 1) Decision distribution (last 7 days)
SELECT
  decision,
  COUNT(*) AS events
FROM audit_events
WHERE created_at >= NOW() - INTERVAL '7 days'
  AND action IN ('executor_run', 'memory_write')
GROUP BY decision
ORDER BY events DESC;

-- 2) Requires-approval rate by day
SELECT
  DATE(created_at) AS day,
  COUNT(*) FILTER (WHERE decision = 'requires_approval') AS requires_approval_count,
  COUNT(*) AS total_count,
  ROUND(
    100.0 * COUNT(*) FILTER (WHERE decision = 'requires_approval') / NULLIF(COUNT(*), 0),
    2
  ) AS requires_approval_rate_pct
FROM audit_events
WHERE created_at >= NOW() - INTERVAL '14 days'
  AND action IN ('executor_run', 'memory_write')
GROUP BY DATE(created_at)
ORDER BY day DESC;

-- 3) Deny rate by scope
SELECT
  target AS scope,
  COUNT(*) FILTER (WHERE decision = 'denied') AS denied_count,
  COUNT(*) AS total_count,
  ROUND(
    100.0 * COUNT(*) FILTER (WHERE decision = 'denied') / NULLIF(COUNT(*), 0),
    2
  ) AS denied_rate_pct
FROM audit_events
WHERE created_at >= NOW() - INTERVAL '14 days'
  AND action IN ('executor_run', 'memory_write')
GROUP BY target
HAVING COUNT(*) >= 5
ORDER BY denied_rate_pct DESC, total_count DESC;

-- 4) Policy engine availability signals
-- Looks for fallback/OPA unavailable signals in payload.
SELECT
  DATE(created_at) AS day,
  COUNT(*) FILTER (
    WHERE payload_jsonb::text ILIKE '%policy_unavailable%'
       OR payload_jsonb::text ILIKE '%fallback%'
  ) AS policy_unavailable_events,
  COUNT(*) AS total_policy_events
FROM audit_events
WHERE created_at >= NOW() - INTERVAL '14 days'
  AND action IN ('executor_run', 'memory_write')
GROUP BY DATE(created_at)
ORDER BY day DESC;

-- 5) Approval SLA (request -> approval delta by request_id)
WITH requests AS (
  SELECT
    payload_jsonb->>'request_id' AS req_id,
    MIN(created_at) AS requested_at
  FROM audit_events
  WHERE decision = 'requires_approval'
    AND payload_jsonb->>'request_id' IS NOT NULL
    AND payload_jsonb->>'request_id' <> ''
  GROUP BY payload_jsonb->>'request_id'
),
approvals AS (
  SELECT
    COALESCE(target, payload_jsonb->>'request_id') AS req_id,
    MIN(created_at) AS approved_at
  FROM audit_events
  WHERE action = 'policy_approval'
    AND COALESCE(target, payload_jsonb->>'request_id') IS NOT NULL
    AND COALESCE(target, payload_jsonb->>'request_id') <> ''
  GROUP BY COALESCE(target, payload_jsonb->>'request_id')
)
SELECT
  r.req_id AS request_id,
  r.requested_at,
  a.approved_at,
  EXTRACT(EPOCH FROM (a.approved_at - r.requested_at)) AS approval_latency_seconds
FROM requests r
LEFT JOIN approvals a ON a.req_id = r.req_id
ORDER BY r.requested_at DESC
LIMIT 200;
