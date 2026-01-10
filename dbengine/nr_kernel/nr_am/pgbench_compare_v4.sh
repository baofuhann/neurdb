#!/bin/bash
# =============================================
# SQL 对比测试: NRINDEX vs BTREE
# 使用单点查询，更准确测量索引性能
# =============================================
# Usage: ./pgbench_compare_v4.sh [query_limit]
# Example: ./pgbench_compare_v4.sh 500000

# RL 训练数据文件路径
BULK_LOAD_CSV="/hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_bulk_load_keys.csv"
READ_KEYS_CSV="/hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_read_keys.csv"
RESULT_CSV="/tmp/benchmark_results_v4.csv"

# 查询数量限制 (0 表示不限制)
QUERY_LIMIT=${1:-0}

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

# 检查数据文件
if [ ! -f "$BULK_LOAD_CSV" ]; then
    echo "错误: 主数据文件不存在: $BULK_LOAD_CSV"
    exit 1
fi

if [ ! -f "$READ_KEYS_CSV" ]; then
    echo "错误: 查询键文件不存在: $READ_KEYS_CSV"
    exit 1
fi

echo "=============================================="
echo "NRINDEX vs BTREE 性能对比测试 (单点查询)"
echo "=============================================="
echo "主数据文件: $BULK_LOAD_CSV"
echo "查询键文件: $READ_KEYS_CSV"
if [ "$QUERY_LIMIT" -eq 0 ]; then
    echo "查询数量限制: 无限制 (使用全部)"
else
    echo "查询数量限制: $QUERY_LIMIT"
fi
echo "测试轮数: $ROUNDS"
echo "=============================================="

# ============================================
# Step 1: 重启数据库，确保干净状态
# ============================================
echo ""
echo "Step 1: 重启数据库确保干净状态..."
restart_db

# ============================================
# Step 2: 准备主数据表 (如果不存在)
# ============================================
echo ""
echo "Step 2: 准备主数据表..."

TABLE_EXISTS=$($PSQL -t -A -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = 'covid';")

if [ "$TABLE_EXISTS" -eq 0 ]; then
    TEMP_DATA_CSV="/tmp/covid_rl_data.csv"
    echo "生成带 id 列的数据文件..."
    echo "id,val" > "$TEMP_DATA_CSV"
    tail -n +2 "$BULK_LOAD_CSV" | awk '{printf "%d,%s\n", NR, $0}' >> "$TEMP_DATA_CSV"
    DATA_COUNT=$(($(wc -l < "$TEMP_DATA_CSV") - 1))
    echo "数据行数: $DATA_COUNT"

    echo "导入数据到 PostgreSQL..."
    $PSQL << EOF
CREATE TABLE covid (id INT PRIMARY KEY, val BIGINT);
\copy covid FROM '$TEMP_DATA_CSV' CSV HEADER;
SELECT COUNT(*) AS row_count FROM covid;
EOF
    rm -f "$TEMP_DATA_CSV"
    echo "数据导入完成"
else
    DATA_COUNT=$($PSQL -t -A -c "SELECT COUNT(*) FROM covid;")
    echo "主数据表已存在，跳过创建 (行数: $DATA_COUNT)"
fi

# ============================================
# Step 3: 准备查询键表 (如果不存在)
# ============================================
echo ""
echo "Step 3: 准备查询键表..."

KEYS_TABLE_EXISTS=$($PSQL -t -A -c "SELECT COUNT(*) FROM information_schema.columns WHERE table_name = 'query_keys' AND column_name = 'id';")

if [ "$KEYS_TABLE_EXISTS" -eq 0 ]; then
    # 删除旧表（如果存在但结构不对）
    $PSQL -c "DROP TABLE IF EXISTS query_keys CASCADE;" > /dev/null 2>&1

    TEMP_KEYS_CSV="/tmp/covid_query_keys.csv"
    echo "val" > "$TEMP_KEYS_CSV"
    if [ "$QUERY_LIMIT" -eq 0 ]; then
        tail -n +2 "$READ_KEYS_CSV" >> "$TEMP_KEYS_CSV"
    else
        tail -n +2 "$READ_KEYS_CSV" | head -n $QUERY_LIMIT >> "$TEMP_KEYS_CSV"
    fi
    QUERY_COUNT=$(($(wc -l < "$TEMP_KEYS_CSV") - 1))
    echo "查询键数量: $QUERY_COUNT"

    echo "导入查询键到 PostgreSQL..."
    $PSQL << EOF
CREATE TABLE query_keys (id SERIAL PRIMARY KEY, val BIGINT);
\copy query_keys(val) FROM '$TEMP_KEYS_CSV' CSV HEADER;
SELECT COUNT(*) AS key_count FROM query_keys;
EOF
    rm -f "$TEMP_KEYS_CSV"
    echo "查询键导入完成"
else
    QUERY_COUNT=$($PSQL -t -A -c "SELECT COUNT(*) FROM query_keys;")
    echo "查询键表已存在，跳过创建 (行数: $QUERY_COUNT)"
fi

# ============================================
# Step 4: 创建单点查询测试函数
# ============================================
echo ""
echo "Step 4: 创建单点查询测试函数..."

$PSQL << 'EOF'
-- 删除旧函数（避免重复）
DROP FUNCTION IF EXISTS benchmark_point_queries();
DROP FUNCTION IF EXISTS benchmark_point_queries(INT);

-- 创建单点查询测试函数
CREATE OR REPLACE FUNCTION benchmark_point_queries()
RETURNS TABLE(total_time_ms DOUBLE PRECISION, query_count BIGINT, avg_time_us DOUBLE PRECISION) AS $$
DECLARE
    start_ts TIMESTAMP;
    end_ts TIMESTAMP;
    key_val BIGINT;
    result_row RECORD;
    cnt BIGINT := 0;
BEGIN
    -- 强制使用索引
    SET enable_seqscan = off;
    SET max_parallel_workers_per_gather = 0;

    start_ts := clock_timestamp();

    -- 遍历查询键，执行单点查询
    FOR key_val IN SELECT val FROM query_keys ORDER BY id LOOP
        SELECT * INTO result_row FROM covid WHERE val = key_val LIMIT 1;
        cnt := cnt + 1;
    END LOOP;

    end_ts := clock_timestamp();

    total_time_ms := EXTRACT(EPOCH FROM (end_ts - start_ts)) * 1000;
    query_count := cnt;
    avg_time_us := (total_time_ms * 1000) / cnt;

    RETURN NEXT;
END;
$$ LANGUAGE plpgsql;

SELECT 'benchmark_point_queries 函数创建成功' AS status;
EOF

echo "测试函数创建完成"

# ============================================
# Step 5: 清理旧索引
# ============================================
echo ""
echo "Step 5: 清理旧索引..."
$PSQL -c "DROP INDEX IF EXISTS idx_covid_nrindex;" 2>/dev/null
$PSQL -c "DROP INDEX IF EXISTS idx_covid_btree;" 2>/dev/null
echo "清理完成"

# 初始化结果文件
echo "index_type,round,create_time_ms,query_time_ms,query_count,avg_time_us,throughput_qps" > "$RESULT_CSV"

# ============================================
# 测试函数
# ============================================
run_benchmark() {
    local index_type=$1
    local create_cmd=$2

    echo ""
    echo "=============================================="
    echo "Benchmark: $index_type (单点查询)"
    echo "=============================================="

    # 重启数据库，确保干净状态
    restart_db

    # 删除所有索引
    $PSQL -c "DROP INDEX IF EXISTS idx_covid_nrindex;" 2>/dev/null
    $PSQL -c "DROP INDEX IF EXISTS idx_covid_btree;" 2>/dev/null

    # 创建索引并计时
    echo "创建 $index_type 索引..."
    create_start=$(date +%s%3N)
    $PSQL -c "$create_cmd" 2>/dev/null
    create_end=$(date +%s%3N)
    create_time_ms=$((create_end - create_start))
    echo "索引创建时间: ${create_time_ms}ms"

    # 预热
    echo "预热中..."
    $PSQL -t -A -c "SELECT * FROM benchmark_point_queries() LIMIT 0;" > /dev/null 2>&1
    # 执行少量查询预热
    $PSQL -t -A << EOF > /dev/null 2>&1
SET enable_seqscan = off;
SELECT * FROM covid WHERE val = (SELECT val FROM query_keys LIMIT 1);
EOF
    echo "预热完成"

    # 多轮测试
    echo ""
    echo "运行 $ROUNDS 轮单点查询测试..."

    for ((i=1; i<=ROUNDS; i++)); do
        echo "--- 第 $i 轮 ---"

        # 执行单点查询测试
        result=$($PSQL -t -A -c "SELECT * FROM benchmark_point_queries();")

        # 解析结果: total_time_ms|query_count|avg_time_us
        query_time_ms=$(echo "$result" | cut -d'|' -f1)
        query_count=$(echo "$result" | cut -d'|' -f2)
        avg_time_us=$(echo "$result" | cut -d'|' -f3)

        throughput=$(awk "BEGIN {printf \"%.2f\", $query_count / ($query_time_ms / 1000.0)}")

        echo "总耗时: ${query_time_ms}ms, 查询数: ${query_count}, 平均: ${avg_time_us}us/查询, 吞吐量: ${throughput} QPS"

        # 保存每轮结果
        echo "$index_type,$i,$create_time_ms,$query_time_ms,$query_count,$avg_time_us,$throughput" >> "$RESULT_CSV"
    done
}

# ============================================
# 运行测试
# ============================================
run_benchmark "NRINDEX" "CREATE INDEX idx_covid_nrindex ON covid USING nrindex(val);"
run_benchmark "BTREE" "CREATE INDEX idx_covid_btree ON covid USING btree(val);"

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
echo "汇总统计"
echo "=============================================="

# 计算平均值
nrindex_avg_time=$(grep "^NRINDEX" "$RESULT_CSV" | awk -F',' '{sum+=$4; count++} END {printf "%.2f", sum/count}')
btree_avg_time=$(grep "^BTREE" "$RESULT_CSV" | awk -F',' '{sum+=$4; count++} END {printf "%.2f", sum/count}')
nrindex_avg_us=$(grep "^NRINDEX" "$RESULT_CSV" | awk -F',' '{sum+=$6; count++} END {printf "%.2f", sum/count}')
btree_avg_us=$(grep "^BTREE" "$RESULT_CSV" | awk -F',' '{sum+=$6; count++} END {printf "%.2f", sum/count}')
nrindex_avg_qps=$(grep "^NRINDEX" "$RESULT_CSV" | awk -F',' '{sum+=$7; count++} END {printf "%.2f", sum/count}')
btree_avg_qps=$(grep "^BTREE" "$RESULT_CSV" | awk -F',' '{sum+=$7; count++} END {printf "%.2f", sum/count}')
nrindex_create=$(grep "^NRINDEX" "$RESULT_CSV" | head -1 | cut -d',' -f3)
btree_create=$(grep "^BTREE" "$RESULT_CSV" | head -1 | cut -d',' -f3)

echo ""
echo "索引类型    | 创建时间(ms) | 总耗时(ms) | 平均(us/查询) | 吞吐量(QPS)"
echo "------------|--------------|------------|---------------|------------"
printf "NRINDEX     | %12s | %10s | %13s | %10s\n" "$nrindex_create" "$nrindex_avg_time" "$nrindex_avg_us" "$nrindex_avg_qps"
printf "BTREE       | %12s | %10s | %13s | %10s\n" "$btree_create" "$btree_avg_time" "$btree_avg_us" "$btree_avg_qps"

echo ""
echo "=============================================="
echo "性能对比"
echo "=============================================="

if [ -n "$nrindex_avg_qps" ] && [ -n "$btree_avg_qps" ]; then
    qps_ratio=$(awk "BEGIN {printf \"%.2f\", $nrindex_avg_qps / $btree_avg_qps}")
    latency_ratio=$(awk "BEGIN {printf \"%.2f\", $nrindex_avg_us / $btree_avg_us}")
    create_ratio=$(awk "BEGIN {printf \"%.2f\", $nrindex_create / $btree_create}")

    echo "NRINDEX/BTREE 吞吐量比值: $qps_ratio"
    echo "NRINDEX/BTREE 延迟比值: $latency_ratio"
    echo "NRINDEX/BTREE 创建时间比值: $create_ratio"

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

# 清理临时文件
rm -f "$TEMP_DATA_CSV" "$TEMP_KEYS_CSV"

echo ""
echo "=============================================="
echo "测试完成!"
echo "结果保存在: $RESULT_CSV"
echo "=============================================="
