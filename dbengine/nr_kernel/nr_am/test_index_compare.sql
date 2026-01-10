-- =============================================
-- NRINDEX vs BTREE 性能对比测试 (使用 RL 训练数据)
-- =============================================

-- /code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb -f /code/neurdb-dev/dbengine/nr_kernel/nr_am/test_index_compare.sql

-- 数据来源:
--   主表数据: /hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_bulk_load_keys.csv (10M)
--   查询键:   /hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_read_keys.csv (500K)

-- 禁用顺序扫描和并行查询，确保使用索引
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;

-- 创建临时表存储测试键值 (RL read_keys 格式只有 key 列)
DROP TABLE IF EXISTS test_keys;
CREATE TABLE test_keys (val BIGINT);
\copy test_keys FROM '/hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_read_keys.csv' CSV HEADER;

\echo '查询键数量:'
SELECT COUNT(*) AS query_count FROM test_keys;

-- 创建临时表存储测试结果
DROP TABLE IF EXISTS test_results;
CREATE TABLE test_results (
    test_id SERIAL,
    round_num INT,
    index_type TEXT,
    test_type TEXT,
    total_queries INT,
    total_time_ms NUMERIC,
    throughput_qps NUMERIC
);

-- =============================================
-- NRINDEX 多轮测试
-- =============================================
\echo '=========================================='
\echo 'NRINDEX 多轮测试'
\echo '=========================================='

DO $$
DECLARE
    num_rounds INT := 3;
    round_i INT;
    start_time TIMESTAMP;
    end_time TIMESTAMP;
    elapsed_ms NUMERIC;
    total_queries INT;
    throughput NUMERIC;
    key_rec RECORD;
    r RECORD;
BEGIN
    FOR round_i IN 1..num_rounds LOOP
        RAISE NOTICE '========== NRINDEX 第 % 轮 ==========', round_i;

        -- 删除已有索引
        EXECUTE 'DROP INDEX IF EXISTS idx_nrindex';
        EXECUTE 'DROP INDEX IF EXISTS idx_btree';

        -- 创建索引
        start_time := clock_timestamp();
        EXECUTE 'CREATE INDEX idx_nrindex ON covid USING nrindex(val)';
        end_time := clock_timestamp();
        elapsed_ms := EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;

        INSERT INTO test_results (round_num, index_type, test_type, total_queries, total_time_ms, throughput_qps)
        VALUES (round_i, 'NRINDEX', 'CREATE INDEX', 1, elapsed_ms, NULL);
        RAISE NOTICE 'NRINDEX 创建时间: % ms', ROUND(elapsed_ms, 3);

        -- 预热查询
        FOR key_rec IN SELECT val FROM test_keys LIMIT 1000 LOOP
            SELECT * INTO r FROM covid WHERE val = key_rec.val;
        END LOOP;
        RAISE NOTICE '预热完成';

        -- 点查询测试
        SELECT COUNT(*) INTO total_queries FROM test_keys;

        start_time := clock_timestamp();
        FOR key_rec IN SELECT val FROM test_keys LOOP
            SELECT * INTO r FROM covid WHERE val = key_rec.val;
        END LOOP;
        end_time := clock_timestamp();

        elapsed_ms := EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;
        throughput := total_queries / (elapsed_ms / 1000.0);

        INSERT INTO test_results (round_num, index_type, test_type, total_queries, total_time_ms, throughput_qps)
        VALUES (round_i, 'NRINDEX', 'POINT QUERY', total_queries, elapsed_ms, throughput);

        RAISE NOTICE 'NRINDEX: % 次查询, 时间: % ms, 吞吐量: % QPS',
                     total_queries, ROUND(elapsed_ms, 3), ROUND(throughput, 2);

        -- 删除索引
        EXECUTE 'DROP INDEX idx_nrindex';
    END LOOP;
END $$;

-- =============================================
-- BTREE 多轮测试
-- =============================================
\echo ''
\echo '=========================================='
\echo 'BTREE 多轮测试'
\echo '=========================================='

DO $$
DECLARE
    num_rounds INT := 3;
    round_i INT;
    start_time TIMESTAMP;
    end_time TIMESTAMP;
    elapsed_ms NUMERIC;
    total_queries INT;
    throughput NUMERIC;
    key_rec RECORD;
    r RECORD;
BEGIN
    FOR round_i IN 1..num_rounds LOOP
        RAISE NOTICE '========== BTREE 第 % 轮 ==========', round_i;

        -- 删除已有索引
        EXECUTE 'DROP INDEX IF EXISTS idx_nrindex';
        EXECUTE 'DROP INDEX IF EXISTS idx_btree';

        -- 创建索引
        start_time := clock_timestamp();
        EXECUTE 'CREATE INDEX idx_btree ON covid USING btree(val)';
        end_time := clock_timestamp();
        elapsed_ms := EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;

        INSERT INTO test_results (round_num, index_type, test_type, total_queries, total_time_ms, throughput_qps)
        VALUES (round_i, 'BTREE', 'CREATE INDEX', 1, elapsed_ms, NULL);
        RAISE NOTICE 'BTREE 创建时间: % ms', ROUND(elapsed_ms, 3);

        -- 预热查询
        FOR key_rec IN SELECT val FROM test_keys LIMIT 1000 LOOP
            SELECT * INTO r FROM covid WHERE val = key_rec.val;
        END LOOP;
        RAISE NOTICE '预热完成';

        -- 点查询测试
        SELECT COUNT(*) INTO total_queries FROM test_keys;

        start_time := clock_timestamp();
        FOR key_rec IN SELECT val FROM test_keys LOOP
            SELECT * INTO r FROM covid WHERE val = key_rec.val;
        END LOOP;
        end_time := clock_timestamp();

        elapsed_ms := EXTRACT(EPOCH FROM (end_time - start_time)) * 1000;
        throughput := total_queries / (elapsed_ms / 1000.0);

        INSERT INTO test_results (round_num, index_type, test_type, total_queries, total_time_ms, throughput_qps)
        VALUES (round_i, 'BTREE', 'POINT QUERY', total_queries, elapsed_ms, throughput);

        RAISE NOTICE 'BTREE: % 次查询, 时间: % ms, 吞吐量: % QPS',
                     total_queries, ROUND(elapsed_ms, 3), ROUND(throughput, 2);

        -- 删除索引
        EXECUTE 'DROP INDEX idx_btree';
    END LOOP;
END $$;

-- =============================================
-- 结果汇总
-- =============================================
\echo ''
\echo '=========================================='
\echo '各轮详细结果'
\echo '=========================================='

SELECT
    round_num AS "轮次",
    index_type AS "索引类型",
    test_type AS "测试类型",
    total_queries AS "查询次数",
    ROUND(total_time_ms, 3) AS "时间(ms)",
    ROUND(throughput_qps, 2) AS "吞吐量(QPS)"
FROM test_results
ORDER BY test_type, index_type, round_num;

\echo ''
\echo '=========================================='
\echo '平均值统计'
\echo '=========================================='

SELECT
    index_type AS "索引类型",
    test_type AS "测试类型",
    COUNT(*) AS "轮数",
    ROUND(AVG(total_time_ms), 3) AS "平均时间(ms)",
    ROUND(MIN(total_time_ms), 3) AS "最小时间(ms)",
    ROUND(MAX(total_time_ms), 3) AS "最大时间(ms)",
    ROUND(STDDEV(total_time_ms), 3) AS "标准差(ms)",
    ROUND(AVG(throughput_qps), 2) AS "平均吞吐量(QPS)"
FROM test_results
GROUP BY index_type, test_type
ORDER BY test_type, index_type;

\echo ''
\echo '=========================================='
\echo 'NRINDEX vs BTREE 性能比较 (平均值)'
\echo '=========================================='

SELECT
    'POINT QUERY' AS "测试类型",
    (SELECT MAX(total_queries) FROM test_results WHERE test_type='POINT QUERY') AS "查询次数",
    ROUND((SELECT AVG(total_time_ms) FROM test_results WHERE index_type='NRINDEX' AND test_type='POINT QUERY'), 3) AS "NRINDEX时间(ms)",
    ROUND((SELECT AVG(total_time_ms) FROM test_results WHERE index_type='BTREE' AND test_type='POINT QUERY'), 3) AS "BTREE时间(ms)",
    ROUND((SELECT AVG(throughput_qps) FROM test_results WHERE index_type='NRINDEX' AND test_type='POINT QUERY'), 2) AS "NRINDEX(QPS)",
    ROUND((SELECT AVG(throughput_qps) FROM test_results WHERE index_type='BTREE' AND test_type='POINT QUERY'), 2) AS "BTREE(QPS)",
    ROUND((SELECT AVG(throughput_qps) FROM test_results WHERE index_type='NRINDEX' AND test_type='POINT QUERY') /
          NULLIF((SELECT AVG(throughput_qps) FROM test_results WHERE index_type='BTREE' AND test_type='POINT QUERY'), 0), 2) AS "NRINDEX/BTREE"
UNION ALL
SELECT
    'CREATE INDEX' AS "测试类型",
    1 AS "查询次数",
    ROUND((SELECT AVG(total_time_ms) FROM test_results WHERE index_type='NRINDEX' AND test_type='CREATE INDEX'), 3) AS "NRINDEX时间(ms)",
    ROUND((SELECT AVG(total_time_ms) FROM test_results WHERE index_type='BTREE' AND test_type='CREATE INDEX'), 3) AS "BTREE时间(ms)",
    NULL AS "NRINDEX(QPS)",
    NULL AS "BTREE(QPS)",
    ROUND((SELECT AVG(total_time_ms) FROM test_results WHERE index_type='BTREE' AND test_type='CREATE INDEX') /
          NULLIF((SELECT AVG(total_time_ms) FROM test_results WHERE index_type='NRINDEX' AND test_type='CREATE INDEX'), 0), 2) AS "BTREE/NRINDEX";

-- 清理临时表
DROP TABLE test_keys;
DROP TABLE test_results;

\echo ''
\echo '测试完成!'
