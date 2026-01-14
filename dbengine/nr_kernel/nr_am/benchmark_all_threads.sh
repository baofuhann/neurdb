#!/bin/bash
# =============================================
# 全面并发测试: 1-64 线程
# =============================================

QUERIES_PER_THREAD=25000
PSQL="/code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb"
RESULT_FILE="/tmp/concurrent_benchmark_results.csv"

# 创建结果表
$PSQL -c "DROP TABLE IF EXISTS concurrent_test_results; CREATE TABLE concurrent_test_results (thread_id INT, index_type TEXT, elapsed_ms NUMERIC, query_count INT);" 2>/dev/null

# 初始化CSV
echo "threads,index_type,total_queries,db_elapsed_ms,db_qps,db_latency_us,shell_elapsed_ms,shell_qps" > "$RESULT_FILE"

run_single_test() {
    local threads=$1
    local index_type=$2
    local table=$3

    # 清空结果表
    $PSQL -c "DELETE FROM concurrent_test_results WHERE index_type = '$index_type';" 2>/dev/null

    # 预热
    $PSQL -t -c "
        SET enable_seqscan = off;
        SET max_parallel_workers_per_gather = 0;
        DO \$\$
        DECLARE k BIGINT; r RECORD;
        BEGIN
            FOR k IN SELECT val FROM query_keys LIMIT 1000 LOOP
                SELECT * INTO r FROM $table WHERE val = k LIMIT 1;
            END LOOP;
        END \$\$;
    " 2>/dev/null

    shell_start=$(date +%s%3N)

    # 并行启动
    for i in $(seq 1 $threads); do
        $PSQL -t -c "
            SET enable_seqscan = off;
            SET max_parallel_workers_per_gather = 0;
            DO \$\$
            DECLARE
                k BIGINT; r RECORD; cnt INT := 0;
                t1 TIMESTAMP; t2 TIMESTAMP; elapsed_ms NUMERIC;
            BEGIN
                t1 := clock_timestamp();
                FOR k IN SELECT val FROM query_keys LIMIT $QUERIES_PER_THREAD LOOP
                    SELECT * INTO r FROM $table WHERE val = k LIMIT 1;
                    cnt := cnt + 1;
                END LOOP;
                t2 := clock_timestamp();
                elapsed_ms := EXTRACT(EPOCH FROM (t2 - t1)) * 1000;
                INSERT INTO concurrent_test_results VALUES ($i, '$index_type', elapsed_ms, cnt);
            END \$\$;
        " 2>/dev/null &
    done

    wait

    shell_end=$(date +%s%3N)
    shell_elapsed=$((shell_end - shell_start))

    # 获取汇总
    result=$($PSQL -t -A -F',' -c "
        SELECT
            SUM(query_count),
            ROUND(AVG(elapsed_ms), 2)
        FROM concurrent_test_results
        WHERE index_type = '$index_type';
    ")

    total_queries=$(echo $result | cut -d',' -f1)
    avg_elapsed=$(echo $result | cut -d',' -f2)

    db_qps=$(awk "BEGIN {printf \"%.0f\", $QUERIES_PER_THREAD / ($avg_elapsed / 1000.0)}")
    db_latency=$(awk "BEGIN {printf \"%.2f\", $avg_elapsed * 1000 / $QUERIES_PER_THREAD}")
    shell_qps=$(awk "BEGIN {printf \"%.0f\", $total_queries / ($shell_elapsed / 1000.0)}")

    echo "$threads,$index_type,$total_queries,$avg_elapsed,$db_qps,$db_latency,$shell_elapsed,$shell_qps" >> "$RESULT_FILE"

    echo "  $index_type: DB=$db_qps QPS, Shell=$shell_qps QPS (${shell_elapsed}ms)"
}

echo "=============================================="
echo "NRINDEX vs BTREE 并发测试 (1-64线程)"
echo "每线程查询数: $QUERIES_PER_THREAD"
echo "=============================================="
echo ""

# 测试不同线程数
for threads in 1 2 4 8 16 32 64; do
    echo "--- $threads 线程 ---"
    run_single_test $threads "NRINDEX" "covid_nrindex"
    run_single_test $threads "BTREE" "covid_btree"
    echo ""
done

# 输出结果表
echo "=============================================="
echo "汇总结果"
echo "=============================================="
echo ""
cat "$RESULT_FILE"

echo ""
echo "=============================================="
echo "格式化输出"
echo "=============================================="
echo ""
printf "%-8s | %-20s | %-20s | %-10s\n" "线程数" "NRINDEX (QPS)" "BTREE (QPS)" "比值"
printf "%-8s-+-%-20s-+-%-20s-+-%-10s\n" "--------" "--------------------" "--------------------" "----------"

for threads in 1 2 4 8 16 32 64; do
    nr_qps=$(grep "^$threads,NRINDEX" "$RESULT_FILE" | cut -d',' -f8)
    bt_qps=$(grep "^$threads,BTREE" "$RESULT_FILE" | cut -d',' -f8)
    if [ -n "$nr_qps" ] && [ -n "$bt_qps" ] && [ "$bt_qps" != "0" ]; then
        ratio=$(awk "BEGIN {printf \"%.2f\", $nr_qps / $bt_qps}")
        printf "%-8s | %-20s | %-20s | %-10s\n" "$threads" "$nr_qps" "$bt_qps" "$ratio"
    fi
done

# 清理
$PSQL -c "DROP TABLE IF EXISTS concurrent_test_results;" 2>/dev/null

echo ""
echo "结果已保存到: $RESULT_FILE"
echo "测试完成!"
