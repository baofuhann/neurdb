#!/bin/bash
# TPC-H 性能测试脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TPCH_DIR="/hdd9/benjamin/tpch-kit"
QUERY_DIR="$TPCH_DIR/queries"
RESULT_DIR="$SCRIPT_DIR/results"

# ===== 配置参数 =====
DB_NAME="${1:-tpch_test}"
DB_USER="${2:-neurdb}"
DB_HOST="${3:-localhost}"
DB_PORT="${4:-5432}"
RUNS="${5:-3}"  # 每个查询运行次数

PSQL="/code/neurdb-dev/psql/bin/psql -U $DB_USER -h $DB_HOST -p $DB_PORT -d $DB_NAME"

mkdir -p "$RESULT_DIR"

echo "===== TPC-H 性能测试 ====="
echo "数据库: $DB_NAME"
echo "每个查询运行次数: $RUNS"
echo "结果保存位置: $RESULT_DIR"
echo ""

# 检查查询文件
if [ ! -d "$QUERY_DIR" ] || [ -z "$(ls -A $QUERY_DIR 2>/dev/null)" ]; then
    echo "错误: 查询文件不存在，请先运行 01_install_tpch.sh"
    exit 1
fi

# 预热数据库
echo "预热数据库缓存..."
$PSQL -c "SELECT COUNT(*) FROM lineitem;" > /dev/null 2>&1

# 结果文件
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
RESULT_FILE="$RESULT_DIR/benchmark_$TIMESTAMP.csv"
DETAIL_FILE="$RESULT_DIR/benchmark_detail_$TIMESTAMP.log"

echo "Query,Run,Time_ms" > "$RESULT_FILE"
echo "TPC-H Benchmark - $(date)" > "$DETAIL_FILE"
echo "Database: $DB_NAME, Runs: $RUNS" >> "$DETAIL_FILE"
echo "========================================" >> "$DETAIL_FILE"

# 运行测试
declare -a avg_times

for q in $(seq 1 22); do
    QUERY_FILE="$QUERY_DIR/q$q.sql"

    if [ ! -f "$QUERY_FILE" ]; then
        echo "跳过 Q$q (文件不存在)"
        continue
    fi

    echo -n "Q$q: "
    total_time=0

    for r in $(seq 1 $RUNS); do
        # 清理缓存（可选，需要 root 权限）
        # sync && echo 3 > /proc/sys/vm/drop_caches

        START=$(date +%s%N)
        $PSQL -f "$QUERY_FILE" > /dev/null 2>&1
        END=$(date +%s%N)

        TIME_MS=$(( (END - START) / 1000000 ))
        total_time=$((total_time + TIME_MS))

        echo "$q,$r,$TIME_MS" >> "$RESULT_FILE"
        echo -n "${TIME_MS}ms "
    done

    avg=$((total_time / RUNS))
    avg_times[$q]=$avg
    echo "| 平均: ${avg}ms"

    echo "Q$q: avg=${avg}ms (runs: $RUNS)" >> "$DETAIL_FILE"
done

# 生成汇总报告
echo ""
echo "===== 测试结果汇总 ====="
echo ""

SUMMARY_FILE="$RESULT_DIR/summary_$TIMESTAMP.txt"
{
    echo "TPC-H Benchmark Summary"
    echo "========================"
    echo "Date: $(date)"
    echo "Database: $DB_NAME"
    echo "Runs per query: $RUNS"
    echo ""
    echo "Query | Avg Time (ms)"
    echo "------|---------------"

    total=0
    for q in $(seq 1 22); do
        if [ -n "${avg_times[$q]}" ]; then
            printf "Q%-4d | %d\n" $q ${avg_times[$q]}
            total=$((total + avg_times[$q]))
        fi
    done

    echo "------|---------------"
    echo "Total | $total ms"
    echo ""
    echo "Total execution time: ${total}ms ($(echo "scale=2; $total/1000" | bc)s)"

} | tee "$SUMMARY_FILE"

echo ""
echo "详细结果已保存到:"
echo "  - $RESULT_FILE (CSV)"
echo "  - $SUMMARY_FILE (汇总)"
