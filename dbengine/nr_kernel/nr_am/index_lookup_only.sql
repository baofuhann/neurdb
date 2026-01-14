-- =============================================
-- NRINDEX 纯索引查找性能测试
-- 用于对比不同配置下的性能
-- =============================================

SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;

\echo '=============================================='
\echo 'NRINDEX 纯索引查找性能测试'
\echo '=============================================='

-- 显示当前 ALEX 配置 (从日志可查看)
\echo ''
\echo '请查看日志确认当前配置: grep "ALEX config" /code/neurdb-dev/logfile | tail -3'

-- 重建索引以应用当前配置
\echo ''
\echo '重建 NRINDEX 索引...'
DROP INDEX IF EXISTS idx_nrindex;
\timing on
CREATE INDEX idx_nrindex ON covid_nrindex USING nrindex(val);
\timing off

-- 测试函数
CREATE OR REPLACE FUNCTION test_nrindex_lookup(lim INT)
RETURNS TABLE(ms NUMERIC, cnt INT, us NUMERIC, qps NUMERIC) AS $$
DECLARE
    k BIGINT; v BIGINT;
    t1 TIMESTAMP; t2 TIMESTAMP;
    n INT := 0; elapsed NUMERIC;
BEGIN
    t1 := clock_timestamp();
    FOR k IN SELECT val FROM query_keys LIMIT lim LOOP
        SELECT val INTO v FROM covid_nrindex WHERE val = k LIMIT 1;
        n := n + 1;
    END LOOP;
    t2 := clock_timestamp();
    elapsed := EXTRACT(EPOCH FROM (t2 - t1)) * 1000;
    ms := elapsed; cnt := n; us := elapsed * 1000 / n; qps := n / (elapsed / 1000);
    RETURN NEXT;
END; $$ LANGUAGE plpgsql;

-- 预热
\echo ''
\echo '预热...'
DO $$ DECLARE dummy RECORD; BEGIN SELECT * INTO dummy FROM test_nrindex_lookup(5000); END $$;

-- 执行测试
\echo ''
\echo '=============================================='
\echo 'NRINDEX Index Only Scan (1000000 次查询)'
\echo '=============================================='

SELECT
    ROUND(ms, 2) AS "总时间(ms)",
    cnt AS "查询数",
    ROUND(us, 2) AS "平均(μs)",
    ROUND(qps, 0) AS "吞吐量(QPS)"
FROM test_nrindex_lookup(1000000);

-- 清理
DROP FUNCTION IF EXISTS test_nrindex_lookup(INT);

\echo ''
\echo '测试完成! 请记录结果，然后切换配置重新测试对比'
