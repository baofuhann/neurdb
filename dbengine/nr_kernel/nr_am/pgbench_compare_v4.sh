#!/bin/bash
# =============================================
# SQL 对比测试: NRINDEX vs BTREE
# 支持5种工作负载的性能测试
# =============================================
# Usage: ./pgbench_compare_v4.sh <workload> [operation_count]
#
# Workloads:
#   read_only   - 100% 查询
#   read_heavy  - 80% 查询, 20% 插入
#   balanced    - 50% 查询, 50% 插入
#   write_heavy - 20% 查询, 80% 插入
#   write_only  - 100% 插入
#
# Examples:
#   ./pgbench_compare_v4.sh read_only
#   ./pgbench_compare_v4.sh read_heavy 100000
#   ./pgbench_compare_v4.sh balanced 50000

# ============================================
# 参数解析
# ============================================
WORKLOAD=${1:-""}
OPERATION_COUNT=${2:-50000}

# 工作负载定义 (查询比例, 插入比例)
declare -A WORKLOAD_READ_PCT
declare -A WORKLOAD_WRITE_PCT
declare -A WORKLOAD_DESC

WORKLOAD_READ_PCT["read_only"]=100
WORKLOAD_WRITE_PCT["read_only"]=0
WORKLOAD_DESC["read_only"]="100% 查询"

WORKLOAD_READ_PCT["read_heavy"]=80
WORKLOAD_WRITE_PCT["read_heavy"]=20
WORKLOAD_DESC["read_heavy"]="80% 查询, 20% 插入"

WORKLOAD_READ_PCT["balanced"]=50
WORKLOAD_WRITE_PCT["balanced"]=50
WORKLOAD_DESC["balanced"]="50% 查询, 50% 插入"

WORKLOAD_READ_PCT["write_heavy"]=20
WORKLOAD_WRITE_PCT["write_heavy"]=80
WORKLOAD_DESC["write_heavy"]="20% 查询, 80% 插入"

WORKLOAD_READ_PCT["write_only"]=0
WORKLOAD_WRITE_PCT["write_only"]=100
WORKLOAD_DESC["write_only"]="100% 插入"

# 检查工作负载参数
if [ -z "$WORKLOAD" ] || [ -z "${WORKLOAD_DESC[$WORKLOAD]}" ]; then
    echo "=============================================="
    echo "NRINDEX vs BTREE 性能对比测试"
    echo "=============================================="
    echo ""
    echo "Usage: $0 <workload> [operation_count]"
    echo ""
    echo "Available workloads:"
    echo "  read_only   - 100% 查询"
    echo "  read_heavy  - 80% 查询, 20% 插入"
    echo "  balanced    - 50% 查询, 50% 插入"
    echo "  write_heavy - 20% 查询, 80% 插入"
    echo "  write_only  - 100% 插入"
    echo ""
    echo "Examples:"
    echo "  $0 read_only"
    echo "  $0 read_heavy 100000"
    echo "  $0 balanced 50000"
    exit 1
fi

# 计算读写操作数量
READ_PCT=${WORKLOAD_READ_PCT[$WORKLOAD]}
WRITE_PCT=${WORKLOAD_WRITE_PCT[$WORKLOAD]}
READ_COUNT=$((OPERATION_COUNT * READ_PCT / 100))
WRITE_COUNT=$((OPERATION_COUNT * WRITE_PCT / 100))

# ============================================
# 配置
# ============================================
BULK_LOAD_CSV="/hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_bulk_load_keys.csv"
READ_KEYS_CSV="/hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_read_keys.csv"
INSERT_KEYS_CSV="/hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_insert_keys.csv"
RESULT_CSV="/tmp/benchmark_${WORKLOAD}.csv"

PSQL="/code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb"
PG_CTL="/code/neurdb-dev/psql/bin/pg_ctl"
PG_DATA="/hdd9/benjamin/neurdb_data"
PG_LOG="/code/neurdb-dev/logfile"
ROUNDS=3

# ============================================
# 辅助函数
# ============================================
restart_db() {
    echo "重启数据库清理缓存..."
    $PG_CTL -D "$PG_DATA" -l "$PG_LOG" restart -w -t 60 > /dev/null 2>&1
    sleep 2
    echo "数据库已重启"
}

# ============================================
# 检查数据文件
# ============================================
if [ ! -f "$BULK_LOAD_CSV" ]; then
    echo "错误: 主数据文件不存在: $BULK_LOAD_CSV"
    exit 1
fi

if [ "$READ_COUNT" -gt 0 ] && [ ! -f "$READ_KEYS_CSV" ]; then
    echo "错误: 查询键文件不存在: $READ_KEYS_CSV"
    exit 1
fi

if [ "$WRITE_COUNT" -gt 0 ] && [ ! -f "$INSERT_KEYS_CSV" ]; then
    echo "警告: 插入键文件不存在: $INSERT_KEYS_CSV"
    echo "将使用查询键文件作为插入键"
    INSERT_KEYS_CSV="$READ_KEYS_CSV"
fi

# ============================================
# 显示测试信息
# ============================================
echo "=============================================="
echo "NRINDEX vs BTREE 性能对比测试"
echo "=============================================="
echo "工作负载: $WORKLOAD (${WORKLOAD_DESC[$WORKLOAD]})"
echo "总操作数: $OPERATION_COUNT"
echo "  - 查询操作: $READ_COUNT (${READ_PCT}%)"
echo "  - 插入操作: $WRITE_COUNT (${WRITE_PCT}%)"
echo "测试轮数: $ROUNDS"
echo "=============================================="

# ============================================
# Step 1: 重启数据库
# ============================================
echo ""
echo "Step 1: 重启数据库确保干净状态..."
restart_db

# ============================================
# Step 2: 准备主数据表 (covid 和 covid_btree)
# ============================================
echo ""
echo "Step 2: 准备主数据表..."

# 检查 covid 表
COVID_EXISTS=$($PSQL -t -A -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'covid';")
BTREE_EXISTS=$($PSQL -t -A -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'covid_btree';")

if [ "$COVID_EXISTS" -eq 0 ] || [ "$BTREE_EXISTS" -eq 0 ]; then
    TEMP_DATA_CSV="/tmp/covid_rl_data.csv"
    echo "生成带 id 列的数据文件..."
    echo "id,val" > "$TEMP_DATA_CSV"
    tail -n +2 "$BULK_LOAD_CSV" | awk '{printf "%d,%s\n", NR, $0}' >> "$TEMP_DATA_CSV"
    DATA_COUNT=$(($(wc -l < "$TEMP_DATA_CSV") - 1))
    echo "数据行数: $DATA_COUNT"

    echo "创建并导入数据到 covid 表..."
    $PSQL << EOF
DROP TABLE IF EXISTS covid CASCADE;
CREATE TABLE covid (id INT PRIMARY KEY, val BIGINT);
\copy covid FROM '$TEMP_DATA_CSV' CSV HEADER;
SELECT 'covid' as tbl, COUNT(*) AS cnt FROM covid;
EOF

    echo "创建并导入数据到 covid_btree 表..."
    $PSQL << EOF
DROP TABLE IF EXISTS covid_btree CASCADE;
CREATE TABLE covid_btree (id INT PRIMARY KEY, val BIGINT);
\copy covid_btree FROM '$TEMP_DATA_CSV' CSV HEADER;
SELECT 'covid_btree' as tbl, COUNT(*) AS cnt FROM covid_btree;
EOF

    rm -f "$TEMP_DATA_CSV"
    echo "数据导入完成"
else
    DATA_COUNT=$($PSQL -t -A -c "SELECT COUNT(*) FROM covid;")
    echo "数据表已存在 (covid: $DATA_COUNT 行)"
fi

# ============================================
# Step 3: 准备查询键表
# ============================================
echo ""
echo "Step 3: 准备查询键表..."

$PSQL -c "DROP TABLE IF EXISTS query_keys CASCADE;" > /dev/null 2>&1

if [ "$READ_COUNT" -gt 0 ]; then
    TEMP_KEYS_CSV="/tmp/covid_query_keys.csv"
    echo "val" > "$TEMP_KEYS_CSV"
    tail -n +2 "$READ_KEYS_CSV" | head -n $READ_COUNT >> "$TEMP_KEYS_CSV"
    KEY_LINES=$(($(wc -l < "$TEMP_KEYS_CSV") - 1))
    echo "准备导入 $KEY_LINES 条查询键..."

    $PSQL << EOF
CREATE TABLE query_keys (id SERIAL PRIMARY KEY, val BIGINT);
\copy query_keys(val) FROM '$TEMP_KEYS_CSV' CSV HEADER;
SELECT COUNT(*) AS query_keys_count FROM query_keys;
EOF
    rm -f "$TEMP_KEYS_CSV"
    echo "查询键表准备完成"
else
    echo "跳过 (READ_COUNT=0)"
    $PSQL -c "CREATE TABLE query_keys (id SERIAL PRIMARY KEY, val BIGINT);" > /dev/null 2>&1
fi

# ============================================
# Step 4: 准备插入键表
# ============================================
echo ""
echo "Step 4: 准备插入键表..."

$PSQL -c "DROP TABLE IF EXISTS insert_keys CASCADE;" > /dev/null 2>&1

if [ "$WRITE_COUNT" -gt 0 ]; then
    TEMP_INSERT_CSV="/tmp/covid_insert_keys.csv"
    echo "val" > "$TEMP_INSERT_CSV"
    tail -n +2 "$INSERT_KEYS_CSV" | head -n $WRITE_COUNT >> "$TEMP_INSERT_CSV"
    INSERT_LINES=$(($(wc -l < "$TEMP_INSERT_CSV") - 1))
    echo "准备导入 $INSERT_LINES 条插入键..."

    $PSQL << EOF
CREATE TABLE insert_keys (id SERIAL PRIMARY KEY, val BIGINT);
\copy insert_keys(val) FROM '$TEMP_INSERT_CSV' CSV HEADER;
SELECT COUNT(*) AS insert_keys_count FROM insert_keys;
EOF
    rm -f "$TEMP_INSERT_CSV"
    echo "插入键表准备完成"
else
    echo "跳过 (WRITE_COUNT=0)"
    $PSQL -c "CREATE TABLE insert_keys (id SERIAL PRIMARY KEY, val BIGINT);" > /dev/null 2>&1
fi

# 验证数据准备
echo ""
echo "Step 5: 验证数据准备..."
$PSQL -c "SELECT 'covid' as tbl, COUNT(*) as cnt FROM covid UNION ALL SELECT 'covid_btree', COUNT(*) FROM covid_btree UNION ALL SELECT 'query_keys', COUNT(*) FROM query_keys UNION ALL SELECT 'insert_keys', COUNT(*) FROM insert_keys;"

# ============================================
# Step 6: 创建测试函数
# ============================================
echo ""
echo "Step 6: 创建工作负载测试函数..."

$PSQL << 'EOF'
-- 删除旧函数
DROP FUNCTION IF EXISTS benchmark_workload_nrindex(INT, INT);
DROP FUNCTION IF EXISTS benchmark_workload_btree(INT, INT);

-- 创建 NRINDEX 表的工作负载测试函数 (直接SQL，无动态开销)
CREATE OR REPLACE FUNCTION benchmark_workload_nrindex(
    p_read_count INT,
    p_write_count INT
)
RETURNS TABLE(
    total_time_ms DOUBLE PRECISION,
    read_ops BIGINT,
    write_ops BIGINT,
    read_time_ms DOUBLE PRECISION,
    write_time_ms DOUBLE PRECISION,
    avg_read_us DOUBLE PRECISION,
    avg_write_us DOUBLE PRECISION
) AS $$
DECLARE
    start_ts TIMESTAMP;
    end_ts TIMESTAMP;
    read_start TIMESTAMP;
    read_end TIMESTAMP;
    write_start TIMESTAMP;
    write_end TIMESTAMP;
    key_val BIGINT;
    result_row RECORD;
    read_cnt BIGINT := 0;
    write_cnt BIGINT := 0;
    next_id INT;
    total_read_time DOUBLE PRECISION := 0;
    total_write_time DOUBLE PRECISION := 0;
BEGIN
    SET enable_seqscan = off;
    SET max_parallel_workers_per_gather = 0;

    SELECT COALESCE(MAX(id), 0) + 1 INTO next_id FROM covid;

    start_ts := clock_timestamp();

    IF p_read_count > 0 THEN
        read_start := clock_timestamp();
        FOR key_val IN SELECT val FROM query_keys ORDER BY id LIMIT p_read_count LOOP
            SELECT * INTO result_row FROM covid WHERE val = key_val LIMIT 1;
            read_cnt := read_cnt + 1;
        END LOOP;
        read_end := clock_timestamp();
        total_read_time := EXTRACT(EPOCH FROM (read_end - read_start)) * 1000;
    END IF;

    IF p_write_count > 0 THEN
        write_start := clock_timestamp();
        FOR key_val IN SELECT val FROM insert_keys ORDER BY id LIMIT p_write_count LOOP
            INSERT INTO covid (id, val) VALUES (next_id, key_val) ON CONFLICT (id) DO NOTHING;
            next_id := next_id + 1;
            write_cnt := write_cnt + 1;
        END LOOP;
        write_end := clock_timestamp();
        total_write_time := EXTRACT(EPOCH FROM (write_end - write_start)) * 1000;
    END IF;

    end_ts := clock_timestamp();

    total_time_ms := EXTRACT(EPOCH FROM (end_ts - start_ts)) * 1000;
    read_ops := read_cnt;
    write_ops := write_cnt;
    read_time_ms := total_read_time;
    write_time_ms := total_write_time;
    avg_read_us := CASE WHEN read_cnt > 0 THEN (total_read_time * 1000) / read_cnt ELSE 0 END;
    avg_write_us := CASE WHEN write_cnt > 0 THEN (total_write_time * 1000) / write_cnt ELSE 0 END;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

-- 创建 BTREE 表的工作负载测试函数 (使用 covid_btree 表)
CREATE OR REPLACE FUNCTION benchmark_workload_btree(
    p_read_count INT,
    p_write_count INT
)
RETURNS TABLE(
    total_time_ms DOUBLE PRECISION,
    read_ops BIGINT,
    write_ops BIGINT,
    read_time_ms DOUBLE PRECISION,
    write_time_ms DOUBLE PRECISION,
    avg_read_us DOUBLE PRECISION,
    avg_write_us DOUBLE PRECISION
) AS $$
DECLARE
    start_ts TIMESTAMP;
    end_ts TIMESTAMP;
    read_start TIMESTAMP;
    read_end TIMESTAMP;
    write_start TIMESTAMP;
    write_end TIMESTAMP;
    key_val BIGINT;
    result_row RECORD;
    read_cnt BIGINT := 0;
    write_cnt BIGINT := 0;
    next_id INT;
    total_read_time DOUBLE PRECISION := 0;
    total_write_time DOUBLE PRECISION := 0;
BEGIN
    SET enable_seqscan = off;
    SET max_parallel_workers_per_gather = 0;

    SELECT COALESCE(MAX(id), 0) + 1 INTO next_id FROM covid_btree;

    start_ts := clock_timestamp();

    IF p_read_count > 0 THEN
        read_start := clock_timestamp();
        FOR key_val IN SELECT val FROM query_keys ORDER BY id LIMIT p_read_count LOOP
            SELECT * INTO result_row FROM covid_btree WHERE val = key_val LIMIT 1;
            read_cnt := read_cnt + 1;
        END LOOP;
        read_end := clock_timestamp();
        total_read_time := EXTRACT(EPOCH FROM (read_end - read_start)) * 1000;
    END IF;

    IF p_write_count > 0 THEN
        write_start := clock_timestamp();
        FOR key_val IN SELECT val FROM insert_keys ORDER BY id LIMIT p_write_count LOOP
            INSERT INTO covid_btree (id, val) VALUES (next_id, key_val) ON CONFLICT (id) DO NOTHING;
            next_id := next_id + 1;
            write_cnt := write_cnt + 1;
        END LOOP;
        write_end := clock_timestamp();
        total_write_time := EXTRACT(EPOCH FROM (write_end - write_start)) * 1000;
    END IF;

    end_ts := clock_timestamp();

    total_time_ms := EXTRACT(EPOCH FROM (end_ts - start_ts)) * 1000;
    read_ops := read_cnt;
    write_ops := write_cnt;
    read_time_ms := total_read_time;
    write_time_ms := total_write_time;
    avg_read_us := CASE WHEN read_cnt > 0 THEN (total_read_time * 1000) / read_cnt ELSE 0 END;
    avg_write_us := CASE WHEN write_cnt > 0 THEN (total_write_time * 1000) / write_cnt ELSE 0 END;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

SELECT '工作负载测试函数创建成功' AS status;
EOF

echo "测试函数创建完成"

# ============================================
# Step 7: 清理旧索引
# ============================================
echo ""
echo "Step 7: 清理旧索引..."
$PSQL -c "DROP INDEX IF EXISTS idx_covid_nrindex;" 2>/dev/null
$PSQL -c "DROP INDEX IF EXISTS idx_covid_btree;" 2>/dev/null
echo "清理完成"

# 初始化结果文件
echo "index_type,round,create_time_ms,total_time_ms,read_ops,write_ops,read_time_ms,write_time_ms,avg_read_us,avg_write_us,throughput_qps" > "$RESULT_CSV"

# ============================================
# 测试函数
# ============================================
run_benchmark() {
    local index_type=$1
    local create_cmd=$2
    local func_name=$3
    local table_name=$4

    echo ""
    echo "=============================================="
    echo "Benchmark: $index_type ($WORKLOAD)"
    echo "=============================================="

    # 重启数据库，确保干净状态
    restart_db

    # 删除索引
    $PSQL -c "DROP INDEX IF EXISTS idx_${table_name};" 2>/dev/null

    # 清理之前插入的数据
    $PSQL -c "DELETE FROM $table_name WHERE id > $DATA_COUNT;" 2>/dev/null

    # 创建索引并计时
    echo "创建 $index_type 索引..."
    create_start=$(date +%s%3N)
    $PSQL -c "$create_cmd" 2>/dev/null
    create_end=$(date +%s%3N)
    create_time_ms=$((create_end - create_start))
    echo "索引创建时间: ${create_time_ms}ms"

    # 预热
    echo "预热中..."
    $PSQL -t -A -c "SET enable_seqscan = off; SELECT * FROM $table_name WHERE val = (SELECT val FROM query_keys LIMIT 1) LIMIT 1;" > /dev/null 2>&1
    echo "预热完成"

    # 多轮测试
    echo ""
    echo "运行 $ROUNDS 轮 $WORKLOAD 测试..."

    for ((i=1; i<=ROUNDS; i++)); do
        echo "--- 第 $i 轮 ---"

        # 清理之前插入的数据
        $PSQL -c "DELETE FROM $table_name WHERE id > $DATA_COUNT;" > /dev/null 2>&1

        # 执行工作负载测试
        result=$($PSQL -t -A -c "SELECT * FROM ${func_name}($READ_COUNT, $WRITE_COUNT);")

        # 解析结果
        total_time_ms=$(echo "$result" | cut -d'|' -f1)
        read_ops=$(echo "$result" | cut -d'|' -f2)
        write_ops=$(echo "$result" | cut -d'|' -f3)
        read_time_ms=$(echo "$result" | cut -d'|' -f4)
        write_time_ms=$(echo "$result" | cut -d'|' -f5)
        avg_read_us=$(echo "$result" | cut -d'|' -f6)
        avg_write_us=$(echo "$result" | cut -d'|' -f7)

        total_ops=$((read_ops + write_ops))
        throughput=$(awk "BEGIN {printf \"%.2f\", $total_ops / ($total_time_ms / 1000.0)}")

        echo "总耗时: ${total_time_ms}ms"
        if [ "$read_ops" -gt 0 ]; then
            echo "  查询: ${read_ops}次, ${read_time_ms}ms, ${avg_read_us}us/次"
        fi
        if [ "$write_ops" -gt 0 ]; then
            echo "  插入: ${write_ops}次, ${write_time_ms}ms, ${avg_write_us}us/次"
        fi
        echo "  吞吐量: ${throughput} OPS"

        # 保存每轮结果
        echo "$index_type,$i,$create_time_ms,$total_time_ms,$read_ops,$write_ops,$read_time_ms,$write_time_ms,$avg_read_us,$avg_write_us,$throughput" >> "$RESULT_CSV"
    done
}

# ============================================
# 运行测试
# ============================================
run_benchmark "NRINDEX" "CREATE INDEX idx_covid ON covid USING nrindex(val);" "benchmark_workload_nrindex" "covid"
run_benchmark "BTREE" "CREATE INDEX idx_covid_btree ON covid_btree USING btree(val);" "benchmark_workload_btree" "covid_btree"

# ============================================
# 结果汇总
# ============================================
echo ""
echo "=============================================="
echo "详细结果"
echo "=============================================="
cat "$RESULT_CSV"

echo ""
echo "=============================================="
echo "汇总统计 - $WORKLOAD (${WORKLOAD_DESC[$WORKLOAD]})"
echo "=============================================="

# 计算平均值
nrindex_avg_total=$(grep "^NRINDEX" "$RESULT_CSV" | awk -F',' '{sum+=$4; count++} END {printf "%.2f", sum/count}')
btree_avg_total=$(grep "^BTREE" "$RESULT_CSV" | awk -F',' '{sum+=$4; count++} END {printf "%.2f", sum/count}')
nrindex_avg_read=$(grep "^NRINDEX" "$RESULT_CSV" | awk -F',' '{sum+=$9; count++} END {printf "%.2f", sum/count}')
btree_avg_read=$(grep "^BTREE" "$RESULT_CSV" | awk -F',' '{sum+=$9; count++} END {printf "%.2f", sum/count}')
nrindex_avg_write=$(grep "^NRINDEX" "$RESULT_CSV" | awk -F',' '{sum+=$10; count++} END {printf "%.2f", sum/count}')
btree_avg_write=$(grep "^BTREE" "$RESULT_CSV" | awk -F',' '{sum+=$10; count++} END {printf "%.2f", sum/count}')
nrindex_avg_qps=$(grep "^NRINDEX" "$RESULT_CSV" | awk -F',' '{sum+=$11; count++} END {printf "%.2f", sum/count}')
btree_avg_qps=$(grep "^BTREE" "$RESULT_CSV" | awk -F',' '{sum+=$11; count++} END {printf "%.2f", sum/count}')
nrindex_create=$(grep "^NRINDEX" "$RESULT_CSV" | head -1 | cut -d',' -f3)
btree_create=$(grep "^BTREE" "$RESULT_CSV" | head -1 | cut -d',' -f3)

echo ""
echo "索引类型    | 创建(ms) | 总耗时(ms) | 查询(us) | 插入(us) | 吞吐量(OPS)"
echo "------------|----------|------------|----------|----------|------------"
printf "NRINDEX     | %8s | %10s | %8s | %8s | %10s\n" "$nrindex_create" "$nrindex_avg_total" "$nrindex_avg_read" "$nrindex_avg_write" "$nrindex_avg_qps"
printf "BTREE       | %8s | %10s | %8s | %8s | %10s\n" "$btree_create" "$btree_avg_total" "$btree_avg_read" "$btree_avg_write" "$btree_avg_qps"

echo ""
echo "=============================================="
echo "性能对比"
echo "=============================================="

if [ -n "$nrindex_avg_qps" ] && [ -n "$btree_avg_qps" ]; then
    qps_ratio=$(awk "BEGIN {printf \"%.2f\", $nrindex_avg_qps / $btree_avg_qps}")
    total_ratio=$(awk "BEGIN {printf \"%.2f\", $btree_avg_total / $nrindex_avg_total}")
    create_ratio=$(awk "BEGIN {printf \"%.2f\", $nrindex_create / $btree_create}")

    echo "NRINDEX/BTREE 吞吐量比值: $qps_ratio"
    echo "BTREE/NRINDEX 总耗时比值: $total_ratio"
    echo "NRINDEX/BTREE 创建时间比值: $create_ratio"

    if [ "$READ_COUNT" -gt 0 ] && [ "$nrindex_avg_read" != "0.00" ]; then
        read_ratio=$(awk "BEGIN {printf \"%.2f\", $btree_avg_read / $nrindex_avg_read}")
        echo "查询性能提升: ${read_ratio}x"
    fi

    if [ "$WRITE_COUNT" -gt 0 ] && [ "$nrindex_avg_write" != "0.00" ]; then
        write_ratio=$(awk "BEGIN {printf \"%.2f\", $btree_avg_write / $nrindex_avg_write}")
        echo "插入性能提升: ${write_ratio}x"
    fi

    nrindex_better=$(awk "BEGIN {print ($nrindex_avg_qps > $btree_avg_qps) ? 1 : 0}")
    if [ "$nrindex_better" = "1" ]; then
        improvement=$(awk "BEGIN {printf \"%.1f\", ($qps_ratio - 1) * 100}")
        echo ""
        echo "结论: NRINDEX 比 BTREE 快 ${improvement}%"
    else
        degradation=$(awk "BEGIN {printf \"%.1f\", (1 - $qps_ratio) * 100}")
        echo ""
        echo "结论: NRINDEX 比 BTREE 慢 ${degradation}%"
    fi
fi

echo ""
echo "=============================================="
echo "测试完成!"
echo "工作负载: $WORKLOAD (${WORKLOAD_DESC[$WORKLOAD]})"
echo "结果保存在: $RESULT_CSV"
echo "=============================================="
