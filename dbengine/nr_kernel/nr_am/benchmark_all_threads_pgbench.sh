#!/bin/bash
# =============================================
# 全面并发测试: 1-64 线程 (pgbench 版本)
# 纯点查询: SELECT * FROM table WHERE val = ? LIMIT 1
# =============================================

QUERIES_PER_THREAD=25000
PSQL="/code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb"
PGBENCH="/code/neurdb-dev/psql/bin/pgbench -h 127.0.0.1 -d neurdb"
RESULT_FILE="/tmp/pgbench_benchmark_results.csv"

# 初始化CSV
echo "threads,index_type,total_queries,tps,latency_avg_ms,latency_stddev_ms" > "$RESULT_FILE"

# =============================================
# Step 1: 准备查询键索引表
# =============================================
prepare_keys() {
    echo "准备查询键索引表..."

    $PSQL << 'EOF' 2>/dev/null
DROP TABLE IF EXISTS qk_idx;
CREATE UNLOGGED TABLE qk_idx (id INT PRIMARY KEY, val BIGINT);
INSERT INTO qk_idx SELECT ROW_NUMBER() OVER ()::INT, val FROM query_keys;
ANALYZE qk_idx;
EOF

    KEY_COUNT=$($PSQL -t -A -c "SELECT COUNT(*) FROM qk_idx;")
    echo "查询键数量: $KEY_COUNT"

    # NRINDEX 点查询
    cat > /tmp/pgbench_nrindex.sql << EOF
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;
\set kid random(1, $KEY_COUNT)
SELECT * FROM covid_nrindex WHERE val = (SELECT val FROM qk_idx WHERE id = :kid) LIMIT 1;
EOF

    # BTREE 点查询
    cat > /tmp/pgbench_btree.sql << EOF
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;
\set kid random(1, $KEY_COUNT)
SELECT * FROM covid_btree WHERE val = (SELECT val FROM qk_idx WHERE id = :kid) LIMIT 1;
EOF

    echo "SQL 文件生成完成"
}

# =============================================
# 测试函数
# =============================================
run_single_test() {
    local threads=$1
    local index_type=$2
    local sql_file=$3

    # 预热
    $PGBENCH -n -f "$sql_file" -c 1 -t 500 > /dev/null 2>&1

    # 运行测试
    result=$($PGBENCH -n -r -f "$sql_file" -c $threads -t $QUERIES_PER_THREAD 2>&1)

    # 解析 TPS
    tps=$(echo "$result" | grep -oP 'tps = \K[0-9.]+' | head -1)
    latency_avg=$(echo "$result" | grep -oP 'latency average = \K[0-9.]+')
    latency_stddev=$(echo "$result" | grep -oP 'latency stddev = \K[0-9.]+')

    [ -z "$tps" ] && tps="0"
    [ -z "$latency_avg" ] && latency_avg="0"
    [ -z "$latency_stddev" ] && latency_stddev="0"

    total_txn=$((QUERIES_PER_THREAD * threads))
    echo "$threads,$index_type,$total_txn,$tps,$latency_avg,$latency_stddev" >> "$RESULT_FILE"

    printf "  %-8s: TPS=%-12s Latency=%-8s ms\n" "$index_type" "$tps" "$latency_avg"
}

# =============================================
# 主流程
# =============================================
echo "=============================================="
echo "NRINDEX vs BTREE 并发测试 (pgbench 版本)"
echo "=============================================="
echo "每线程事务数: $QUERIES_PER_THREAD"
echo "测试线程数: 1, 2, 4, 8, 16, 32, 64"
echo "=============================================="
echo ""

# 检查索引
NRINDEX_EXISTS=$($PSQL -t -A -c "SELECT COUNT(*) FROM pg_indexes WHERE indexname = 'idx_nrindex';")
BTREE_EXISTS=$($PSQL -t -A -c "SELECT COUNT(*) FROM pg_indexes WHERE indexname = 'idx_btree';")

if [ "$NRINDEX_EXISTS" -eq 0 ] || [ "$BTREE_EXISTS" -eq 0 ]; then
    echo "错误: 索引不存在"
    exit 1
fi

prepare_keys

echo ""
echo "开始测试..."
echo ""

for threads in 1 2 4 8 16 32 64; do
    echo "--- $threads 线程 ---"
    run_single_test $threads "NRINDEX" "/tmp/pgbench_nrindex.sql"
    run_single_test $threads "BTREE" "/tmp/pgbench_btree.sql"
    echo ""
done

# =============================================
# 输出结果
# =============================================
echo "=============================================="
echo "CSV 结果"
echo "=============================================="
cat "$RESULT_FILE"

echo ""
echo "=============================================="
echo "格式化输出"
echo "=============================================="
echo ""
printf "%-8s | %-15s | %-15s | %-15s\n" "线程数" "NRINDEX (TPS)" "BTREE (TPS)" "NRINDEX提升"
printf "%-8s-+-%-15s-+-%-15s-+-%-15s\n" "--------" "---------------" "---------------" "---------------"

for threads in 1 2 4 8 16 32 64; do
    nr_tps=$(grep "^$threads,NRINDEX" "$RESULT_FILE" | cut -d',' -f4)
    bt_tps=$(grep "^$threads,BTREE" "$RESULT_FILE" | cut -d',' -f4)
    if [ -n "$nr_tps" ] && [ -n "$bt_tps" ]; then
        speedup=$(awk "BEGIN {if ($bt_tps > 0) printf \"%.2fx\", $nr_tps / $bt_tps; else print \"N/A\"}")
        printf "%-8s | %-15.0f | %-15.0f | %-15s\n" "$threads" "$nr_tps" "$bt_tps" "$speedup"
    fi
done

# 清理
rm -f /tmp/pgbench_nrindex.sql /tmp/pgbench_btree.sql
$PSQL -c "DROP TABLE IF EXISTS qk_idx;" 2>/dev/null

echo ""
echo "结果已保存到: $RESULT_FILE"
echo "测试完成!"
