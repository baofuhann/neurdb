-- =============================================
-- 这个是我们进行pg试验的最终的测试脚本
-- neurdb@87f0aea057c8:/code/neurdb-dev/dbengine/nr_kernel/nr_am$ (项目的路径)
-- 如下是执行的命令
-- /code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb -f index_benchmark_final.sql
-- 两张独立的表，分别测试 NRINDEX 和 BTREE
-- 只测试 Index Scan + 回表 (SELECT *)
-- 输出: 创建时间、延迟、吞吐量
-- =============================================

SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;

-- =============================================
-- 准备两张独立的数据表 (如果不存在才创建)
-- =============================================
\echo ''
\echo '检查数据表...'

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'covid_nrindex') THEN
        RAISE NOTICE '创建 covid_nrindex 表...';
        CREATE TABLE covid_nrindex (id INT PRIMARY KEY, val BIGINT);
        INSERT INTO covid_nrindex SELECT id, val FROM covid;
    ELSE
        RAISE NOTICE 'covid_nrindex 表已存在，跳过创建';
    END IF;

    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'covid_btree') THEN
        RAISE NOTICE '创建 covid_btree 表...';
        CREATE TABLE covid_btree (id INT PRIMARY KEY, val BIGINT);
        INSERT INTO covid_btree SELECT id, val FROM covid;
    ELSE
        RAISE NOTICE 'covid_btree 表已存在，跳过创建';
    END IF;
END $$;

\echo '数据量:'
SELECT 'covid_nrindex' AS "表名", COUNT(*) AS "行数" FROM covid_nrindex
UNION ALL
SELECT 'covid_btree', COUNT(*) FROM covid_btree
UNION ALL
SELECT 'query_keys', COUNT(*) FROM query_keys;

-- =============================================
-- 结果表 (包含创建时间)
-- =============================================
DROP TABLE IF EXISTS benchmark_results;
CREATE TABLE benchmark_results (
    index_type TEXT,
    create_time_ms NUMERIC,
    query_count INT,
    total_time_ms NUMERIC,
    avg_time_us NUMERIC,
    throughput_qps NUMERIC
);

-- =============================================
-- 创建索引并记录时间
-- =============================================
\echo ''
\echo '创建索引...'

DROP INDEX IF EXISTS idx_nrindex;
DROP INDEX IF EXISTS idx_btree;

-- NRINDEX 创建时间
DO $$
DECLARE
    t1 TIMESTAMP;
    t2 TIMESTAMP;
    elapsed_ms NUMERIC;
BEGIN
    t1 := clock_timestamp();
    CREATE INDEX idx_nrindex ON covid_nrindex USING nrindex(val);
    t2 := clock_timestamp();
    elapsed_ms := EXTRACT(EPOCH FROM (t2 - t1)) * 1000;
    INSERT INTO benchmark_results (index_type, create_time_ms) VALUES ('NRINDEX', elapsed_ms);
    RAISE NOTICE 'NRINDEX 创建时间: % ms', ROUND(elapsed_ms, 2);
END $$;

-- BTREE 创建时间
DO $$
DECLARE
    t1 TIMESTAMP;
    t2 TIMESTAMP;
    elapsed_ms NUMERIC;
BEGIN
    t1 := clock_timestamp();
    CREATE INDEX idx_btree ON covid_btree USING btree(val);
    t2 := clock_timestamp();
    elapsed_ms := EXTRACT(EPOCH FROM (t2 - t1)) * 1000;
    INSERT INTO benchmark_results (index_type, create_time_ms) VALUES ('BTREE', elapsed_ms);
    RAISE NOTICE 'BTREE 创建时间: % ms', ROUND(elapsed_ms, 2);
END $$;

-- =============================================
-- 测试函数: NRINDEX - Index Scan + 回表
-- =============================================
CREATE OR REPLACE FUNCTION test_nrindex_index_scan(lim INT)
RETURNS TABLE(ms NUMERIC, cnt INT, us NUMERIC, qps NUMERIC) AS $$
DECLARE
    k BIGINT; r RECORD;
    t1 TIMESTAMP; t2 TIMESTAMP;
    n INT := 0; elapsed NUMERIC;
BEGIN
    t1 := clock_timestamp();
    FOR k IN SELECT val FROM query_keys LIMIT lim LOOP
        SELECT * INTO r FROM covid_nrindex WHERE val = k LIMIT 1;
        n := n + 1;
    END LOOP;
    t2 := clock_timestamp();
    elapsed := EXTRACT(EPOCH FROM (t2 - t1)) * 1000;
    ms := elapsed; cnt := n; us := elapsed * 1000 / n; qps := n / (elapsed / 1000);
    RETURN NEXT;
END; $$ LANGUAGE plpgsql;

-- =============================================
-- 测试函数: BTREE - Index Scan + 回表
-- =============================================
CREATE OR REPLACE FUNCTION test_btree_index_scan(lim INT)
RETURNS TABLE(ms NUMERIC, cnt INT, us NUMERIC, qps NUMERIC) AS $$
DECLARE
    k BIGINT; r RECORD;
    t1 TIMESTAMP; t2 TIMESTAMP;
    n INT := 0; elapsed NUMERIC;
BEGIN
    t1 := clock_timestamp();
    FOR k IN SELECT val FROM query_keys LIMIT lim LOOP
        SELECT * INTO r FROM covid_btree WHERE val = k LIMIT 1;
        n := n + 1;
    END LOOP;
    t2 := clock_timestamp();
    elapsed := EXTRACT(EPOCH FROM (t2 - t1)) * 1000;
    ms := elapsed; cnt := n; us := elapsed * 1000 / n; qps := n / (elapsed / 1000);
    RETURN NEXT;
END; $$ LANGUAGE plpgsql;

-- =============================================
-- 执行测试
-- =============================================
\echo ''
\echo '=============================================='
\echo '开始测试 Index Scan + 回表 (100000 次查询)'
\echo '=============================================='

-- 预热 (不显示结果)
\echo '预热...'
DO $$ DECLARE dummy RECORD; BEGIN SELECT * INTO dummy FROM test_nrindex_index_scan(1000); END $$;
DO $$ DECLARE dummy RECORD; BEGIN SELECT * INTO dummy FROM test_btree_index_scan(1000); END $$;

-- NRINDEX 查询测试
\echo ''
\echo 'NRINDEX - Index Scan + 回表:'
UPDATE benchmark_results
SET query_count = t.cnt, total_time_ms = t.ms, avg_time_us = t.us, throughput_qps = t.qps
FROM test_nrindex_index_scan(100000) t
WHERE index_type = 'NRINDEX';

-- BTREE 查询测试
\echo 'BTREE - Index Scan + 回表:'
UPDATE benchmark_results
SET query_count = t.cnt, total_time_ms = t.ms, avg_time_us = t.us, throughput_qps = t.qps
FROM test_btree_index_scan(100000) t
WHERE index_type = 'BTREE';

-- =============================================
-- 结果汇总
-- =============================================
\echo ''
\echo '=============================================='
\echo '结果汇总'
\echo '=============================================='

SELECT
    index_type AS "索引类型",
    ROUND(create_time_ms, 2) AS "创建时间(ms)",
    query_count AS "查询数",
    ROUND(total_time_ms, 2) AS "查询时间(ms)",
    ROUND(avg_time_us, 2) AS "平均延迟(μs)",
    ROUND(throughput_qps, 0) AS "吞吐量(QPS)"
FROM benchmark_results
ORDER BY index_type;

\echo ''
\echo '=============================================='
\echo '性能对比 (NRINDEX vs BTREE)'
\echo '=============================================='

SELECT
    ROUND(n.create_time_ms, 0) AS "NRINDEX创建(ms)",
    ROUND(b.create_time_ms, 0) AS "BTREE创建(ms)",
    ROUND(n.avg_time_us, 2) AS "NRINDEX延迟(μs)",
    ROUND(b.avg_time_us, 2) AS "BTREE延迟(μs)",
    ROUND(n.throughput_qps, 0) AS "NRINDEX(QPS)",
    ROUND(b.throughput_qps, 0) AS "BTREE(QPS)",
    CASE
        WHEN n.avg_time_us < b.avg_time_us
        THEN 'NRINDEX 快 ' || ROUND((1 - n.avg_time_us/b.avg_time_us) * 100, 1) || '%'
        ELSE 'BTREE 快 ' || ROUND((1 - b.avg_time_us/n.avg_time_us) * 100, 1) || '%'
    END AS "查询性能结论"
FROM benchmark_results n, benchmark_results b
WHERE n.index_type = 'NRINDEX' AND b.index_type = 'BTREE';

-- 清理
DROP FUNCTION IF EXISTS test_nrindex_index_scan(INT);
DROP FUNCTION IF EXISTS test_btree_index_scan(INT);
DROP TABLE IF EXISTS benchmark_results;

\echo ''
\echo '测试完成!'
