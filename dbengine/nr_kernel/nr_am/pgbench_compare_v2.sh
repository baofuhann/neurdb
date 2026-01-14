#!/bin/bash
# =============================================
# pgbench 对比测试: NRINDEX vs BTREE
# =============================================
# Usage: ./pgbench_compare_v2.sh [query_limit] [threads] [transactions]
# Example:
#   ./pgbench_compare_v2.sh 10000          # 单线程，10000条查询
#   ./pgbench_compare_v2.sh 10000 4        # 4线程并发
#   ./pgbench_compare_v2.sh 10000 4 10     # 4线程，每线程10个事务
#
# 数据来源:
#   主表数据: /hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_bulk_load_keys.csv (10M)

# RL 训练数据文件路径
BULK_LOAD_CSV="/hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_bulk_load_keys.csv"
READ_KEYS_CSV="/hdd9/benjamin/LearnedIndexSelfDesign/src/drl/covid_read_keys.csv"
RESULT_CSV="/tmp/benchmark_results_v2.csv"

# 参数解析
QUERY_LIMIT=${1:-10000}      # 查询数量 (默认 10000)
THREADS=${2:-1}               # 并发线程数 (默认 1)
TRANSACTIONS=${3:-1}          # 每线程事务数 (默认 1)

PSQL="/code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb"
PGBENCH="/code/neurdb-dev/psql/bin/pgbench -h 127.0.0.1 -d neurdb"
ROUNDS=3

# 检查数据文件 (仅在需要导入数据时使用)
# if [ ! -f "$BULK_LOAD_CSV" ]; then
#     echo "错误: 主数据文件不存在: $BULK_LOAD_CSV"
#     exit 1
# fi

echo "=============================================="
echo "NRINDEX vs BTREE 性能对比测试 (pgbench)"
echo "=============================================="
echo "查询数量: $QUERY_LIMIT"
echo "并发线程: $THREADS"
echo "每线程事务数: $TRANSACTIONS"
echo "测试轮数: $ROUNDS"
echo "=============================================="

# ============================================
# Step 1: 准备数据表
# ============================================
echo ""
echo "Step 1: 准备数据表..."

# 创建临时 CSV 文件 (添加 id 列)
TEMP_DATA_CSV="/tmp/covid_rl_data.csv"
echo "生成带 id 列的数据文件..."
echo "id,val" > "$TEMP_DATA_CSV"
tail -n +2 "$BULK_LOAD_CSV" | awk '{printf "%d,%s\n", NR, $0}' >> "$TEMP_DATA_CSV"
DATA_COUNT=$(($(wc -l < "$TEMP_DATA_CSV") - 1))
echo "数据行数: $DATA_COUNT"

# # 导入数据到 PostgreSQL
# echo "导入数据到 PostgreSQL..."
# $PSQL << EOF
# DROP TABLE IF EXISTS covid CASCADE;
# CREATE TABLE covid (id INT PRIMARY KEY, val BIGINT);
# \copy covid FROM '$TEMP_DATA_CSV' CSV HEADER;
# SELECT COUNT(*) AS row_count FROM covid;
# EOF

echo "数据导入完成"

# ============================================
# Step 2: 生成查询 SQL 文件
# ============================================
echo ""
echo "Step 2: 生成查询 SQL 文件..."

QUERY_SQL="/tmp/pgbench_rl_query.sql"

cat > "$QUERY_SQL" << 'EOF'
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;
EOF

# 从数据库中随机抽取 QUERY_LIMIT 个 val 值作为查询键
echo "从 covid 表中随机抽取 $QUERY_LIMIT 个键..."
$PSQL -t -A -c "SELECT val FROM covid ORDER BY RANDOM() LIMIT $QUERY_LIMIT;" 2>/dev/null | while read val; do
    if [ -n "$val" ]; then
        echo "SELECT * FROM covid WHERE val = $val;"
    fi
done >> "$QUERY_SQL"

QUERY_COUNT=$(($(wc -l < "$QUERY_SQL") - 2))
echo "生成完成: $QUERY_COUNT 条查询"


# ============================================
# Step 3: 清理旧索引
# ============================================
echo ""
echo "Step 3: 清理旧索引..."
$PSQL -c "DROP INDEX IF EXISTS idx_covid_nrindex;" 2>/dev/null
$PSQL -c "DROP INDEX IF EXISTS idx_covid_btree;" 2>/dev/null
echo "清理完成"

# 初始化结果文件
echo "index_type,round,create_time_ms,latency_ms,throughput_qps" > "$RESULT_CSV"

# ============================================
# 测试函数
# ============================================
run_benchmark() {
    local index_type=$1
    local create_cmd=$2

    echo ""
    echo "=============================================="
    echo "Benchmark: $index_type"
    echo "=============================================="

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

    # 多轮测试
    echo ""
    echo "运行 $ROUNDS 轮 pgbench 测试..."

    # 总查询数 = 每事务查询数 * 线程数 * 每线程事务数
    total_queries=$((QUERY_COUNT * THREADS * TRANSACTIONS))

    for ((i=1; i<=ROUNDS; i++)); do
        echo "--- 第 $i 轮 (${THREADS}线程 x ${TRANSACTIONS}事务) ---"

        round_start=$(date +%s%3N)
        result=$($PGBENCH -n -f "$QUERY_SQL" -c $THREADS -t $TRANSACTIONS 2>/dev/null)
        round_end=$(date +%s%3N)

        round_time_ms=$((round_end - round_start))
        throughput=$(awk "BEGIN {printf \"%.2f\", $total_queries / ($round_time_ms / 1000.0)}")

        echo "耗时: ${round_time_ms}ms, 总查询: ${total_queries}, 吞吐量: ${throughput} QPS"

        # 保存每轮结果
        echo "$index_type,$i,$create_time_ms,$round_time_ms,$throughput" >> "$RESULT_CSV"
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
nrindex_avg_latency=$(grep "^NRINDEX" "$RESULT_CSV" | awk -F',' '{sum+=$4; count++} END {printf "%.2f", sum/count}')
btree_avg_latency=$(grep "^BTREE" "$RESULT_CSV" | awk -F',' '{sum+=$4; count++} END {printf "%.2f", sum/count}')
nrindex_avg_qps=$(grep "^NRINDEX" "$RESULT_CSV" | awk -F',' '{sum+=$5; count++} END {printf "%.2f", sum/count}')
btree_avg_qps=$(grep "^BTREE" "$RESULT_CSV" | awk -F',' '{sum+=$5; count++} END {printf "%.2f", sum/count}')
nrindex_create=$(grep "^NRINDEX" "$RESULT_CSV" | head -1 | cut -d',' -f3)
btree_create=$(grep "^BTREE" "$RESULT_CSV" | head -1 | cut -d',' -f3)

echo ""
echo "索引类型    | 创建时间(ms) | 平均延迟(ms) | 平均吞吐量(QPS)"
echo "------------|--------------|--------------|----------------"
printf "NRINDEX     | %12s | %12s | %14s\n" "$nrindex_create" "$nrindex_avg_latency" "$nrindex_avg_qps"
printf "BTREE       | %12s | %12s | %14s\n" "$btree_create" "$btree_avg_latency" "$btree_avg_qps"

echo ""
echo "=============================================="
echo "性能对比"
echo "=============================================="

if [ -n "$nrindex_avg_qps" ] && [ -n "$btree_avg_qps" ]; then
    qps_ratio=$(awk "BEGIN {printf \"%.2f\", $nrindex_avg_qps / $btree_avg_qps}")
    latency_ratio=$(awk "BEGIN {printf \"%.2f\", $btree_avg_latency / $nrindex_avg_latency}")
    create_ratio=$(awk "BEGIN {printf \"%.2f\", $btree_create / $nrindex_create}")

    echo "NRINDEX/BTREE 吞吐量比值: $qps_ratio"
    echo "BTREE/NRINDEX 延迟比值: $latency_ratio"
    echo "BTREE/NRINDEX 创建时间比值: $create_ratio"

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
rm -f "$TEMP_DATA_CSV" "$QUERY_SQL"

echo ""
echo "=============================================="
echo "测试完成!"
echo "结果保存在: $RESULT_CSV"
echo "=============================================="
