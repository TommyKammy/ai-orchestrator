-- pgvector Query Performance Tuning Script
-- Run this in PostgreSQL to optimize vector similarity search performance

-- =====================================================
-- IVFFlat Probes Configuration
-- =====================================================
-- The probes parameter controls how many lists are searched during queries
-- Higher probes = better recall (accuracy) but slower queries
-- Lower probes = faster queries but may miss some results

-- Default: probes = lists (searches all lists for perfect recall)
-- Fast: probes = 10 (good for large datasets where speed matters)
-- Balanced: probes = lists / 2

-- Set probes for current session
SET ivfflat.probes = 10;

-- Check current probes setting
SHOW ivfflat.probes;

-- =====================================================
-- View Current Index Configuration
-- =====================================================

-- Check pgvector indexes
SELECT 
    schemaname,
    tablename,
    indexname,
    indexdef
FROM pg_indexes 
WHERE indexname LIKE '%embedding%'
ORDER BY tablename;

-- Check index statistics
SELECT 
    indexrelname AS index_name,
    idx_scan AS index_scans,
    idx_tup_read AS tuples_read,
    idx_tup_fetch AS tuples_fetched
FROM pg_stat_user_indexes 
WHERE indexrelname LIKE '%embedding%'
ORDER BY idx_scan DESC;

-- =====================================================
-- Query Performance Test
-- =====================================================

-- Get a sample embedding for testing
\set sample_embedding (SELECT embedding::text FROM memory_vectors LIMIT 1)

-- Test query with EXPLAIN ANALYZE
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
SELECT 
    id, 
    scope, 
    content, 
    (embedding <=> :'sample_embedding'::vector) AS cosine_distance
FROM memory_vectors
ORDER BY embedding <=> :'sample_embedding'::vector
LIMIT 5;

-- =====================================================
-- Recommended Probes Settings by Dataset Size
-- =====================================================

/*
Dataset Size    | Lists | Recommended Probes | Recall | Speed
----------------|-------|-------------------|--------|-------
1K vectors      | 50    | 10                | ~95%   | Fast
10K vectors     | 100   | 10-20             | ~95%   | Fast
100K vectors    | 316   | 30-50             | ~95%   | Medium
1M vectors      | 1000  | 100               | ~95%   | Medium
10M vectors     | 2000  | 200               | ~95%   | Slower

Formula: probes ≈ sqrt(row_count) / 3 for ~95% recall
*/

-- =====================================================
-- Production Query Template with Optimized Probes
-- =====================================================

-- Set optimal probes for tenant-scoped search
SET ivfflat.probes = 10;

-- Production vector search query
-- Returns top-k most similar vectors for a tenant/scope combination
SELECT 
    id,
    scope,
    content,
    tags,
    source,
    created_at,
    (embedding <=> :query_embedding::vector) AS cosine_distance
FROM memory_vectors
WHERE tenant_id = :tenant_id 
  AND scope = :scope
ORDER BY embedding <=> :query_embedding::vector
LIMIT :k;

-- =====================================================
-- Alternative: HNSW Index (for very large datasets)
-- =====================================================

-- For datasets > 100K vectors, consider HNSW instead of IVFFlat
-- HNSW generally provides better performance at scale

/*
-- Create HNSW index (uncomment if needed)
DROP INDEX IF EXISTS idx_memory_vectors_embedding_hnsw;

CREATE INDEX idx_memory_vectors_embedding_hnsw
ON memory_vectors 
USING hnsw (embedding vector_cosine_ops)
WITH (
    m = 16,              -- number of connections per layer
    ef_construction = 64 -- build-time accuracy tradeoff
);

-- Set HNSW query-time parameter
SET hnsw.ef_search = 100;  -- higher = better recall, slower
*/

-- =====================================================
-- Monitoring Queries
-- =====================================================

-- Check if index is being used
SELECT 
    schemaname,
    tablename,
    indexname,
    idx_scan,
    pg_size_pretty(pg_relation_size(indexrelid)) AS index_size
FROM pg_stat_user_indexes
WHERE indexname LIKE '%embedding%'
ORDER BY idx_scan DESC;

-- Check table bloat (dead tuples)
SELECT 
    relname AS table_name,
    n_live_tup AS live_tuples,
    n_dead_tup AS dead_tuples,
    CASE 
        WHEN n_live_tup > 0 THEN round(100.0 * n_dead_tup / n_live_tup, 2)
        ELSE 0
    END AS dead_tuple_pct
FROM pg_stat_user_tables
WHERE relname = 'memory_vectors';

-- Reset statistics (useful for testing)
-- SELECT pg_stat_reset();
