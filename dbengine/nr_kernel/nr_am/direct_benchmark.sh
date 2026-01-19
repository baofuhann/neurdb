#!/bin/bash
# =============================================
# 直接性能测试: NRINDEX vs BTREE
# 使用吞吐量 (TPS) 展示结果
# =============================================

PSQL="/code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb"
TOTAL_OPS=${1:-5000}

echo "=============================================="
echo "   直接性能测试: NRINDEX vs BTREE"
echo "   每种工作负载操作数: $TOTAL_OPS"
echo "=============================================="
echo ""

$PSQL -q << EOF
SET enable_seqscan = off;
SET client_min_messages = WARNING;

DROP TABLE IF EXISTS _test_read_keys;
DROP TABLE IF EXISTS _test_write_keys;
CREATE TEMP TABLE _test_read_keys AS SELECT val FROM _qk_array ORDER BY random() LIMIT 1000;
CREATE TEMP TABLE _test_write_keys AS SELECT val FROM _ik_array ORDER BY random() LIMIT 1000;

SET client_min_messages = NOTICE;

DO \$\$
DECLARE
    v_total_ops INT := $TOTAL_OPS;
    v_read_ops INT;
    v_write_ops INT;
    v_key BIGINT;
    v_start TIMESTAMP;
    r RECORD;
    i INT;
    v_base_id INT := 30000000;

    -- 时间（秒）
    v_nr_read_sec NUMERIC;
    v_nr_write_sec NUMERIC;
    v_bt_read_sec NUMERIC;
    v_bt_write_sec NUMERIC;

    -- 吞吐量 (TPS)
    v_nr_read_tps NUMERIC;
    v_nr_write_tps NUMERIC;
    v_nr_total_tps NUMERIC;
    v_bt_read_tps NUMERIC;
    v_bt_write_tps NUMERIC;
    v_bt_total_tps NUMERIC;
    v_speedup NUMERIC;
BEGIN
    RAISE NOTICE '==============================================';
    RAISE NOTICE '工作负载     | NR读TPS  | NR写TPS  | NR总TPS  | BT读TPS  | BT写TPS  | BT总TPS  | 加速比';
    RAISE NOTICE '-------------+----------+----------+----------+----------+----------+----------+--------';

    -- ========== 1. read_only (100% 读) ==========
    v_read_ops := v_total_ops; v_write_ops := 0;

    v_start := clock_timestamp();
    FOR i IN 1..v_read_ops LOOP
        SELECT val INTO v_key FROM _test_read_keys OFFSET (i % 1000) LIMIT 1;
        SELECT * INTO r FROM covid_nrindex WHERE val = v_key LIMIT 1;
    END LOOP;
    v_nr_read_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);
    v_nr_write_sec := 0;

    v_start := clock_timestamp();
    FOR i IN 1..v_read_ops LOOP
        SELECT val INTO v_key FROM _test_read_keys OFFSET (i % 1000) LIMIT 1;
        SELECT * INTO r FROM covid_btree WHERE val = v_key LIMIT 1;
    END LOOP;
    v_bt_read_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);
    v_bt_write_sec := 0;

    v_nr_read_tps := ROUND(v_read_ops / NULLIF(v_nr_read_sec, 0));
    v_nr_write_tps := 0;
    v_nr_total_tps := ROUND(v_total_ops / NULLIF(v_nr_read_sec + v_nr_write_sec, 0));
    v_bt_read_tps := ROUND(v_read_ops / NULLIF(v_bt_read_sec, 0));
    v_bt_write_tps := 0;
    v_bt_total_tps := ROUND(v_total_ops / NULLIF(v_bt_read_sec + v_bt_write_sec, 0));
    v_speedup := v_nr_total_tps / NULLIF(v_bt_total_tps, 0);

    RAISE NOTICE 'read_only    | % | % | % | % | % | % | %x',
        LPAD(v_nr_read_tps::TEXT, 8), LPAD('-', 8), LPAD(v_nr_total_tps::TEXT, 8),
        LPAD(v_bt_read_tps::TEXT, 8), LPAD('-', 8), LPAD(v_bt_total_tps::TEXT, 8),
        ROUND(v_speedup, 2);

    -- ========== 2. read_heavy (80% 读, 20% 写) ==========
    v_read_ops := v_total_ops * 80 / 100; v_write_ops := v_total_ops - v_read_ops;

    v_start := clock_timestamp();
    FOR i IN 1..v_read_ops LOOP
        SELECT val INTO v_key FROM _test_read_keys OFFSET (i % 1000) LIMIT 1;
        SELECT * INTO r FROM covid_nrindex WHERE val = v_key LIMIT 1;
    END LOOP;
    v_nr_read_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);

    v_start := clock_timestamp();
    FOR i IN 1..v_write_ops LOOP
        SELECT val INTO v_key FROM _test_write_keys OFFSET (i % 1000) LIMIT 1;
        INSERT INTO covid_nrindex (id, val) VALUES (v_base_id + i, v_key);
    END LOOP;
    v_nr_write_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);
    DELETE FROM covid_nrindex WHERE id >= v_base_id;

    v_start := clock_timestamp();
    FOR i IN 1..v_read_ops LOOP
        SELECT val INTO v_key FROM _test_read_keys OFFSET (i % 1000) LIMIT 1;
        SELECT * INTO r FROM covid_btree WHERE val = v_key LIMIT 1;
    END LOOP;
    v_bt_read_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);

    v_start := clock_timestamp();
    FOR i IN 1..v_write_ops LOOP
        SELECT val INTO v_key FROM _test_write_keys OFFSET (i % 1000) LIMIT 1;
        INSERT INTO covid_btree (id, val) VALUES (v_base_id + i, v_key);
    END LOOP;
    v_bt_write_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);
    DELETE FROM covid_btree WHERE id >= v_base_id;

    v_nr_read_tps := ROUND(v_read_ops / NULLIF(v_nr_read_sec, 0));
    v_nr_write_tps := ROUND(v_write_ops / NULLIF(v_nr_write_sec, 0));
    v_nr_total_tps := ROUND(v_total_ops / NULLIF(v_nr_read_sec + v_nr_write_sec, 0));
    v_bt_read_tps := ROUND(v_read_ops / NULLIF(v_bt_read_sec, 0));
    v_bt_write_tps := ROUND(v_write_ops / NULLIF(v_bt_write_sec, 0));
    v_bt_total_tps := ROUND(v_total_ops / NULLIF(v_bt_read_sec + v_bt_write_sec, 0));
    v_speedup := v_nr_total_tps / NULLIF(v_bt_total_tps, 0);

    RAISE NOTICE 'read_heavy   | % | % | % | % | % | % | %x',
        LPAD(v_nr_read_tps::TEXT, 8), LPAD(v_nr_write_tps::TEXT, 8), LPAD(v_nr_total_tps::TEXT, 8),
        LPAD(v_bt_read_tps::TEXT, 8), LPAD(v_bt_write_tps::TEXT, 8), LPAD(v_bt_total_tps::TEXT, 8),
        ROUND(v_speedup, 2);

    -- ========== 3. balanced (50% 读, 50% 写) ==========
    v_read_ops := v_total_ops / 2; v_write_ops := v_total_ops - v_read_ops;

    v_start := clock_timestamp();
    FOR i IN 1..v_read_ops LOOP
        SELECT val INTO v_key FROM _test_read_keys OFFSET (i % 1000) LIMIT 1;
        SELECT * INTO r FROM covid_nrindex WHERE val = v_key LIMIT 1;
    END LOOP;
    v_nr_read_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);

    v_start := clock_timestamp();
    FOR i IN 1..v_write_ops LOOP
        SELECT val INTO v_key FROM _test_write_keys OFFSET (i % 1000) LIMIT 1;
        INSERT INTO covid_nrindex (id, val) VALUES (v_base_id + i, v_key);
    END LOOP;
    v_nr_write_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);
    DELETE FROM covid_nrindex WHERE id >= v_base_id;

    v_start := clock_timestamp();
    FOR i IN 1..v_read_ops LOOP
        SELECT val INTO v_key FROM _test_read_keys OFFSET (i % 1000) LIMIT 1;
        SELECT * INTO r FROM covid_btree WHERE val = v_key LIMIT 1;
    END LOOP;
    v_bt_read_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);

    v_start := clock_timestamp();
    FOR i IN 1..v_write_ops LOOP
        SELECT val INTO v_key FROM _test_write_keys OFFSET (i % 1000) LIMIT 1;
        INSERT INTO covid_btree (id, val) VALUES (v_base_id + i, v_key);
    END LOOP;
    v_bt_write_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);
    DELETE FROM covid_btree WHERE id >= v_base_id;

    v_nr_read_tps := ROUND(v_read_ops / NULLIF(v_nr_read_sec, 0));
    v_nr_write_tps := ROUND(v_write_ops / NULLIF(v_nr_write_sec, 0));
    v_nr_total_tps := ROUND(v_total_ops / NULLIF(v_nr_read_sec + v_nr_write_sec, 0));
    v_bt_read_tps := ROUND(v_read_ops / NULLIF(v_bt_read_sec, 0));
    v_bt_write_tps := ROUND(v_write_ops / NULLIF(v_bt_write_sec, 0));
    v_bt_total_tps := ROUND(v_total_ops / NULLIF(v_bt_read_sec + v_bt_write_sec, 0));
    v_speedup := v_nr_total_tps / NULLIF(v_bt_total_tps, 0);

    RAISE NOTICE 'balanced     | % | % | % | % | % | % | %x',
        LPAD(v_nr_read_tps::TEXT, 8), LPAD(v_nr_write_tps::TEXT, 8), LPAD(v_nr_total_tps::TEXT, 8),
        LPAD(v_bt_read_tps::TEXT, 8), LPAD(v_bt_write_tps::TEXT, 8), LPAD(v_bt_total_tps::TEXT, 8),
        ROUND(v_speedup, 2);

    -- ========== 4. write_heavy (20% 读, 80% 写) ==========
    v_read_ops := v_total_ops * 20 / 100; v_write_ops := v_total_ops - v_read_ops;

    v_start := clock_timestamp();
    FOR i IN 1..v_read_ops LOOP
        SELECT val INTO v_key FROM _test_read_keys OFFSET (i % 1000) LIMIT 1;
        SELECT * INTO r FROM covid_nrindex WHERE val = v_key LIMIT 1;
    END LOOP;
    v_nr_read_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);

    v_start := clock_timestamp();
    FOR i IN 1..v_write_ops LOOP
        SELECT val INTO v_key FROM _test_write_keys OFFSET (i % 1000) LIMIT 1;
        INSERT INTO covid_nrindex (id, val) VALUES (v_base_id + i, v_key);
    END LOOP;
    v_nr_write_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);
    DELETE FROM covid_nrindex WHERE id >= v_base_id;

    v_start := clock_timestamp();
    FOR i IN 1..v_read_ops LOOP
        SELECT val INTO v_key FROM _test_read_keys OFFSET (i % 1000) LIMIT 1;
        SELECT * INTO r FROM covid_btree WHERE val = v_key LIMIT 1;
    END LOOP;
    v_bt_read_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);

    v_start := clock_timestamp();
    FOR i IN 1..v_write_ops LOOP
        SELECT val INTO v_key FROM _test_write_keys OFFSET (i % 1000) LIMIT 1;
        INSERT INTO covid_btree (id, val) VALUES (v_base_id + i, v_key);
    END LOOP;
    v_bt_write_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);
    DELETE FROM covid_btree WHERE id >= v_base_id;

    v_nr_read_tps := ROUND(v_read_ops / NULLIF(v_nr_read_sec, 0));
    v_nr_write_tps := ROUND(v_write_ops / NULLIF(v_nr_write_sec, 0));
    v_nr_total_tps := ROUND(v_total_ops / NULLIF(v_nr_read_sec + v_nr_write_sec, 0));
    v_bt_read_tps := ROUND(v_read_ops / NULLIF(v_bt_read_sec, 0));
    v_bt_write_tps := ROUND(v_write_ops / NULLIF(v_bt_write_sec, 0));
    v_bt_total_tps := ROUND(v_total_ops / NULLIF(v_bt_read_sec + v_bt_write_sec, 0));
    v_speedup := v_nr_total_tps / NULLIF(v_bt_total_tps, 0);

    RAISE NOTICE 'write_heavy  | % | % | % | % | % | % | %x',
        LPAD(v_nr_read_tps::TEXT, 8), LPAD(v_nr_write_tps::TEXT, 8), LPAD(v_nr_total_tps::TEXT, 8),
        LPAD(v_bt_read_tps::TEXT, 8), LPAD(v_bt_write_tps::TEXT, 8), LPAD(v_bt_total_tps::TEXT, 8),
        ROUND(v_speedup, 2);

    -- ========== 5. write_only (0% 读, 100% 写) ==========
    v_read_ops := 0; v_write_ops := v_total_ops;
    v_nr_read_sec := 0; v_bt_read_sec := 0;

    v_start := clock_timestamp();
    FOR i IN 1..v_write_ops LOOP
        SELECT val INTO v_key FROM _test_write_keys OFFSET (i % 1000) LIMIT 1;
        INSERT INTO covid_nrindex (id, val) VALUES (v_base_id + i, v_key);
    END LOOP;
    v_nr_write_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);
    DELETE FROM covid_nrindex WHERE id >= v_base_id;

    v_start := clock_timestamp();
    FOR i IN 1..v_write_ops LOOP
        SELECT val INTO v_key FROM _test_write_keys OFFSET (i % 1000) LIMIT 1;
        INSERT INTO covid_btree (id, val) VALUES (v_base_id + i, v_key);
    END LOOP;
    v_bt_write_sec := EXTRACT(EPOCH FROM clock_timestamp() - v_start);
    DELETE FROM covid_btree WHERE id >= v_base_id;

    v_nr_write_tps := ROUND(v_write_ops / NULLIF(v_nr_write_sec, 0));
    v_nr_total_tps := v_nr_write_tps;
    v_bt_write_tps := ROUND(v_write_ops / NULLIF(v_bt_write_sec, 0));
    v_bt_total_tps := v_bt_write_tps;
    v_speedup := v_nr_total_tps / NULLIF(v_bt_total_tps, 0);

    RAISE NOTICE 'write_only   | % | % | % | % | % | % | %x',
        LPAD('-', 8), LPAD(v_nr_write_tps::TEXT, 8), LPAD(v_nr_total_tps::TEXT, 8),
        LPAD('-', 8), LPAD(v_bt_write_tps::TEXT, 8), LPAD(v_bt_total_tps::TEXT, 8),
        ROUND(v_speedup, 2);

    RAISE NOTICE '==============================================';
    RAISE NOTICE '';
    RAISE NOTICE 'TPS = 每秒事务数 (越高越好)';
    RAISE NOTICE '加速比 > 1.0 表示 NRINDEX 更快';
END;
\$\$;
EOF

echo ""
echo "测试完成!"
