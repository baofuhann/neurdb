-- =============================================
-- NRINDEX vs BTREE 插入性能对比测试
-- =============================================
-- Usage: psql -h 127.0.0.1 -d neurdb -f benchmark_insert.sql

\timing on

-- =============================================
-- Step 1: 设置
-- =============================================
SET max_parallel_workers_per_gather = 0;

-- =============================================
-- Step 2: 创建测试表 (使用 bulk_load 数据作为初始数据)
-- =============================================
\echo '准备测试表...'
DROP TABLE IF EXISTS insert_test CASCADE;
CREATE TABLE insert_test (
    id INT PRIMARY KEY,
    val BIGINT NOT NULL
);

-- 导入初始数据 (bulk_load_keys)
\echo '导入初始数据 (bulk_load_keys)...'
CREATE TEMP TABLE temp_bulk (val BIGINT);
COPY temp_bulk FROM '/hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_bulk_load_keys.csv' CSV HEADER;
INSERT INTO insert_test (id, val) 
SELECT row_number() OVER () AS id, val FROM temp_bulk;
DROP TABLE temp_bulk;

SELECT COUNT(*) AS "初始行数" FROM insert_test;

-- =============================================
-- Step 3: 准备插入数据 (来自 insert_keys.csv)
-- =============================================
\echo '准备插入数据 (insert_keys.csv)...'
DROP TABLE IF EXISTS insert_data CASCADE;
CREATE TABLE insert_data (
    id SERIAL PRIMARY KEY,
    val BIGINT NOT NULL
);

COPY insert_data(val) FROM '/hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_insert_keys.csv' CSV HEADER;

-- 获取初始表的最大 id，用于生成新的 id
DO $$
DECLARE
    max_id INT;
BEGIN
    SELECT COALESCE(MAX(id), 0) INTO max_id FROM insert_test;
    -- 更新 insert_data 的 id
    UPDATE insert_data SET id = id + max_id;
END $$;

SELECT COUNT(*) AS "待插入行数" FROM insert_data;

-- =============================================
-- Step 4: 创建插入测试函数
-- =============================================
DROP FUNCTION IF EXISTS benchmark_insert();
DROP FUNCTION IF EXISTS benchmark_insert(INT);

CREATE OR REPLACE FUNCTION benchmark_insert(insert_limit INT DEFAULT 0)
RETURNS TABLE(
    total_time_ms DOUBLE PRECISION,
    insert_count BIGINT,
    avg_time_us DOUBLE PRECISION,
    throughput_ips DOUBLE PRECISION
) AS $$
DECLARE
    start_ts TIMESTAMP;
    end_ts TIMESTAMP;
    rec RECORD;
    cnt BIGINT := 0;
    elapsed_ms DOUBLE PRECISION;
BEGIN
    start_ts := clock_timestamp();

    -- 逐行插入
    IF insert_limit > 0 THEN
        FOR rec IN SELECT id, val FROM insert_data ORDER BY id LIMIT insert_limit LOOP
            INSERT INTO insert_test (id, val) VALUES (rec.id, rec.val);
            cnt := cnt + 1;
        END LOOP;
    ELSE
        FOR rec IN SELECT id, val FROM insert_data ORDER BY id LOOP
            INSERT INTO insert_test (id, val) VALUES (rec.id, rec.val);
            cnt := cnt + 1;
        END LOOP;
    END IF;

    end_ts := clock_timestamp();

    elapsed_ms := EXTRACT(EPOCH FROM (end_ts - start_ts)) * 1000;
    total_time_ms := elapsed_ms;
    insert_count := cnt;
    avg_time_us := (elapsed_ms * 1000) / NULLIF(cnt, 0);
    throughput_ips := cnt / NULLIF(elapsed_ms / 1000, 0);

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- =============================================
-- Step 5: 创建结果表
-- =============================================
DROP TABLE IF EXISTS insert_results;
CREATE TABLE insert_results (
    index_type TEXT,
    create_time_ms DOUBLE PRECISION,
    insert_count BIGINT,
    total_time_ms DOUBLE PRECISION,
    avg_time_us DOUBLE PRECISION,
    throughput_ips DOUBLE PRECISION
);

-- =============================================
-- Step 6: 测试 NRINDEX 插入
-- =============================================
\echo ''
\echo '=============================================='
\echo 'Benchmark: NRINDEX 插入测试'
\echo '=============================================='

-- 重置表数据
\echo '重置表数据...'
TRUNCATE insert_test;
CREATE TEMP TABLE temp_reset (val BIGINT);
COPY temp_reset FROM '/hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_bulk_load_keys.csv' CSV HEADER;
INSERT INTO insert_test (id, val) SELECT row_number() OVER () AS id, val FROM temp_reset;
DROP TABLE temp_reset;

\echo '创建 NRINDEX 索引...'
DROP INDEX IF EXISTS idx_insert_nrindex;
DROP INDEX IF EXISTS idx_insert_btree;

DO $$
DECLARE
    create_start TIMESTAMP;
    create_end TIMESTAMP;
    create_time DOUBLE PRECISION;
    result RECORD;
BEGIN
    create_start := clock_timestamp();
    EXECUTE 'CREATE INDEX idx_insert_nrindex ON insert_test USING nrindex(val)';
    create_end := clock_timestamp();
    create_time := EXTRACT(EPOCH FROM (create_end - create_start)) * 1000;
    
    RAISE NOTICE 'NRINDEX 创建时间: % ms', round(create_time::numeric, 2);
    
    -- 执行插入测试 (100000 次)
    SELECT * INTO result FROM benchmark_insert(100000);
    
    INSERT INTO insert_results VALUES (
        'NRINDEX',
        create_time,
        result.insert_count,
        result.total_time_ms,
        result.avg_time_us,
        result.throughput_ips
    );
    
    RAISE NOTICE 'NRINDEX 插入完成: % IPS', round(result.throughput_ips::numeric, 2);
END $$;

-- =============================================
-- Step 7: 测试 BTREE 插入
-- =============================================
\echo ''
\echo '=============================================='
\echo 'Benchmark: BTREE 插入测试'
\echo '=============================================='

-- 重置表数据
\echo '重置表数据...'
TRUNCATE insert_test;
CREATE TEMP TABLE temp_reset2 (val BIGINT);
COPY temp_reset2 FROM '/hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_bulk_load_keys.csv' CSV HEADER;
INSERT INTO insert_test (id, val) SELECT row_number() OVER () AS id, val FROM temp_reset2;
DROP TABLE temp_reset2;

\echo '创建 BTREE 索引...'
DROP INDEX IF EXISTS idx_insert_nrindex;
DROP INDEX IF EXISTS idx_insert_btree;

DO $$
DECLARE
    create_start TIMESTAMP;
    create_end TIMESTAMP;
    create_time DOUBLE PRECISION;
    result RECORD;
BEGIN
    create_start := clock_timestamp();
    EXECUTE 'CREATE INDEX idx_insert_btree ON insert_test USING btree(val)';
    create_end := clock_timestamp();
    create_time := EXTRACT(EPOCH FROM (create_end - create_start)) * 1000;
    
    RAISE NOTICE 'BTREE 创建时间: % ms', round(create_time::numeric, 2);
    
    -- 执行插入测试 (100000 次)
    SELECT * INTO result FROM benchmark_insert(100000);
    
    INSERT INTO insert_results VALUES (
        'BTREE',
        create_time,
        result.insert_count,
        result.total_time_ms,
        result.avg_time_us,
        result.throughput_ips
    );
    
    RAISE NOTICE 'BTREE 插入完成: % IPS', round(result.throughput_ips::numeric, 2);
END $$;

-- =============================================
-- Step 8: 显示结果
-- =============================================
\echo ''
\echo '=============================================='
\echo '插入测试结果'
\echo '=============================================='

SELECT 
    index_type AS "索引类型",
    round(create_time_ms::numeric, 2) AS "创建时间(ms)",
    insert_count AS "插入数量",
    round(total_time_ms::numeric, 2) AS "总耗时(ms)",
    round(avg_time_us::numeric, 2) AS "平均延迟(us)",
    round(throughput_ips::numeric, 2) AS "吞吐量(IPS)"
FROM insert_results;

-- 性能对比
\echo ''
\echo '=============================================='
\echo '性能对比'
\echo '=============================================='

SELECT 
    round((SELECT throughput_ips FROM insert_results WHERE index_type = 'NRINDEX') / 
          NULLIF((SELECT throughput_ips FROM insert_results WHERE index_type = 'BTREE'), 0), 2) 
    AS "NRINDEX/BTREE 吞吐量比值";

-- 导出 CSV
COPY (
    SELECT 
        index_type,
        round(create_time_ms::numeric, 2) AS create_time_ms,
        insert_count,
        round(total_time_ms::numeric, 2) AS total_time_ms,
        round(avg_time_us::numeric, 2) AS avg_time_us,
        round(throughput_ips::numeric, 2) AS throughput_ips
    FROM insert_results
) TO '/tmp/insert_results.csv' WITH CSV HEADER;

\echo '结果已保存到: /tmp/insert_results.csv'

\echo ''
\echo '=============================================='
\echo '测试完成!'
\echo '=============================================='
