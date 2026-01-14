#!/bin/bash
# =============================================
# 并发测试脚本: NRINDEX vs BTREE
# =============================================
# Usage: ./concurrent_test.sh [threads] [queries_per_thread] [index_type]
# Example:
#   ./concurrent_test.sh 4 25000 both

THREADS=${1:-4}
QUERIES_PER_THREAD=${2:-25000}
INDEX_TYPE=${3:-both}

PSQL="/code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb"

run_test() {
    local index_type=$1
    local table=$2

    echo ""
    echo "=============================================="
    echo "测试: $index_type ($THREADS 线程, 每线程 $QUERIES_PER_THREAD 查询)"
    echo "=============================================="

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
    start_time=$(date +%s%3N)

    # 并行启动多个进程 (每个线程查询相同的前 N 个 key)
    for i in $(seq 1 $THREADS); do
        $PSQL -t -c "
            SET enable_seqscan = off;
            SET max_parallel_workers_per_gather = 0;
            DO \$\$
            DECLARE k BIGINT; r RECORD; cnt INT := 0;
            BEGIN
                FOR k IN SELECT val FROM query_keys LIMIT $QUERIES_PER_THREAD LOOP
                    SELECT * INTO r FROM $table WHERE val = k LIMIT 1;
                    cnt := cnt + 1;
                END LOOP;
            END \$\$;
        " 2>/dev/null &
    done

    wait

    end_time=$(date +%s%3N)
    elapsed=$((end_time - start_time))
    total_queries=$((THREADS * QUERIES_PER_THREAD))
    qps=$(awk "BEGIN {printf \"%.0f\", $total_queries / ($elapsed / 1000.0)}")
    avg_latency=$(awk "BEGIN {printf \"%.2f\", $elapsed * 1000 / $total_queries}")

    echo ""
    echo "结果: $index_type"
    echo "  线程数: $THREADS"
    echo "  总查询: $total_queries"
    echo "  总耗时: ${elapsed}ms"
    echo "  吞吐量: $qps QPS"
    echo "  平均延迟: ${avg_latency}μs"

    eval "${index_type}_elapsed=$elapsed"
    eval "${index_type}_qps=$qps"
    eval "${index_type}_latency=$avg_latency"
}

echo "=============================================="
echo "NRINDEX vs BTREE 并发性能测试"
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

    if [ -n "$NRINDEX_qps" ] && [ -n "$BTREE_qps" ]; then
        ratio=$(awk "BEGIN {printf \"%.2f\", $NRINDEX_qps / $BTREE_qps}")
        if [ $(awk "BEGIN {print ($NRINDEX_qps > $BTREE_qps) ? 1 : 0}") = "1" ]; then
            improvement=$(awk "BEGIN {printf \"%.1f\", ($ratio - 1) * 100}")
            echo "NRINDEX: $NRINDEX_qps QPS (延迟 ${NRINDEX_latency}μs)"
            echo "BTREE:   $BTREE_qps QPS (延迟 ${BTREE_latency}μs)"
            echo ""
            echo "结论: NRINDEX 比 BTREE 快 ${improvement}%"
        else
            degradation=$(awk "BEGIN {printf \"%.1f\", (1 - $ratio) * 100}")
            echo "NRINDEX: $NRINDEX_qps QPS (延迟 ${NRINDEX_latency}μs)"
            echo "BTREE:   $BTREE_qps QPS (延迟 ${BTREE_latency}μs)"
            echo ""
            echo "结论: NRINDEX 比 BTREE 慢 ${degradation}%"
        fi
    fi
fi

echo ""
echo "测试完成!"
