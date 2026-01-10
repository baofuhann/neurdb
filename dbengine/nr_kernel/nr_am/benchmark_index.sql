-- =============================================
-- NRINDEX vs BTREE 性能对比测试
-- 强制使用索引的完整 SQL 脚本
-- 结果输出到 CSV 文件
-- =============================================
-- Usage: psql -h 127.0.0.1 -d neurdb -f benchmark_index.sql

-- =============================================
-- Step 1: 强制使用索引的设置
-- =============================================
SET enable_seqscan = off;
SET enable_hashjoin = off;
SET enable_mergejoin = off;
SET enable_nestloop = on;
SET max_parallel_workers_per_gather = 0;

-- =============================================
-- Step 2: 创建主数据表 (如果不存在)
-- =============================================
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'covid') THEN
        RAISE NOTICE '创建主数据表 covid...';
        CREATE TABLE covid (
            id INT PRIMARY KEY,
            val BIGINT NOT NULL
        );
        CREATE TEMP TABLE temp_load (val BIGINT);
        COPY temp_load FROM '/hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_bulk_load_keys.csv' CSV HEADER;
        INSERT INTO covid (id, val) SELECT row_number() OVER () AS id, val FROM temp_load;
        DROP TABLE temp_load;
        RAISE NOTICE '主数据表创建完成';
    ELSE
        RAISE NOTICE '主数据表 covid 已存在，跳过创建';
    END IF;
END $$;

-- =============================================
-- Step 3: 创建查询键表 (如果不存在或结构不对则重建)
-- =============================================
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'query_keys' AND column_name = 'id'
    ) THEN
        DROP TABLE IF EXISTS query_keys;
        RAISE NOTICE '创建查询键表 query_keys...';
        CREATE TABLE query_keys (
            id SERIAL PRIMARY KEY,
            val BIGINT NOT NULL
        );
        COPY query_keys(val) FROM '/hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_read_keys.csv' CSV HEADER;
        RAISE NOTICE '查询键表创建完成';
    ELSE
        RAISE NOTICE '查询键表 query_keys 已存在，跳过创建';
    END IF;
END $$;

-- =============================================
-- Step 4: 创建结果表
-- =============================================
DROP TABLE IF EXISTS benchmark_results;
CREATE TABLE benchmark_results (
    index_type TEXT,
    create_time_ms DOUBLE PRECISION,
    query_count BIGINT,
    total_time_ms DOUBLE PRECISION,
    avg_time_us DOUBLE PRECISION,
    throughput_qps DOUBLE PRECISION
);

-- =============================================
-- Step 5: 删除所有旧索引
-- =============================================
DROP INDEX IF EXISTS idx_covid_nrindex;
DROP INDEX IF EXISTS idx_covid_btree;

-- =============================================
-- Step 6: 创建单点查询测试函数
-- =============================================
CREATE OR REPLACE FUNCTION benchmark_point_queries(query_limit INT DEFAULT 0)
RETURNS TABLE(
    total_time_ms DOUBLE PRECISION,
    query_count BIGINT,
    avg_time_us DOUBLE PRECISION,
    throughput_qps DOUBLE PRECISION
) AS $$
DECLARE
    start_ts TIMESTAMP;
    end_ts TIMESTAMP;
    key_val BIGINT;
    result_row RECORD;
    cnt BIGINT := 0;
    elapsed_ms DOUBLE PRECISION;
BEGIN
    SET LOCAL enable_seqscan = off;
    SET LOCAL enable_hashjoin = off;
    SET LOCAL enable_mergejoin = off;
    SET LOCAL enable_nestloop = on;

    start_ts := clock_timestamp();

    IF query_limit > 0 THEN
        FOR key_val IN SELECT q.val FROM query_keys q ORDER BY q.id LIMIT query_limit LOOP
            SELECT * INTO result_row FROM covid WHERE val = key_val LIMIT 1;
            cnt := cnt + 1;
        END LOOP;
    ELSE
        FOR key_val IN SELECT q.val FROM query_keys q ORDER BY q.id LOOP
            SELECT * INTO result_row FROM covid WHERE val = key_val LIMIT 1;
            cnt := cnt + 1;
        END LOOP;
    END IF;

    end_ts := clock_timestamp();

    elapsed_ms := EXTRACT(EPOCH FROM (end_ts - start_ts)) * 1000;
    total_time_ms := elapsed_ms;
    query_count := cnt;
    avg_time_us := (elapsed_ms * 1000) / cnt;
    throughput_qps := cnt / (elapsed_ms / 1000);

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- =============================================
-- Step 7: 测试 NRINDEX
-- =============================================
\echo ''
\echo '=============================================='
\echo 'Benchmark: NRINDEX'
\echo '=============================================='

DO $$
DECLARE
    create_start TIMESTAMP;
    create_end TIMESTAMP;
    create_time DOUBLE PRECISION;
    result RECORD;
BEGIN
    create_start := clock_timestamp();
    EXECUTE 'CREATE INDEX idx_covid_nrindex ON covid USING nrindex(val)';
    create_end := clock_timestamp();
    create_time := EXTRACT(EPOCH FROM (create_end - create_start)) * 1000;
    
    RAISE NOTICE 'NRINDEX 创建时间: % ms', round(create_time::numeric, 2);
    
    -- 预热
    PERFORM * FROM benchmark_point_queries(1000);
    
    -- 正式测试
    SELECT * INTO result FROM benchmark_point_queries(500000);
    
    INSERT INTO benchmark_results VALUES (
        'NRINDEX',
        create_time,
        result.query_count,
        result.total_time_ms,
        result.avg_time_us,
        result.throughput_qps
    );
    
    RAISE NOTICE 'NRINDEX 测试完成: % QPS', round(result.throughput_qps::numeric, 2);
END $$;

DROP INDEX IF EXISTS idx_covid_nrindex;

-- =============================================
-- Step 8: 测试 BTREE
-- =============================================
\echo ''
\echo '=============================================='
\echo 'Benchmark: BTREE'
\echo '=============================================='

DO $$
DECLARE
    create_start TIMESTAMP;
    create_end TIMESTAMP;
    create_time DOUBLE PRECISION;
    result RECORD;
BEGIN
    create_start := clock_timestamp();
    EXECUTE 'CREATE INDEX idx_covid_btree ON covid USING btree(val)';
    create_end := clock_timestamp();
    create_time := EXTRACT(EPOCH FROM (create_end - create_start)) * 1000;
    
    RAISE NOTICE 'BTREE 创建时间: % ms', round(create_time::numeric, 2);
    
    -- 预热
    PERFORM * FROM benchmark_point_queries(1000);
    
    -- 正式测试
    SELECT * INTO result FROM benchmark_point_queries(500000);
    
    INSERT INTO benchmark_results VALUES (
        'BTREE',
        create_time,
        result.query_count,
        result.total_time_ms,
        result.avg_time_us,
        result.throughput_qps
    );
    
    RAISE NOTICE 'BTREE 测试完成: % QPS', round(result.throughput_qps::numeric, 2);
END $$;

DROP INDEX IF EXISTS idx_covid_btree;

-- =============================================
-- Step 9: 显示结果
-- =============================================
\echo ''
\echo '=============================================='
\echo '测试结果'
\echo '=============================================='

SELECT 
    index_type AS "索引类型",
    round(create_time_ms::numeric, 2) AS "创建时间(ms)",
    query_count AS "查询数量",
    round(total_time_ms::numeric, 2) AS "总耗时(ms)",
    round(avg_time_us::numeric, 2) AS "平均延迟(us)",
    round(throughput_qps::numeric, 2) AS "吞吐量(QPS)"
FROM benchmark_results;

-- =============================================
-- Step 10: 导出到 CSV
-- =============================================
\echo ''
\echo '导出结果到 CSV...'

COPY (
    SELECT 
        index_type,
        round(create_time_ms::numeric, 2) AS create_time_ms,
        query_count,
        round(total_time_ms::numeric, 2) AS total_time_ms,
        round(avg_time_us::numeric, 2) AS avg_time_us,
        round(throughput_qps::numeric, 2) AS throughput_qps
    FROM benchmark_results
) TO '/tmp/benchmark_results.csv' WITH CSV HEADER;

\echo '结果已保存到: /tmp/benchmark_results.csv'

\echo ''
\echo '=============================================='
\echo '测试完成!'
\echo '=============================================='
