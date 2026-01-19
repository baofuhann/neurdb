#!/bin/bash

# ==============================================
# 数据构造脚本 - 用于索引性能测试
# 直接从已有CSV文件导入数据
# ==============================================

set -e

# 配置参数 - 已有的数据文件路径
BULK_LOAD_FILE="/hdd9/benjamin/adaptive-learned-index/result_figure_revison/covid_bulk_load.csv"
QUERY_KEY_FILE="/hdd9/benjamin/adaptive-learned-index/result_figure_revison/covid_query_key.csv"
INSERT_KEY_FILE="/hdd9/benjamin/adaptive-learned-index/result_figure_revison/covid_insert_key.csv"

# 导入数量配置 (设为0表示导入全部)
BULK_LOAD_COUNT=${BULK_LOAD_COUNT:-1000000}    # 默认100万
QUERY_KEY_COUNT=${QUERY_KEY_COUNT:-100000}     # 默认10万
INSERT_KEY_COUNT=${INSERT_KEY_COUNT:-100000}   # 默认10万

echo "数据导入配置:"
echo "  BULK_LOAD_COUNT=$BULK_LOAD_COUNT"
echo "  QUERY_KEY_COUNT=$QUERY_KEY_COUNT"
echo "  INSERT_KEY_COUNT=$INSERT_KEY_COUNT"
echo ""
echo "可通过环境变量修改，例如:"
echo "  BULK_LOAD_COUNT=5000000 QUERY_KEY_COUNT=500000 bash final_test.sh"

DB_NAME="neurdb"

# ==============================================
# 步骤1: 创建数据表
# ==============================================
echo "=== 步骤1: 创建数据表 ==="

psql -d ${DB_NAME} << 'SQLEOF'
-- 删除已存在的表
DROP TABLE IF EXISTS covid_nrindex CASCADE;
DROP TABLE IF EXISTS covid_btree CASCADE;
DROP TABLE IF EXISTS query_keys CASCADE;
DROP TABLE IF EXISTS insert_keys CASCADE;

-- 创建 covid_nrindex 表 (用于nrindex索引测试)
CREATE TABLE covid_nrindex (
    id INT PRIMARY KEY,
    val BIGINT
);

-- 创建 covid_btree 表 (用于btree索引对比测试)
CREATE TABLE covid_btree (
    id INT PRIMARY KEY,
    val BIGINT
);

-- 创建 query_keys 表 (存储查询用的key)
CREATE TABLE query_keys (
    id INT PRIMARY KEY,
    val BIGINT
);

-- 创建 insert_keys 表 (存储待插入的key)
CREATE TABLE insert_keys (
    id INT PRIMARY KEY,
    val BIGINT
);

\echo '表创建完成'
SQLEOF

# ==============================================
# 步骤2: 导入数据
# ==============================================
echo ""
echo "=== 步骤2: 导入数据 ==="

echo "导入 bulk_load 数据到 covid_nrindex (${BULK_LOAD_COUNT} 条)..."
psql -d ${DB_NAME} << SQLEOF
CREATE TEMP TABLE tmp_load (val BIGINT);
COPY tmp_load(val) FROM PROGRAM 'tail -n +2 "${BULK_LOAD_FILE}" | head -n ${BULK_LOAD_COUNT}';
INSERT INTO covid_nrindex (id, val) SELECT row_number() OVER ()::INT, val FROM tmp_load;
DROP TABLE tmp_load;
SQLEOF

echo "导入 bulk_load 数据到 covid_btree (${BULK_LOAD_COUNT} 条)..."
psql -d ${DB_NAME} << SQLEOF
CREATE TEMP TABLE tmp_load (val BIGINT);
COPY tmp_load(val) FROM PROGRAM 'tail -n +2 "${BULK_LOAD_FILE}" | head -n ${BULK_LOAD_COUNT}';
INSERT INTO covid_btree (id, val) SELECT row_number() OVER ()::INT, val FROM tmp_load;
DROP TABLE tmp_load;
SQLEOF

echo "导入 query_key 数据到 query_keys (${QUERY_KEY_COUNT} 条)..."
psql -d ${DB_NAME} << SQLEOF
CREATE TEMP TABLE tmp_load (val BIGINT);
COPY tmp_load(val) FROM PROGRAM 'tail -n +2 "${QUERY_KEY_FILE}" | head -n ${QUERY_KEY_COUNT}';
INSERT INTO query_keys (id, val) SELECT row_number() OVER ()::INT, val FROM tmp_load;
DROP TABLE tmp_load;
SQLEOF

echo "导入 insert_key 数据到 insert_keys (${INSERT_KEY_COUNT} 条)..."
psql -d ${DB_NAME} << SQLEOF
CREATE TEMP TABLE tmp_load (val BIGINT);
COPY tmp_load(val) FROM PROGRAM 'tail -n +2 "${INSERT_KEY_FILE}" | head -n ${INSERT_KEY_COUNT}';
INSERT INTO insert_keys (id, val) SELECT row_number() OVER ()::INT, val FROM tmp_load;
DROP TABLE tmp_load;
SQLEOF

echo "验证导入的数据:"
psql -d ${DB_NAME} -c "SELECT 'covid_nrindex' as table_name, count(*) FROM covid_nrindex UNION ALL SELECT 'covid_btree', count(*) FROM covid_btree UNION ALL SELECT 'query_keys', count(*) FROM query_keys UNION ALL SELECT 'insert_keys', count(*) FROM insert_keys;"

# ==============================================
# 步骤3: 创建索引
# ==============================================
echo ""
echo "=== 步骤3: 创建索引 ==="

echo "在 covid_nrindex 上创建 nrindex 索引..."
psql -d ${DB_NAME} -c "CREATE INDEX idx_covid_nrindex ON covid_nrindex USING nrindex(val);"

echo "在 covid_btree 上创建 btree 索引..."
psql -d ${DB_NAME} -c "CREATE INDEX idx_covid_btree ON covid_btree USING btree(val);"

echo ""
echo "=== 数据准备完成 ==="
echo "- covid_nrindex: ${BULK_LOAD_COUNT} 条记录，已创建 nrindex 索引"
echo "- covid_btree: ${BULK_LOAD_COUNT} 条记录，已创建 btree 索引"
echo "- query_keys: ${QUERY_KEY_COUNT} 条查询key"
echo "- insert_keys: ${INSERT_KEY_COUNT} 条待插入key"

# ==============================================
# 步骤4: 准备辅助查询表
# ==============================================
echo ""
echo "=== 步骤4: 准备辅助查询表 ==="

psql -d ${DB_NAME} << 'SQLEOF'
-- 创建查询key索引表 (用于随机查询)
DROP TABLE IF EXISTS qk_idx;
CREATE UNLOGGED TABLE qk_idx (id INT PRIMARY KEY, val BIGINT);
INSERT INTO qk_idx SELECT id, val FROM query_keys;
ANALYZE qk_idx;

-- 创建插入key索引表 (用于随机插入)
DROP TABLE IF EXISTS ik_idx;
CREATE UNLOGGED TABLE ik_idx (id INT PRIMARY KEY, val BIGINT);
INSERT INTO ik_idx SELECT id, val FROM insert_keys;
ANALYZE ik_idx;

\echo '辅助表创建完成'
SQLEOF

# ==============================================
# 步骤5: 工作负载测试 (纯SQL实现)
# ==============================================
echo ""
echo "=============================================="
echo "步骤5: 工作负载性能测试 (纯SQL)"
echo "=============================================="

# 测试参数
TOTAL_OPS=100000

# 获取当前最大ID
NRINDEX_MAX_ID=$(psql -d ${DB_NAME} -t -A -c "SELECT COALESCE(MAX(id), 0) FROM covid_nrindex;")
BTREE_MAX_ID=$(psql -d ${DB_NAME} -t -A -c "SELECT COALESCE(MAX(id), 0) FROM covid_btree;")

echo "NRINDEX_MAX_ID: $NRINDEX_MAX_ID"
echo "BTREE_MAX_ID: $BTREE_MAX_ID"
echo "每个测试执行 $TOTAL_OPS 次操作"

# 用于存储性能结果的数组
declare -a WORKLOAD_NAMES
declare -a NRINDEX_TIMES
declare -a BTREE_TIMES
TEST_IDX=0

# 函数: 提取时间 (ms)
extract_time_ms() {
    echo "$1" | grep -oP 'Time: \K[0-9]+\.[0-9]+' | tail -1
}

# ==============================================
# 测试 1: read_only (100% 查询)
# ==============================================
echo ""
echo "=============================================="
echo "测试 1: read_only (100% 查询, ${TOTAL_OPS}次)"
echo "=============================================="

WORKLOAD_NAMES[$TEST_IDX]="read_only (100% 查询)"

echo "--- covid_nrindex ---"
NRINDEX_OUTPUT=$(psql -d ${DB_NAME} << SQLEOF
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;
\timing on

-- 执行 ${TOTAL_OPS} 次随机查询
SELECT COUNT(*) as total_found FROM (
    SELECT (SELECT id FROM covid_nrindex WHERE val = q.val LIMIT 1)
    FROM (SELECT val FROM qk_idx ORDER BY random() LIMIT ${TOTAL_OPS}) q
) t;

\timing off
SQLEOF
)
echo "$NRINDEX_OUTPUT"
NRINDEX_TIMES[$TEST_IDX]=$(extract_time_ms "$NRINDEX_OUTPUT")

echo "--- covid_btree ---"
BTREE_OUTPUT=$(psql -d ${DB_NAME} << SQLEOF
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;
\timing on

SELECT COUNT(*) as total_found FROM (
    SELECT (SELECT id FROM covid_btree WHERE val = q.val LIMIT 1)
    FROM (SELECT val FROM qk_idx ORDER BY random() LIMIT ${TOTAL_OPS}) q
) t;

\timing off
SQLEOF
)
echo "$BTREE_OUTPUT"
BTREE_TIMES[$TEST_IDX]=$(extract_time_ms "$BTREE_OUTPUT")

TEST_IDX=$((TEST_IDX + 1))

# # ==============================================
# # 测试 2: read_heavy (80% 查询, 20% 插入)
# # ==============================================
# echo ""
# echo "=============================================="
# echo "测试 2: read_heavy (80% 查询, 20% 插入)"
# echo "=============================================="

# QUERY_OPS=$((TOTAL_OPS * 80 / 100))
# INSERT_OPS=$((TOTAL_OPS * 20 / 100))

# echo "--- covid_nrindex (查询:${QUERY_OPS}, 插入:${INSERT_OPS}) ---"
# psql -d ${DB_NAME} << SQLEOF
# SET enable_seqscan = off;
# SET max_parallel_workers_per_gather = 0;
# \timing on

# -- 查询
# SELECT COUNT(*) as queries FROM (
#     SELECT (SELECT id FROM covid_nrindex WHERE val = q.val LIMIT 1)
#     FROM (SELECT val FROM qk_idx ORDER BY random() LIMIT ${QUERY_OPS}) q
# ) t;

# -- 插入
# INSERT INTO covid_nrindex (id, val)
# SELECT ${NRINDEX_MAX_ID} + row_number() OVER (), val
# FROM (SELECT val FROM ik_idx ORDER BY random() LIMIT ${INSERT_OPS}) t
# ON CONFLICT (id) DO NOTHING;

# \timing off
# SQLEOF

# echo "--- covid_btree (查询:${QUERY_OPS}, 插入:${INSERT_OPS}) ---"
# psql -d ${DB_NAME} << SQLEOF
# SET enable_seqscan = off;
# SET max_parallel_workers_per_gather = 0;
# \timing on

# SELECT COUNT(*) as queries FROM (
#     SELECT (SELECT id FROM covid_btree WHERE val = q.val LIMIT 1)
#     FROM (SELECT val FROM qk_idx ORDER BY random() LIMIT ${QUERY_OPS}) q
# ) t;

# INSERT INTO covid_btree (id, val)
# SELECT ${BTREE_MAX_ID} + row_number() OVER (), val
# FROM (SELECT val FROM ik_idx ORDER BY random() LIMIT ${INSERT_OPS}) t
# ON CONFLICT (id) DO NOTHING;

# \timing off
# SQLEOF

# # 清理插入的数据
# psql -d ${DB_NAME} -c "DELETE FROM covid_nrindex WHERE id > $NRINDEX_MAX_ID;" 2>/dev/null
# psql -d ${DB_NAME} -c "DELETE FROM covid_btree WHERE id > $BTREE_MAX_ID;" 2>/dev/null

# # ==============================================
# # 测试 3: balanced (50% 查询, 50% 插入)
# # ==============================================
# echo ""
# echo "=============================================="
# echo "测试 3: balanced (50% 查询, 50% 插入)"
# echo "=============================================="

# QUERY_OPS=$((TOTAL_OPS * 50 / 100))
# INSERT_OPS=$((TOTAL_OPS * 50 / 100))

# echo "--- covid_nrindex (查询:${QUERY_OPS}, 插入:${INSERT_OPS}) ---"
# psql -d ${DB_NAME} << SQLEOF
# SET enable_seqscan = off;
# SET max_parallel_workers_per_gather = 0;
# \timing on

# SELECT COUNT(*) as queries FROM (
#     SELECT (SELECT id FROM covid_nrindex WHERE val = q.val LIMIT 1)
#     FROM (SELECT val FROM qk_idx ORDER BY random() LIMIT ${QUERY_OPS}) q
# ) t;

# INSERT INTO covid_nrindex (id, val)
# SELECT ${NRINDEX_MAX_ID} + row_number() OVER (), val
# FROM (SELECT val FROM ik_idx ORDER BY random() LIMIT ${INSERT_OPS}) t
# ON CONFLICT (id) DO NOTHING;

# \timing off
# SQLEOF

# echo "--- covid_btree (查询:${QUERY_OPS}, 插入:${INSERT_OPS}) ---"
# psql -d ${DB_NAME} << SQLEOF
# SET enable_seqscan = off;
# SET max_parallel_workers_per_gather = 0;
# \timing on

# SELECT COUNT(*) as queries FROM (
#     SELECT (SELECT id FROM covid_btree WHERE val = q.val LIMIT 1)
#     FROM (SELECT val FROM qk_idx ORDER BY random() LIMIT ${QUERY_OPS}) q
# ) t;

# INSERT INTO covid_btree (id, val)
# SELECT ${BTREE_MAX_ID} + row_number() OVER (), val
# FROM (SELECT val FROM ik_idx ORDER BY random() LIMIT ${INSERT_OPS}) t
# ON CONFLICT (id) DO NOTHING;

# \timing off
# SQLEOF

# psql -d ${DB_NAME} -c "DELETE FROM covid_nrindex WHERE id > $NRINDEX_MAX_ID;" 2>/dev/null
# psql -d ${DB_NAME} -c "DELETE FROM covid_btree WHERE id > $BTREE_MAX_ID;" 2>/dev/null

# # ==============================================
# # 测试 4: write_heavy (20% 查询, 80% 插入)
# # ==============================================
# echo ""
# echo "=============================================="
# echo "测试 4: write_heavy (20% 查询, 80% 插入)"
# echo "=============================================="

# QUERY_OPS=$((TOTAL_OPS * 20 / 100))
# INSERT_OPS=$((TOTAL_OPS * 80 / 100))

# echo "--- covid_nrindex (查询:${QUERY_OPS}, 插入:${INSERT_OPS}) ---"
# psql -d ${DB_NAME} << SQLEOF
# SET enable_seqscan = off;
# SET max_parallel_workers_per_gather = 0;
# \timing on

# SELECT COUNT(*) as queries FROM (
#     SELECT (SELECT id FROM covid_nrindex WHERE val = q.val LIMIT 1)
#     FROM (SELECT val FROM qk_idx ORDER BY random() LIMIT ${QUERY_OPS}) q
# ) t;

# INSERT INTO covid_nrindex (id, val)
# SELECT ${NRINDEX_MAX_ID} + row_number() OVER (), val
# FROM (SELECT val FROM ik_idx ORDER BY random() LIMIT ${INSERT_OPS}) t
# ON CONFLICT (id) DO NOTHING;

# \timing off
# SQLEOF

# echo "--- covid_btree (查询:${QUERY_OPS}, 插入:${INSERT_OPS}) ---"
# psql -d ${DB_NAME} << SQLEOF
# SET enable_seqscan = off;
# SET max_parallel_workers_per_gather = 0;
# \timing on

# SELECT COUNT(*) as queries FROM (
#     SELECT (SELECT id FROM covid_btree WHERE val = q.val LIMIT 1)
#     FROM (SELECT val FROM qk_idx ORDER BY random() LIMIT ${QUERY_OPS}) q
# ) t;

# INSERT INTO covid_btree (id, val)
# SELECT ${BTREE_MAX_ID} + row_number() OVER (), val
# FROM (SELECT val FROM ik_idx ORDER BY random() LIMIT ${INSERT_OPS}) t
# ON CONFLICT (id) DO NOTHING;

# \timing off
# SQLEOF

# psql -d ${DB_NAME} -c "DELETE FROM covid_nrindex WHERE id > $NRINDEX_MAX_ID;" 2>/dev/null
# psql -d ${DB_NAME} -c "DELETE FROM covid_btree WHERE id > $BTREE_MAX_ID;" 2>/dev/null

# # ==============================================
# # 测试 5: write_only (100% 插入)
# # ==============================================
# echo ""
# echo "=============================================="
# echo "测试 5: write_only (100% 插入, ${TOTAL_OPS}次)"
# echo "=============================================="

# echo "--- covid_nrindex ---"
# psql -d ${DB_NAME} << SQLEOF
# SET enable_seqscan = off;
# \timing on

# INSERT INTO covid_nrindex (id, val)
# SELECT ${NRINDEX_MAX_ID} + row_number() OVER (), val
# FROM (SELECT val FROM ik_idx ORDER BY random() LIMIT ${TOTAL_OPS}) t
# ON CONFLICT (id) DO NOTHING;

# \timing off
# SQLEOF

# echo "--- covid_btree ---"
# psql -d ${DB_NAME} << SQLEOF
# SET enable_seqscan = off;
# \timing on

# INSERT INTO covid_btree (id, val)
# SELECT ${BTREE_MAX_ID} + row_number() OVER (), val
# FROM (SELECT val FROM ik_idx ORDER BY random() LIMIT ${TOTAL_OPS}) t
# ON CONFLICT (id) DO NOTHING;

# \timing off
# SQLEOF

# 清理
psql -d ${DB_NAME} -c "DELETE FROM covid_nrindex WHERE id > $NRINDEX_MAX_ID;" 2>/dev/null
psql -d ${DB_NAME} -c "DELETE FROM covid_btree WHERE id > $BTREE_MAX_ID;" 2>/dev/null

echo ""
echo "=============================================="
echo "所有测试完成!"
echo "=============================================="

# ==============================================
# 性能汇总报告
# ==============================================
echo ""
echo "=============================================="
echo "          性 能 汇 总 报 告"
echo "=============================================="
echo ""
echo "测试配置:"
echo "  - 数据量: ${BULK_LOAD_COUNT} 条"
echo "  - 查询key数: ${QUERY_KEY_COUNT} 条"
echo "  - 每个测试操作数: ${TOTAL_OPS} 次"
echo ""
printf "%-30s %15s %15s %15s\n" "工作负载" "nrindex (ms)" "btree (ms)" "提升倍数"
printf "%-30s %15s %15s %15s\n" "------------------------------" "---------------" "---------------" "---------------"

for i in $(seq 0 $((TEST_IDX - 1))); do
    WORKLOAD="${WORKLOAD_NAMES[$i]}"
    NRINDEX_T="${NRINDEX_TIMES[$i]}"
    BTREE_T="${BTREE_TIMES[$i]}"

    if [ -n "$NRINDEX_T" ] && [ -n "$BTREE_T" ] && [ "$NRINDEX_T" != "0" ]; then
        SPEEDUP=$(awk "BEGIN {printf \"%.2f\", $BTREE_T / $NRINDEX_T}")
        printf "%-30s %15.2f %15.2f %14.2fx\n" "$WORKLOAD" "$NRINDEX_T" "$BTREE_T" "$SPEEDUP"
    else
        printf "%-30s %15s %15s %15s\n" "$WORKLOAD" "${NRINDEX_T:-N/A}" "${BTREE_T:-N/A}" "N/A"
    fi
done

echo ""
echo "=============================================="
echo "结论:"
if [ -n "${NRINDEX_TIMES[0]}" ] && [ -n "${BTREE_TIMES[0]}" ] && [ "${NRINDEX_TIMES[0]}" != "0" ]; then
    AVG_SPEEDUP=$(awk "BEGIN {printf \"%.2f\", ${BTREE_TIMES[0]} / ${NRINDEX_TIMES[0]}}")
    IS_FASTER=$(awk "BEGIN {print (${AVG_SPEEDUP} > 1) ? 1 : 0}")
    IS_SLOWER=$(awk "BEGIN {print (${AVG_SPEEDUP} < 1) ? 1 : 0}")
    if [ "$IS_FASTER" = "1" ]; then
        echo "nrindex 相比 btree 性能提升 ${AVG_SPEEDUP}x"
    elif [ "$IS_SLOWER" = "1" ]; then
        SLOWDOWN=$(awk "BEGIN {printf \"%.2f\", 1 / ${AVG_SPEEDUP}}")
        echo "nrindex 相比 btree 性能下降 ${SLOWDOWN}x"
    else
        echo "nrindex 和 btree 性能相当"
    fi
fi
echo "=============================================="
