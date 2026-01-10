#!/bin/bash
# =============================================
# pgbench 对比测试: NRINDEX vs BTREE
# 使用 pgbench_data.sh 生成的数据文件
# =============================================
# Usage: ./pgbench_compare_v1.sh <data_size> <query_size>
# Example: ./pgbench_compare_v1.sh 1000000 100000
#
# 依赖文件 (由 pgbench_data.sh 生成):
#   /tmp/covid_<data_size>.csv       - 主数据文件
#   /tmp/covid_query_<query_size>.csv - 查询键文件

# 检查参数
if [ $# -lt 2 ]; then
    echo "Usage: $0 <data_size> <query_size>"
    echo "Example: $0 1000000 100000"
    echo ""
    echo "请先运行 pgbench_data.sh 生成数据文件:"
    echo "  ./pgbench_data.sh 1000000 100000"
    exit 1
fi

DATA_SIZE=$1
QUERY_SIZE=$2

DATA_CSV="/tmp/covid_${DATA_SIZE}.csv"
QUERY_CSV="/tmp/covid_query_${QUERY_SIZE}.csv"
RESULT_CSV="/tmp/benchmark_results.csv"

PSQL="/code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb"
PGBENCH="/code/neurdb-dev/psql/bin/pgbench -h 127.0.0.1 -d neurdb"
ROUNDS=3

# 检查数据文件是否存在
if [ ! -f "$DATA_CSV" ]; then
    echo "错误: 主数据文件不存在: $DATA_CSV"
    echo "请先运行: ./pgbench_data.sh $DATA_SIZE $QUERY_SIZE"
    exit 1
fi

if [ ! -f "$QUERY_CSV" ]; then
    echo "错误: 查询键文件不存在: $QUERY_CSV"
    echo "请先运行: ./pgbench_data.sh $DATA_SIZE $QUERY_SIZE"
    exit 1
fi

echo "=============================================="
echo "NRINDEX vs BTREE 性能对比测试 (pgbench)"
echo "=============================================="
echo "主数据文件: $DATA_CSV ($DATA_SIZE 行)"
echo "查询键文件: $QUERY_CSV ($QUERY_SIZE 行)"
echo "测试轮数: $ROUNDS"
echo "=============================================="

# ============================================
# Step 1: 导入数据到数据库
# ============================================
echo ""
echo "Step 1: 导入数据到数据库..."

$PSQL << EOF
DROP TABLE IF EXISTS covid CASCADE;
CREATE TABLE covid (id INT PRIMARY KEY, val BIGINT);
\copy covid FROM '$DATA_CSV' CSV HEADER;
SELECT COUNT(*) AS row_count FROM covid;
EOF

echo "数据导入完成"

# ============================================
# Step 2: 从查询键文件生成 SQL
# ============================================
echo ""
echo "Step 2: 生成查询 SQL 文件..."

# 跳过 CSV 头部，提取 val 列生成查询
cat > /tmp/pgbench_with_index.sql << 'EOF'
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;
EOF

tail -n +2 "$QUERY_CSV" | cut -d',' -f2 | while read val; do
    echo "SELECT * FROM covid WHERE val = $val;"
done >> /tmp/pgbench_with_index.sql

QUERY_COUNT=$(($(wc -l < /tmp/pgbench_with_index.sql) - 2))
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
echo "index_type,create_time_ms,avg_latency_ms,throughput_qps" > "$RESULT_CSV"

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

    total_latency=0

    for ((i=1; i<=ROUNDS; i++)); do
        echo "--- 第 $i 轮 ---"
        result=$($PGBENCH -n -f /tmp/pgbench_with_index.sql -c 1 -t 1 2>/dev/null)
        echo "$result"

        # 提取平均延迟
        latency=$(echo "$result" | grep "latency average" | awk '{print $4}')

        if [ -n "$latency" ]; then
            total_latency=$(awk "BEGIN {print $total_latency + $latency}")
        fi
    done

    # 计算平均值
    avg_latency=$(awk "BEGIN {printf \"%.3f\", $total_latency / $ROUNDS}")
    throughput=$(awk "BEGIN {printf \"%.2f\", $QUERY_COUNT / ($avg_latency / 1000)}")

    echo ""
    echo "[$index_type 汇总]"
    echo "  索引创建时间: ${create_time_ms}ms"
    echo "  平均延迟: ${avg_latency}ms"
    echo "  吞吐量: ${throughput} QPS"

    # 保存结果
    echo "$index_type,$create_time_ms,$avg_latency,$throughput" >> "$RESULT_CSV"
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
echo "最终结果对比"
echo "=============================================="
echo ""
cat "$RESULT_CSV"

echo ""
echo "=============================================="

# 读取结果计算比较
nrindex_latency=$(grep "NRINDEX" "$RESULT_CSV" | cut -d',' -f3)
btree_latency=$(grep "BTREE" "$RESULT_CSV" | cut -d',' -f3)
nrindex_qps=$(grep "NRINDEX" "$RESULT_CSV" | cut -d',' -f4)
btree_qps=$(grep "BTREE" "$RESULT_CSV" | cut -d',' -f4)
nrindex_create=$(grep "NRINDEX" "$RESULT_CSV" | cut -d',' -f2)
btree_create=$(grep "BTREE" "$RESULT_CSV" | cut -d',' -f2)

echo ""
echo "性能对比:"
echo "  NRINDEX: 构造=${nrindex_create}ms, 延迟=${nrindex_latency}ms, 吞吐量=${nrindex_qps} QPS"
echo "  BTREE:   构造=${btree_create}ms, 延迟=${btree_latency}ms, 吞吐量=${btree_qps} QPS"

if [ -n "$nrindex_qps" ] && [ -n "$btree_qps" ]; then
    ratio=$(awk "BEGIN {printf \"%.2f\", $nrindex_qps / $btree_qps}")
    echo ""
    echo "  NRINDEX/BTREE 吞吐量比值: $ratio"
fi

if [ -n "$nrindex_create" ] && [ -n "$btree_create" ]; then
    create_ratio=$(awk "BEGIN {printf \"%.2f\", $btree_create / $nrindex_create}")
    echo "  BTREE/NRINDEX 构造时间比值: $create_ratio"
fi

# 清理临时文件
rm -f /tmp/pgbench_with_index.sql

echo ""
echo "=============================================="
echo "测试完成!"
echo "结果保存在: $RESULT_CSV"
echo "=============================================="
