-- pgvector Monitoring Script
-- Run this script periodically to monitor pgvector health and performance
-- Usage: psql -U ai_user -d ai_memory -f monitor_pgvector.sql

\echo '=== pgvector Monitoring Report ==='
\echo ''
\echo 'Timestamp:' :'TIMESTAMP'
\echo ''

-- =====================================================
-- 1. Vector Count and Storage
-- =====================================================

\echo '--- Vector Storage Statistics ---'

SELECT 
    COUNT(*) AS total_vectors,
    COUNT(DISTINCT tenant_id) AS unique_tenants,
    COUNT(DISTINCT scope) AS unique_scopes,
    MIN(created_at) AS oldest_vector,
    MAX(created_at) AS newest_vector,
    pg_size_pretty(pg_total_relation_size('memory_vectors')) AS total_size
FROM memory_vectors;

\echo ''

-- =====================================================
-- 2. Index Health
-- =====================================================

\echo '--- Index Statistics ---'

SELECT 
    indexname AS index_name,
    idx_scan AS index_scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE tablename = 'memory_vectors'
ORDER BY idx_scan DESC;

\echo ''

-- =====================================================
-- 3. Table Bloat Check
-- =====================================================

\echo '--- Table Health ---'

SELECT 
    relname AS table_name,
    n_live_tup AS live_tuples,
    n_dead_tup AS dead_tuples,
    CASE 
        WHEN n_live_tup > 0 THEN round(100.0 * n_dead_tup / n_live_tup, 2)
        ELSE 0
    END AS dead_tuple_pct,
    last_vacuum,
    last_autovacuum,
    last_analyze
FROM pg_stat_user_tables
WHERE relname = 'memory_vectors';

\echo ''

-- =====================================================
-- 4. Scope Distribution
-- =====================================================

\echo '--- Top 10 Scopes by Vector Count ---'

SELECT 
    scope,
    COUNT(*) AS vector_count,
    MIN(created_at) AS first_seen,
    MAX(created_at) AS last_seen
FROM memory_vectors
GROUP BY scope
ORDER BY vector_count DESC
LIMIT 10;

\echo ''

-- =====================================================
-- 5. Recent Activity
-- =====================================================

\echo '--- Recent Vectors (Last 24 Hours) ---'

SELECT 
    COUNT(*) AS vectors_last_24h
FROM memory_vectors
WHERE created_at > NOW() - INTERVAL '24 hours';

\echo ''

\echo '--- Hourly Ingest Rate (Last 7 Days) ---'

SELECT 
    DATE_TRUNC('hour', created_at) AS hour,
    COUNT(*) AS vectors_ingested
FROM memory_vectors
WHERE created_at > NOW() - INTERVAL '7 days'
GROUP BY DATE_TRUNC('hour', created_at)
ORDER BY hour DESC
LIMIT 24;

\echo ''

-- =====================================================
-- 6. Audit Events Summary
-- =====================================================

\echo '--- Audit Events Summary ---'

SELECT 
    action,
    COUNT(*) AS event_count,
    COUNT(DISTINCT target) AS unique_targets,
    MAX(created_at) AS last_event
FROM audit_events
GROUP BY action
ORDER BY event_count DESC;

\echo ''

-- =====================================================
-- 7. Performance Metrics
-- =====================================================

\echo '--- Cache Hit Ratio ---'

SELECT 
    relname AS table_name,
    CASE 
        WHEN heap_blks_hit + heap_blks_read > 0 
        THEN round(100.0 * heap_blks_hit / (heap_blks_hit + heap_blks_read), 2)
        ELSE 0 
    END AS cache_hit_ratio_pct
FROM pg_statio_user_tables
WHERE relname = 'memory_vectors';

\echo ''

-- =====================================================
-- 8. Index Usage Analysis
-- =====================================================

\echo '--- Index Usage Ratio ---'

WITH table_stats AS (
    SELECT 
        n_tup_ins AS inserts,
        n_tup_upd AS updates,
        n_tup_del AS deletes,
        n_live_tup AS live_tuples,
        n_dead_tup AS dead_tuples,
        seq_scan,
        seq_tup_read,
        idx_scan,
        idx_tup_fetch
    FROM pg_stat_user_tables
    WHERE relname = 'memory_vectors'
)
SELECT 
    seq_scan AS sequential_scans,
    idx_scan AS index_scans,
    CASE 
        WHEN seq_scan + idx_scan > 0 
        THEN round(100.0 * idx_scan / (seq_scan + idx_scan), 2)
        ELSE 0 
    END AS index_usage_pct,
    live_tuples,
    dead_tuples,
    CASE 
        WHEN live_tuples > 0 
        THEN round(100.0 * dead_tuples / live_tuples, 2)
        ELSE 0 
    END AS bloat_pct
FROM table_stats;

\echo ''

-- =====================================================
-- 9. Vector Dimension Validation
-- =====================================================

\echo '--- Vector Dimension Check ---'

SELECT 
    'memory_vectors' AS table_name,
    'embedding' AS column_name,
    'vector(1536)' AS expected_type,
    pg_typeof(embedding) AS actual_type,
    CASE 
        WHEN pg_typeof(embedding)::text = 'vector(1536)' 
        THEN 'OK' 
        ELSE 'MISMATCH!' 
    END AS status
FROM memory_vectors
LIMIT 1;

\echo ''

-- =====================================================
-- 10. Alerts / Anomalies
-- =====================================================

\echo '--- Alerts ---'

-- Check for potential issues
SELECT 
    'dead_tuples_high' AS alert_type,
    CASE 
        WHEN n_dead_tup > n_live_tup * 0.2 
        THEN 'WARNING: Dead tuples exceed 20% of live tuples - consider VACUUM'
        ELSE 'OK'
    END AS status
FROM pg_stat_user_tables
WHERE relname = 'memory_vectors'

UNION ALL

SELECT 
    'index_not_used' AS alert_type,
    CASE 
        WHEN idx_scan = 0 AND n_live_tup > 1000
        THEN 'WARNING: Index not being used despite large table - check queries'
        ELSE 'OK'
    END AS status
FROM pg_stat_user_tables
WHERE relname = 'memory_vectors'

UNION ALL

SELECT 
    'cache_hit_low' AS alert_type,
    CASE 
        WHEN heap_blks_hit + heap_blks_read > 0 
             AND heap_blks_hit::float / (heap_blks_hit + heap_blks_read) < 0.95
        THEN 'WARNING: Cache hit ratio below 95% - consider more RAM'
        ELSE 'OK'
    END AS status
FROM pg_statio_user_tables
WHERE relname = 'memory_vectors';

\echo ''
\echo '=== End of Report ==='
