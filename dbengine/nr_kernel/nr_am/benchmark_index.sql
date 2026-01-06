-- Index Performance Benchmark (100,000 queries)
-- 从表中真实存在的数据中选择 10 万个不重复的 key
-- Usage: psql -h /tmp -d neurdb -f benchmark_index.sql

\set QUIET on
SET client_min_messages = 'warning';
SET max_parallel_workers_per_gather = 0;
SET enable_seqscan = off;

\echo ''
\echo '=============================================='
\echo 'Index Performance Benchmark (100,000 queries)'
\echo 'Keys: Real data, unique, uniform distribution'
\echo '=============================================='

-- Check table
SELECT COUNT(*) AS total_rows FROM books;

------------------------------------------------------------
-- Step 1: Extract 100,000 unique keys from real data
------------------------------------------------------------
\echo ''
\echo 'Step 1: Extracting 100,000 unique keys from table...'

DROP TABLE IF EXISTS benchmark_queries;

-- 从表中随机选择 100,000 个不重复的 val
CREATE TEMP TABLE benchmark_queries AS
SELECT query_key, ROW_NUMBER() OVER () AS query_id
FROM (
    SELECT val AS query_key
    FROM (SELECT DISTINCT val FROM books) distinct_vals
    ORDER BY random()  -- 随机打乱顺序
    LIMIT 100000
) sub;

-- 验证
SELECT COUNT(*) AS unique_keys FROM benchmark_queries;
SELECT COUNT(DISTINCT query_key) AS verify_unique FROM benchmark_queries;

\echo ''
\echo 'Sample keys (first 10):'
SELECT query_id, query_key FROM benchmark_queries ORDER BY query_id LIMIT 10;

------------------------------------------------------------
-- Benchmark 1: nrindex (LIPP - Direct Call)
------------------------------------------------------------
\echo ''
\echo '=============================================='
\echo 'Benchmark 1: nrindex (LIPP - Direct Call)'
\echo '=============================================='

DROP INDEX IF EXISTS idx_books_val_btree;
DROP INDEX IF EXISTS idx_books_val;

\echo 'Creating nrindex...'
\timing on
CREATE INDEX idx_books_val ON books USING nrindex(val);
\timing off

\echo ''
\echo 'Warming up...'
SELECT * FROM books WHERE val = (SELECT query_key FROM benchmark_queries WHERE query_id = 1);

\echo ''
\echo 'Running 100,000 unique queries on nrindex...'

DO $$
DECLARE
    start_ts TIMESTAMP;
    end_ts TIMESTAMP;
    elapsed_ms NUMERIC;
    qps NUMERIC;
    rec RECORD;
    result RECORD;
    query_count INT := 0;
BEGIN
    start_ts := clock_timestamp();

    FOR rec IN SELECT query_key FROM benchmark_queries ORDER BY query_id LOOP
        SELECT * INTO result FROM books WHERE val = rec.query_key LIMIT 1;
        query_count := query_count + 1;
    END LOOP;

    end_ts := clock_timestamp();
    elapsed_ms := EXTRACT(EPOCH FROM (end_ts - start_ts)) * 1000;
    qps := query_count / (elapsed_ms / 1000.0);

    RAISE WARNING '';
    RAISE WARNING '========== nrindex Results ==========';
    RAISE WARNING '  Queries:       %', query_count;
    RAISE WARNING '  Total time:    % ms', ROUND(elapsed_ms, 2);
    RAISE WARNING '  Throughput:    % QPS', ROUND(qps, 2);
    RAISE WARNING '  Avg latency:   % ms', ROUND(elapsed_ms / query_count, 4);
END $$;

------------------------------------------------------------
-- Benchmark 2: B-tree
------------------------------------------------------------
\echo ''
\echo '=============================================='
\echo 'Benchmark 2: B-tree'
\echo '=============================================='

DROP INDEX IF EXISTS idx_books_val;

\echo 'Creating btree index...'
\timing on
CREATE INDEX idx_books_val_btree ON books USING btree(val);
\timing off

\echo ''
\echo 'Warming up...'
SELECT * FROM books WHERE val = (SELECT query_key FROM benchmark_queries WHERE query_id = 1);

\echo ''
\echo 'Running 100,000 unique queries on btree...'

DO $$
DECLARE
    start_ts TIMESTAMP;
    end_ts TIMESTAMP;
    elapsed_ms NUMERIC;
    qps NUMERIC;
    rec RECORD;
    result RECORD;
    query_count INT := 0;
BEGIN
    start_ts := clock_timestamp();

    FOR rec IN SELECT query_key FROM benchmark_queries ORDER BY query_id LOOP
        SELECT * INTO result FROM books WHERE val = rec.query_key LIMIT 1;
        query_count := query_count + 1;
    END LOOP;

    end_ts := clock_timestamp();
    elapsed_ms := EXTRACT(EPOCH FROM (end_ts - start_ts)) * 1000;
    qps := query_count / (elapsed_ms / 1000.0);

    RAISE WARNING '';
    RAISE WARNING '========== B-tree Results ==========';
    RAISE WARNING '  Queries:       %', query_count;
    RAISE WARNING '  Total time:    % ms', ROUND(elapsed_ms, 2);
    RAISE WARNING '  Throughput:    % QPS', ROUND(qps, 2);
    RAISE WARNING '  Avg latency:   % ms', ROUND(elapsed_ms / query_count, 4);
END $$;

------------------------------------------------------------
-- Summary
------------------------------------------------------------
\echo ''
\echo '=============================================='
\echo 'Benchmark Complete'
\echo '=============================================='
\echo ''
\echo 'Test characteristics:'
\echo '  - 100,000 unique keys from real table data'
\echo '  - Each key queried exactly once'
\echo '  - Uniform distribution (no hot spots)'
\echo ''

-- Cleanup
DROP TABLE IF EXISTS benchmark_queries;

-- Restore nrindex
DROP INDEX IF EXISTS idx_books_val_btree;
CREATE INDEX idx_books_val ON books USING nrindex(val);
\echo 'nrindex restored for further testing.'
