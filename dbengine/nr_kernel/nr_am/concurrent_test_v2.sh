#!/bin/bash
# =============================================
# 并发测试脚本 v2: NRINDEX vs BTREE
# 使用数据库内部计时，结果更准确
# =============================================
# Usage: ./concurrent_test_v2.sh [threads] [queries_per_thread] [index_type]
# Example:
#   ./concurrent_test_v2.sh 4 25000 both

THREADS=${1:-4}
QUERIES_PER_THREAD=${2:-25000}
INDEX_TYPE=${3:-both}

PSQL="/code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb"

# 创建结果表
$PSQL -c "DROP TABLE IF EXISTS concurrent_test_results; CREATE TABLE concurrent_test_results (thread_id INT, index_type TEXT, elapsed_ms NUMERIC, query_count INT);" 2>/dev/null

run_test() {
    local index_type=$1
    local table=$2

    echo ""
    echo "=============================================="
    echo "测试: $index_type ($THREADS 线程, 每线程 $QUERIES_PER_THREAD 查询)"
    echo "=============================================="

    # 清空结果表
    $PSQL -c "DELETE FROM concurrent_test_results WHERE index_type = '$index_type';" 2>/dev/null

    # 预热
    echo "预热..."
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

    echo "开始并发测试..."

    # 记录 shell 端开始时间（用于计算总吞吐量）
    shell_start=$(date +%s%3N)

    # 并行启动多个进程，每个进程在数据库内部计时
    for i in $(seq 1 $THREADS); do
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

    # 从数据库获取汇总结果
    result=$($PSQL -t -A -F',' -c "
        SELECT
            COUNT(*) as threads,
            SUM(query_count) as total_queries,
            ROUND(AVG(elapsed_ms), 2) as avg_elapsed_ms,
            ROUND(MAX(elapsed_ms), 2) as max_elapsed_ms,
            ROUND(MIN(elapsed_ms), 2) as min_elapsed_ms
        FROM concurrent_test_results
        WHERE index_type = '$index_type';
    ")

    threads_done=$(echo $result | cut -d',' -f1)
    total_queries=$(echo $result | cut -d',' -f2)
    avg_elapsed=$(echo $result | cut -d',' -f3)
    max_elapsed=$(echo $result | cut -d',' -f4)
    min_elapsed=$(echo $result | cut -d',' -f5)

    # 计算指标
    # 1. 单线程 QPS（基于平均执行时间）
    single_qps=$(awk "BEGIN {printf \"%.0f\", $QUERIES_PER_THREAD / ($avg_elapsed / 1000.0)}")

    # 2. 总吞吐量（基于 shell 端总时间，即所有线程并行执行的实际时间）
    total_qps=$(awk "BEGIN {printf \"%.0f\", $total_queries / ($shell_elapsed / 1000.0)}")

    # 3. 平均延迟（基于数据库内部计时）
    avg_latency=$(awk "BEGIN {printf \"%.2f\", $avg_elapsed * 1000 / $QUERIES_PER_THREAD}")

    echo ""
    echo "结果: $index_type"
    echo "  完成线程数: $threads_done"
    echo "  总查询数: $total_queries"
    echo "  ---"
    echo "  DB内部计时 (每线程):"
    echo "    平均耗时: ${avg_elapsed}ms"
    echo "    最小耗时: ${min_elapsed}ms"
    echo "    最大耗时: ${max_elapsed}ms"
    echo "    单线程QPS: $single_qps"
    echo "    平均延迟: ${avg_latency}μs"
    echo "  ---"
    echo "  Shell端计时 (并发总时间):"
    echo "    总耗时: ${shell_elapsed}ms"
    echo "    总吞吐量: $total_qps QPS"

    eval "${index_type}_single_qps=$single_qps"
    eval "${index_type}_total_qps=$total_qps"
    eval "${index_type}_latency=$avg_latency"
    eval "${index_type}_shell_elapsed=$shell_elapsed"
}

echo "=============================================="
echo "NRINDEX vs BTREE 并发性能测试 v2"
echo "=============================================="
echo "线程数: $THREADS"
echo "每线程查询数: $QUERIES_PER_THREAD"
echo "总查询数: $((THREADS * QUERIES_PER_THREAD))"
echo "=============================================="

if [ "$INDEX_TYPE" = "nrindex" ] || [ "$INDEX_TYPE" = "both" ]; then
    run_test "NRINDEX" "covid_nrindex"
fi

if [ "$INDEX_TYPE" = "btree" ] || [ "$INDEX_TYPE" = "both" ]; then
    run_test "BTREE" "covid_btree"
fi

if [ "$INDEX_TYPE" = "both" ]; then
    echo ""
    echo "=============================================="
    echo "性能对比"
    echo "=============================================="

    if [ -n "$NRINDEX_single_qps" ] && [ -n "$BTREE_single_qps" ]; then
        single_ratio=$(awk "BEGIN {printf \"%.2f\", $NRINDEX_single_qps / $BTREE_single_qps}")
        total_ratio=$(awk "BEGIN {printf \"%.2f\", $NRINDEX_total_qps / $BTREE_total_qps}")

        echo ""
        echo "单线程性能 (DB内部计时):"
        echo "  NRINDEX: $NRINDEX_single_qps QPS (延迟 ${NRINDEX_latency}μs)"
        echo "  BTREE:   $BTREE_single_qps QPS (延迟 ${BTREE_latency}μs)"
        echo "  比值:    $single_ratio"

        echo ""
        echo "并发吞吐量 (Shell端计时):"
        echo "  NRINDEX: $NRINDEX_total_qps QPS (${NRINDEX_shell_elapsed}ms)"
        echo "  BTREE:   $BTREE_total_qps QPS (${BTREE_shell_elapsed}ms)"
        echo "  比值:    $total_ratio"

        echo ""
        if [ $(awk "BEGIN {print ($NRINDEX_single_qps > $BTREE_single_qps) ? 1 : 0}") = "1" ]; then
            improvement=$(awk "BEGIN {printf \"%.1f\", ($single_ratio - 1) * 100}")
            echo "结论: NRINDEX 单线程比 BTREE 快 ${improvement}%"
        else
            degradation=$(awk "BEGIN {printf \"%.1f\", (1 - $single_ratio) * 100}")
            echo "结论: NRINDEX 单线程比 BTREE 慢 ${degradation}%"
        fi
    fi
fi

# 清理
$PSQL -c "DROP TABLE IF EXISTS concurrent_test_results;" 2>/dev/null

echo ""
echo "测试完成!"
