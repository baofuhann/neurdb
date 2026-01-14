#!/bin/bash

PSQL="/code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb"
PGBENCH="/code/neurdb-dev/psql/bin/pgbench -h 127.0.0.1"
DBNAME="neurdb"
WORKLOAD_DIR="/code/neurdb-dev/dbengine/nr_kernel/nr_am/workload"

# 测试参数
CLIENTS=64          # 并发连接数
THREADS=10          # 线程数
TOTAL_OPS=1000000   # 每个工作负载的总操作数
PROGRESS=5          # 进度输出间隔(秒)

# 所有可用的工作负载定义 (名称:查询比例:插入比例)
ALL_WORKLOADS=(
    "read_only:100:0"
    "read_heavy:80:20"
    "balanced:50:50"
    "write_heavy:20:80"
    "write_only:0:100"
)

# 使用说明
usage() {
    echo "用法: $0 [工作负载名称...]"
    echo ""
    echo "可用的工作负载:"
    echo "  read_only    - 100% 查询, 0% 插入"
    echo "  read_heavy   - 80% 查询, 20% 插入"
    echo "  balanced     - 50% 查询, 50% 插入"
    echo "  write_heavy  - 20% 查询, 80% 插入"
    echo "  write_only   - 0% 查询, 100% 插入"
    echo "  all          - 运行所有工作负载"
    echo ""
    echo "示例:"
    echo "  $0 read_only              # 只运行只读测试"
    echo "  $0 read_only balanced     # 运行只读和平衡测试"
    echo "  $0 all                    # 运行所有测试"
    exit 1
}

# 根据名称获取工作负载定义
get_workload() {
    local name=$1
    for w in "${ALL_WORKLOADS[@]}"; do
        if [[ "$w" == "$name:"* ]]; then
            echo "$w"
            return 0
        fi
    done
    return 1
}

# 解析命令行参数
WORKLOADS=()
if [ $# -eq 0 ]; then
    usage
elif [ "$1" == "all" ]; then
    WORKLOADS=("${ALL_WORKLOADS[@]}")
else
    for arg in "$@"; do
        workload=$(get_workload "$arg")
        if [ -n "$workload" ]; then
            WORKLOADS+=("$workload")
        else
            echo "错误: 未知的工作负载 '$arg'"
            usage
        fi
    done
fi

# 确保工作负载目录存在
mkdir -p "$WORKLOAD_DIR"

echo "=============================================="
echo "pgbench 多种工作负载测试: NRINDEX vs BTREE"
echo "=============================================="
echo "工作负载类型: read_only, read_heavy, balanced, write_heavy, write_only"
echo "并发连接: $CLIENTS"
echo "线程数: $THREADS"
echo "每工作负载总操作数: $TOTAL_OPS"
echo "=============================================="

# =============================================
# Step 1: 检查表是否存在
# =============================================
echo ""
echo "Step 1: 检查表是否存在..."

check_table() {
    local table=$1
    local exists=$($PSQL -t -A -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_name = '$table';")
    echo "$exists"
}

COVID_NRINDEX_EXISTS=$(check_table "covid_nrindex")
COVID_BTREE_EXISTS=$(check_table "covid_btree")
QUERY_KEYS_EXISTS=$(check_table "query_keys")
INSERT_KEYS_EXISTS=$(check_table "insert_keys")

echo "  covid_nrindex: $([ "$COVID_NRINDEX_EXISTS" -eq 1 ] && echo '存在' || echo '不存在')"
echo "  covid_btree:   $([ "$COVID_BTREE_EXISTS" -eq 1 ] && echo '存在' || echo '不存在')"
echo "  query_keys:    $([ "$QUERY_KEYS_EXISTS" -eq 1 ] && echo '存在' || echo '不存在')"
echo "  insert_keys:   $([ "$INSERT_KEYS_EXISTS" -eq 1 ] && echo '存在' || echo '不存在')"

# 检查必要的表
if [ "$COVID_NRINDEX_EXISTS" -eq 0 ] || [ "$COVID_BTREE_EXISTS" -eq 0 ]; then
    echo "错误: covid_nrindex 或 covid_btree 表不存在，请先运行 prepare_test_data.sh"
    exit 1
fi

if [ "$QUERY_KEYS_EXISTS" -eq 0 ] || [ "$INSERT_KEYS_EXISTS" -eq 0 ]; then
    echo "错误: query_keys 或 insert_keys 表不存在，请先运行 prepare_test_data.sh"
    exit 1
fi

# =============================================
# Step 2: 显示数据量
# =============================================
echo ""
echo "Step 2: 数据量统计..."

NRINDEX_COUNT=$($PSQL -t -A -c "SELECT COUNT(*) FROM covid_nrindex;")
BTREE_COUNT=$($PSQL -t -A -c "SELECT COUNT(*) FROM covid_btree;")
QUERY_KEYS_COUNT=$($PSQL -t -A -c "SELECT COUNT(*) FROM query_keys;")
INSERT_KEYS_COUNT=$($PSQL -t -A -c "SELECT COUNT(*) FROM insert_keys;")

echo "  covid_nrindex: $NRINDEX_COUNT 行"
echo "  covid_btree:   $BTREE_COUNT 行"
echo "  query_keys:    $QUERY_KEYS_COUNT 行"
echo "  insert_keys:   $INSERT_KEYS_COUNT 行"

# =============================================
# Step 3: 准备辅助表
# =============================================
echo ""
echo "Step 3: 准备辅助表..."

$PSQL << 'EOF'
-- 查询键索引表
DROP TABLE IF EXISTS qk_idx;
CREATE UNLOGGED TABLE qk_idx (id INT PRIMARY KEY, val BIGINT);
INSERT INTO qk_idx SELECT id, val FROM query_keys;
ANALYZE qk_idx;

-- 插入键索引表
DROP TABLE IF EXISTS ik_idx;
CREATE UNLOGGED TABLE ik_idx (id INT PRIMARY KEY, val BIGINT);
INSERT INTO ik_idx SELECT id, val FROM insert_keys;
ANALYZE ik_idx;
EOF

QUERY_KEY_COUNT=$($PSQL -t -A -c "SELECT COUNT(*) FROM qk_idx;")
INSERT_KEY_COUNT=$($PSQL -t -A -c "SELECT COUNT(*) FROM ik_idx;")
echo "  qk_idx 表: $QUERY_KEY_COUNT 个查询键"
echo "  ik_idx 表: $INSERT_KEY_COUNT 个插入键"

# =============================================
# 函数: 创建工作负载SQL文件
# =============================================
create_workload_sql() {
    local index_type=$1      # nrindex 或 btree
    local table_name=$2      # 表名
    local query_weight=$3    # 查询权重
    local insert_weight=$4   # 插入权重
    local base_id=$5         # 插入起始ID

    local query_file="${WORKLOAD_DIR}/bench_${index_type}_query.sql"
    local insert_file="${WORKLOAD_DIR}/bench_${index_type}_insert.sql"

    # 查询SQL
    cat > "$query_file" << EOF
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;
\set kid random(1, $QUERY_KEY_COUNT)
SELECT * FROM $table_name WHERE val = (SELECT val FROM qk_idx WHERE id = :kid) LIMIT 1;
EOF

    # 插入SQL - 使用随机插入键
    cat > "$insert_file" << EOF
SET enable_seqscan = off;
\set iid random(1, $INSERT_KEY_COUNT)
\set newid random($base_id, $((base_id + 50000000)))
INSERT INTO $table_name (id, val) SELECT :newid, val FROM ik_idx WHERE id = :iid ON CONFLICT (id) DO NOTHING;
EOF

    echo "$query_file $insert_file"
}

# =============================================
# 函数: 运行单个工作负载测试
# =============================================
run_workload_test() {
    local workload_name=$1
    local query_ratio=$2
    local insert_ratio=$3
    local index_type=$4
    local table_name=$5
    local base_id=$6

    echo ""
    echo "--- $index_type: $workload_name (查询:$query_ratio% 插入:$insert_ratio%) ---"

    local files=$(create_workload_sql "$index_type" "$table_name" "$query_ratio" "$insert_ratio" "$base_id")
    local query_file=$(echo $files | cut -d' ' -f1)
    local insert_file=$(echo $files | cut -d' ' -f2)

    # 计算每种操作的事务数
    local query_txns=$((TOTAL_OPS * query_ratio / 100))
    local insert_txns=$((TOTAL_OPS * insert_ratio / 100))

    local result=""
    local tps=""
    local lat=""

    if [ "$query_ratio" -eq 100 ]; then
        # 只读工作负载
        result=$($PGBENCH -c $CLIENTS -j $THREADS -t $((query_txns / CLIENTS)) -P $PROGRESS -n -f "$query_file" $DBNAME 2>&1)
    elif [ "$insert_ratio" -eq 100 ]; then
        # 只写工作负载
        result=$($PGBENCH -c $CLIENTS -j $THREADS -t $((insert_txns / CLIENTS)) -P $PROGRESS -n -f "$insert_file" $DBNAME 2>&1)
    else
        # 混合工作负载 - 使用权重
        result=$($PGBENCH -c $CLIENTS -j $THREADS -t $((TOTAL_OPS / CLIENTS)) -P $PROGRESS -n \
            -f "$query_file"@$query_ratio \
            -f "$insert_file"@$insert_ratio \
            $DBNAME 2>&1)
    fi

    echo "$result" | tail -5

    tps=$(echo "$result" | grep -oP 'tps = \K[0-9.]+' | head -1)
    lat=$(echo "$result" | grep -oP 'latency average = \K[0-9.]+')

    echo "$tps $lat"
}

# =============================================
# Step 4: 存储结果
# =============================================
declare -A NRINDEX_RESULTS
declare -A BTREE_RESULTS

# =============================================
# Step 5: 执行各工作负载测试
# =============================================
echo ""
echo "=============================================="
echo "Step 5: 执行工作负载测试"
echo "=============================================="

# 获取当前最大ID作为插入基准
NRINDEX_MAX_ID=$($PSQL -t -A -c "SELECT COALESCE(MAX(id), 0) FROM covid_nrindex;")
BTREE_MAX_ID=$($PSQL -t -A -c "SELECT COALESCE(MAX(id), 0) FROM covid_btree;")

for workload in "${WORKLOADS[@]}"; do
    IFS=':' read -r name query_ratio insert_ratio <<< "$workload"

    echo ""
    echo "=============================================="
    echo "工作负载: $name (查询:$query_ratio% 插入:$insert_ratio%)"
    echo "=============================================="

    # 测试前重置表数据（如果有插入操作）
    if [ "$insert_ratio" -gt 0 ]; then
        echo "重置测试表数据..."
        $PSQL -c "DELETE FROM covid_nrindex WHERE id > $NRINDEX_MAX_ID;" 2>/dev/null
        $PSQL -c "DELETE FROM covid_btree WHERE id > $BTREE_MAX_ID;" 2>/dev/null
    fi

    # 测试 NRINDEX
    echo ""
    echo ">>> 测试 NRINDEX <<<"
    NRINDEX_OUTPUT=$(run_workload_test "$name" "$query_ratio" "$insert_ratio" "nrindex" "covid_nrindex" "$((NRINDEX_MAX_ID + 1))")
    NRINDEX_TPS=$(echo "$NRINDEX_OUTPUT" | tail -1 | awk '{print $1}')
    NRINDEX_LAT=$(echo "$NRINDEX_OUTPUT" | tail -1 | awk '{print $2}')
    NRINDEX_RESULTS["$name"]="$NRINDEX_TPS $NRINDEX_LAT"

    # 重置数据
    if [ "$insert_ratio" -gt 0 ]; then
        $PSQL -c "DELETE FROM covid_nrindex WHERE id > $NRINDEX_MAX_ID;" 2>/dev/null
        $PSQL -c "DELETE FROM covid_btree WHERE id > $BTREE_MAX_ID;" 2>/dev/null
    fi

    # 测试 BTREE
    echo ""
    echo ">>> 测试 BTREE <<<"
    BTREE_OUTPUT=$(run_workload_test "$name" "$query_ratio" "$insert_ratio" "btree" "covid_btree" "$((BTREE_MAX_ID + 1))")
    BTREE_TPS=$(echo "$BTREE_OUTPUT" | tail -1 | awk '{print $1}')
    BTREE_LAT=$(echo "$BTREE_OUTPUT" | tail -1 | awk '{print $2}')
    BTREE_RESULTS["$name"]="$BTREE_TPS $BTREE_LAT"
done

# =============================================
# Step 6: 结果汇总
# =============================================
echo ""
echo "=============================================="
echo "测试结果汇总"
echo "=============================================="
echo ""

printf "%-15s | %-12s | %-12s | %-12s | %-12s | %-10s\n" \
    "工作负载" "NRINDEX TPS" "NRINDEX延迟" "BTREE TPS" "BTREE延迟" "加速比"
printf "%-15s-+-%-12s-+-%-12s-+-%-12s-+-%-12s-+-%-10s\n" \
    "---------------" "------------" "------------" "------------" "------------" "----------"

for workload in "${WORKLOADS[@]}"; do
    IFS=':' read -r name query_ratio insert_ratio <<< "$workload"

    nr_data="${NRINDEX_RESULTS[$name]}"
    bt_data="${BTREE_RESULTS[$name]}"

    nr_tps=$(echo "$nr_data" | awk '{print $1}')
    nr_lat=$(echo "$nr_data" | awk '{print $2}')
    bt_tps=$(echo "$bt_data" | awk '{print $1}')
    bt_lat=$(echo "$bt_data" | awk '{print $2}')

    if [ -n "$nr_tps" ] && [ -n "$bt_tps" ] && [ "$bt_tps" != "0" ]; then
        speedup=$(awk "BEGIN {printf \"%.2fx\", $nr_tps / $bt_tps}")
    else
        speedup="N/A"
    fi

    printf "%-15s | %-12s | %-12s | %-12s | %-12s | %-10s\n" \
        "$name" "$nr_tps" "${nr_lat}ms" "$bt_tps" "${bt_lat}ms" "$speedup"
done

# SQL文件保留在 ${WORKLOAD_DIR} 目录
echo "SQL文件保存在: ${WORKLOAD_DIR}/"

echo ""
echo "=============================================="
echo "测试完成!"
echo "=============================================="
