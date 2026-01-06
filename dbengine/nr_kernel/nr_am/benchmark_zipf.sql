-- Index Performance Benchmark with Zipf Distribution
-- 从真实数据中抽取 key，查询分布服从 Zipf 分布
-- Usage: psql -h /tmp -d neurdb -f benchmark_zipf.sql

\set QUIET on
SET client_min_messages = 'warning';  -- 屏蔽 nrindex 的 NOTICE 日志
SET max_parallel_workers_per_gather = 0;
SET enable_seqscan = off;

\echo ''
\echo '=============================================='
\echo 'Index Benchmark with Zipf Distribution'
\echo 'Query count: 100,000'
\echo '=============================================='

-- Check table
SELECT COUNT(*) AS total_rows FROM books;

------------------------------------------------------------
-- Step 1: Create temp table with real keys and Zipf weights
------------------------------------------------------------
\echo ''
\echo 'Step 1: Extracting real keys from table...'

DROP TABLE IF EXISTS benchmark_keys;

-- 获取所有不重复的 val 值，并分配 rank
CREATE TEMP TABLE benchmark_keys AS
SELECT val,
       ROW_NUMBER() OVER (ORDER BY val) AS rank,
       COUNT(*) OVER () AS total_keys
FROM (SELECT DISTINCT val FROM books) sub;

SELECT COUNT(*) AS unique_keys FROM benchmark_keys;

------------------------------------------------------------
-- Step 2: Generate Zipf-distributed query keys
------------------------------------------------------------
\echo ''
\echo 'Step 2: Generating 100,000 Zipf-distributed query keys...'

-- Zipf 分布: P(rank) ∝ 1/rank^s, where s is skew parameter
-- s = 1.0 是标准 Zipf (最常见)
-- s > 1.0 更倾斜 (热点更集中)

DROP TABLE IF EXISTS zipf_queries;

CREATE TEMP TABLE zipf_queries AS
WITH zipf_generator AS (
    SELECT
        generate_series(1, 100000) AS query_id,
        random() AS rand_val
),
-- 使用逆变换采样生成 Zipf 分布的 rank
-- 对于 Zipf(s=1), CDF^(-1)(u) ≈ n^u where n is number of items
zipf_ranks AS (
    SELECT
        query_id,
        -- Zipf with skew s=1.0: rank = floor(n^random)
        -- 这会让 rank=1 的 key 被选中概率最高
        GREATEST(1, FLOOR(POWER((SELECT COUNT(*) FROM benchmark_keys), rand_val)))::INT AS zipf_rank
    FROM zipf_generator
)
SELECT
    zr.query_id,
    bk.val AS query_key
FROM zipf_ranks zr
JOIN benchmark_keys bk ON bk.rank = zr.zipf_rank;

-- 显示 Zipf 分布统计
\echo ''
\echo 'Zipf distribution statistics (top 10 hot keys):'
SELECT query_key, COUNT(*) AS access_count,
       ROUND(COUNT(*) * 100.0 / 100000, 2) AS percentage
FROM zipf_queries
GROUP BY query_key
ORDER BY access_count DESC
LIMIT 10;

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
SELECT * FROM books WHERE val = (SELECT query_key FROM zipf_queries LIMIT 1);

\echo ''
\echo 'Running 100,000 Zipf-distributed queries on nrindex...'

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

    FOR rec IN SELECT query_key FROM zipf_queries ORDER BY query_id LOOP
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
SELECT * FROM books WHERE val = (SELECT query_key FROM zipf_queries LIMIT 1);

\echo ''
\echo 'Running 100,000 Zipf-distributed queries on btree...'

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

    FOR rec IN SELECT query_key FROM zipf_queries ORDER BY query_id LOOP
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
\echo 'Zipf distribution ensures realistic workload pattern:'
\echo '  - Few "hot" keys accessed very frequently'
\echo '  - Many "cold" keys accessed rarely'
\echo ''

-- Cleanup
DROP TABLE IF EXISTS benchmark_keys;
DROP TABLE IF EXISTS zipf_queries;

-- Restore nrindex
DROP INDEX IF EXISTS idx_books_val_btree;
CREATE INDEX idx_books_val ON books USING nrindex(val);
\echo 'nrindex restored for further testing.'
