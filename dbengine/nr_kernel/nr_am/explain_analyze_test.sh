#!/bin/bash
# =============================================
# EXPLAIN ANALYZE 索引性能分析脚本 (单连接，带预热)
# 支持读取和写入性能测试
# =============================================
# Usage: ./explain_analyze_test.sh [test_type] [query_count] [warmup_count]
# test_type: read (默认), write, both

TEST_TYPE=${1:-read}
QUERY_COUNT=${2:-100}
WARMUP_COUNT=${3:-10}
DB_NAME="neurdb"
PSQL="/code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d $DB_NAME"
RESULT_FILE="/tmp/explain_analyze_results.csv"
SQL_FILE="/tmp/explain_test.sql"

echo "=============================================="
echo "EXPLAIN ANALYZE 索引性能分析 (单连接)"
echo "=============================================="
echo "测试类型: $TEST_TYPE"
echo "预热查询数: $WARMUP_COUNT"
echo "正式查询数: $QUERY_COUNT"
echo ""

# 获取随机查询键 (用于读取测试)
echo "Step 1: 获取查询键..."
TOTAL_KEYS=$((WARMUP_COUNT + QUERY_COUNT))
QUERY_KEYS=$($PSQL -t -A -c "SELECT val FROM query_keys ORDER BY random() LIMIT $TOTAL_KEYS;")

if [ -z "$QUERY_KEYS" ]; then
    echo "错误: query_keys 表为空"
    exit 1
fi

KEY_ARRAY=($QUERY_KEYS)
echo "获取到 ${#KEY_ARRAY[@]} 个查询键"

# 获取当前最大 ID (用于写入测试)
if [ "$TEST_TYPE" = "write" ] || [ "$TEST_TYPE" = "both" ]; then
    echo "获取当前最大 ID..."
    MAX_ID_COVID=$($PSQL -t -A -c "SELECT COALESCE(MAX(id), 0) FROM covid;")
    MAX_ID_BTREE=$($PSQL -t -A -c "SELECT COALESCE(MAX(id), 0) FROM covid_btree;")
    echo "covid 表最大 ID: $MAX_ID_COVID"
    echo "covid_btree 表最大 ID: $MAX_ID_BTREE"
fi

echo ""
echo "Step 2: 检查表和索引..."
$PSQL -c "SELECT indexname, tablename FROM pg_indexes WHERE tablename IN ('covid', 'covid_btree');"

# ============================================
# 读取测试
# ============================================
run_read_test() {
    local index_type=$1
    local table_name=$2
    local output_file="/tmp/explain_read_${index_type}.txt"

    echo ""
    echo "=============================================="
    echo "读取测试: $index_type ($table_name)"
    echo "=============================================="

    # 生成 SQL 脚本
    cat > "$SQL_FILE" << 'HEADER'
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;
\timing off

HEADER

    # 添加预热查询
    echo "-- ========== 预热阶段 ==========" >> "$SQL_FILE"
    for ((i=0; i<WARMUP_COUNT; i++)); do
        key=${KEY_ARRAY[$i]}
        echo "SELECT * FROM $table_name WHERE val = $key LIMIT 1;" >> "$SQL_FILE"
    done

    # 添加正式测试查询
    echo "" >> "$SQL_FILE"
    echo "-- ========== 正式测试阶段 ==========" >> "$SQL_FILE"

    for ((i=WARMUP_COUNT; i<TOTAL_KEYS; i++)); do
        key=${KEY_ARRAY[$i]}
        echo "EXPLAIN (ANALYZE, COSTS OFF) SELECT * FROM $table_name WHERE val = $key LIMIT 1;" >> "$SQL_FILE"
    done

    echo "执行读取测试..."
    $PSQL -f "$SQL_FILE" 2>/dev/null > "$output_file"

    # 解析结果
    exec_times=$(grep "Execution Time:" "$output_file" | sed 's/.*Execution Time: \([0-9.]*\) ms.*/\1/')
    plan_times=$(grep "Planning Time:" "$output_file" | sed 's/.*Planning Time: \([0-9.]*\) ms.*/\1/')

    if [ -n "$exec_times" ]; then
        query_count=$(echo "$exec_times" | wc -l)
        avg_exec_ms=$(echo "$exec_times" | awk '{sum+=$1} END {printf "%.4f", sum/NR}')
        avg_exec_us=$(echo "$exec_times" | awk '{sum+=$1} END {printf "%.2f", sum/NR*1000}')
        avg_plan_ms=$(echo "$plan_times" | awk '{sum+=$1} END {printf "%.4f", sum/NR}')
        avg_plan_us=$(echo "$plan_times" | awk '{sum+=$1} END {printf "%.2f", sum/NR*1000}')
        min_exec_us=$(echo "$exec_times" | awk 'BEGIN{min=999999} {if($1*1000<min)min=$1*1000} END{printf "%.2f", min}')
        max_exec_us=$(echo "$exec_times" | awk 'BEGIN{max=0} {if($1*1000>max)max=$1*1000} END{printf "%.2f", max}')

        echo ""
        echo "结果 ($index_type 读取) - 预热后:"
        echo "  成功查询数: $query_count"
        echo "  平均规划时间: ${avg_plan_ms}ms (${avg_plan_us}us)"
        echo "  平均执行时间: ${avg_exec_ms}ms (${avg_exec_us}us)"
        echo "  执行时间范围: ${min_exec_us}us ~ ${max_exec_us}us"

        echo "${index_type},READ,$query_count,$avg_plan_us,$avg_exec_us" >> "$RESULT_FILE"
    else
        echo "错误: 无法获取测试结果"
    fi
}

# ============================================
# 写入测试
# ============================================
run_write_test() {
    local index_type=$1
    local table_name=$2
    local start_id=$3
    local output_file="/tmp/explain_write_${index_type}.txt"

    echo ""
    echo "=============================================="
    echo "写入测试: $index_type ($table_name)"
    echo "=============================================="

    # 生成 SQL 脚本
    cat > "$SQL_FILE" << 'HEADER'
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;
\timing off

HEADER

    # 添加预热写入
    echo "-- ========== 预热阶段 ==========" >> "$SQL_FILE"
    local current_id=$((start_id + 1))
    for ((i=0; i<WARMUP_COUNT; i++)); do
        # 生成随机 val 值
        val=$((RANDOM * RANDOM))
        echo "INSERT INTO $table_name (id, val) VALUES ($current_id, $val);" >> "$SQL_FILE"
        current_id=$((current_id + 1))
    done

    # 添加正式测试写入
    echo "" >> "$SQL_FILE"
    echo "-- ========== 正式测试阶段 ==========" >> "$SQL_FILE"

    for ((i=0; i<QUERY_COUNT; i++)); do
        val=$((RANDOM * RANDOM))
        echo "EXPLAIN (ANALYZE, COSTS OFF) INSERT INTO $table_name (id, val) VALUES ($current_id, $val);" >> "$SQL_FILE"
        current_id=$((current_id + 1))
    done

    echo "执行写入测试..."
    $PSQL -f "$SQL_FILE" 2>/dev/null > "$output_file"

    # 解析结果
    exec_times=$(grep "Execution Time:" "$output_file" | sed 's/.*Execution Time: \([0-9.]*\) ms.*/\1/')
    plan_times=$(grep "Planning Time:" "$output_file" | sed 's/.*Planning Time: \([0-9.]*\) ms.*/\1/')

    if [ -n "$exec_times" ]; then
        query_count=$(echo "$exec_times" | wc -l)
        avg_exec_ms=$(echo "$exec_times" | awk '{sum+=$1} END {printf "%.4f", sum/NR}')
        avg_exec_us=$(echo "$exec_times" | awk '{sum+=$1} END {printf "%.2f", sum/NR*1000}')
        avg_plan_ms=$(echo "$plan_times" | awk '{sum+=$1} END {printf "%.4f", sum/NR}')
        avg_plan_us=$(echo "$plan_times" | awk '{sum+=$1} END {printf "%.2f", sum/NR*1000}')
        min_exec_us=$(echo "$exec_times" | awk 'BEGIN{min=999999} {if($1*1000<min)min=$1*1000} END{printf "%.2f", min}')
        max_exec_us=$(echo "$exec_times" | awk 'BEGIN{max=0} {if($1*1000>max)max=$1*1000} END{printf "%.2f", max}')

        echo ""
        echo "结果 ($index_type 写入) - 预热后:"
        echo "  成功写入数: $query_count"
        echo "  平均规划时间: ${avg_plan_ms}ms (${avg_plan_us}us)"
        echo "  平均执行时间: ${avg_exec_ms}ms (${avg_exec_us}us)"
        echo "  执行时间范围: ${min_exec_us}us ~ ${max_exec_us}us"

        echo "${index_type},WRITE,$query_count,$avg_plan_us,$avg_exec_us" >> "$RESULT_FILE"
    else
        echo "错误: 无法获取测试结果"
    fi
}

# 清空结果文件
> "$RESULT_FILE"

echo ""
echo "Step 3: 运行测试..."

# 根据测试类型执行
case "$TEST_TYPE" in
    read)
        run_read_test "NRINDEX" "covid"
        run_read_test "BTREE" "covid_btree"
        ;;
    write)
        run_write_test "NRINDEX" "covid" "$MAX_ID_COVID"
        run_write_test "BTREE" "covid_btree" "$MAX_ID_BTREE"
        ;;
    both)
        run_read_test "NRINDEX" "covid"
        run_read_test "BTREE" "covid_btree"
        run_write_test "NRINDEX" "covid" "$MAX_ID_COVID"
        run_write_test "BTREE" "covid_btree" "$MAX_ID_BTREE"
        ;;
    *)
        echo "未知测试类型: $TEST_TYPE"
        echo "用法: $0 [read|write|both] [query_count] [warmup_count]"
        exit 1
        ;;
esac

# ============================================
# 结果对比
# ============================================
echo ""
echo "=============================================="
echo "性能对比汇总 (预热后，单连接)"
echo "=============================================="

if [ -f "$RESULT_FILE" ] && [ -s "$RESULT_FILE" ]; then
    echo ""
    echo "索引类型  | 操作   | 查询数 | 规划(us) | 执行(us)"
    echo "----------|--------|--------|----------|----------"

    while IFS=',' read -r idx op cnt plan exec; do
        printf "%-9s | %-6s | %6s | %8s | %8s\n" "$idx" "$op" "$cnt" "$plan" "$exec"
    done < "$RESULT_FILE"

    # 读取性能对比
    nrindex_read=$(grep "^NRINDEX,READ" "$RESULT_FILE" | cut -d',' -f5)
    btree_read=$(grep "^BTREE,READ" "$RESULT_FILE" | cut -d',' -f5)

    if [ -n "$nrindex_read" ] && [ -n "$btree_read" ]; then
        echo ""
        echo "--- 读取性能对比 ---"
        echo "NRINDEX: ${nrindex_read} us"
        echo "BTREE:   ${btree_read} us"

        is_faster=$(awk "BEGIN {print ($nrindex_read < $btree_read) ? 1 : 0}")
        if [ "$is_faster" = "1" ]; then
            speedup=$(awk "BEGIN {printf \"%.2f\", $btree_read / $nrindex_read}")
            echo "结论: NRINDEX 读取比 BTREE 快 ${speedup}x"
        else
            slowdown=$(awk "BEGIN {printf \"%.2f\", $nrindex_read / $btree_read}")
            echo "结论: NRINDEX 读取比 BTREE 慢 ${slowdown}x"
        fi
    fi

    # 写入性能对比
    nrindex_write=$(grep "^NRINDEX,WRITE" "$RESULT_FILE" | cut -d',' -f5)
    btree_write=$(grep "^BTREE,WRITE" "$RESULT_FILE" | cut -d',' -f5)

    if [ -n "$nrindex_write" ] && [ -n "$btree_write" ]; then
        echo ""
        echo "--- 写入性能对比 ---"
        echo "NRINDEX: ${nrindex_write} us"
        echo "BTREE:   ${btree_write} us"

        is_faster=$(awk "BEGIN {print ($nrindex_write < $btree_write) ? 1 : 0}")
        if [ "$is_faster" = "1" ]; then
            speedup=$(awk "BEGIN {printf \"%.2f\", $btree_write / $nrindex_write}")
            echo "结论: NRINDEX 写入比 BTREE 快 ${speedup}x"
        else
            slowdown=$(awk "BEGIN {printf \"%.2f\", $nrindex_write / $btree_write}")
            echo "结论: NRINDEX 写入比 BTREE 慢 ${slowdown}x"
        fi
    fi
fi

# 清理
rm -f "$SQL_FILE"

echo ""
echo "=============================================="
echo "测试完成!"
echo "=============================================="
