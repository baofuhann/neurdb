#!/bin/bash
# 运行单个 TPC-H 查询并显示执行计划

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TPCH_DIR="/hdd9/benjamin/tpch-kit"
QUERY_DIR="$TPCH_DIR/queries"

# ===== 配置参数 =====
DB_NAME="${2:-tpch_test}"
DB_USER="${3:-neurdb}"
DB_HOST="${4:-localhost}"
DB_PORT="${5:-5432}"

QUERY_NUM=$1

if [ -z "$QUERY_NUM" ]; then
    echo "用法: $0 <查询编号> [数据库名] [用户名] [主机] [端口]"
    echo "示例: $0 1"
    echo "      $0 6 tpch_test neurdb localhost 5432"
    exit 1
fi

QUERY_FILE="$QUERY_DIR/q$QUERY_NUM.sql"

if [ ! -f "$QUERY_FILE" ]; then
    echo "错误: 查询文件 $QUERY_FILE 不存在"
    exit 1
fi

PSQL="/code/neurdb-dev/psql/bin/psql -U $DB_USER -h $DB_HOST -p $DB_PORT -d $DB_NAME"

echo "===== TPC-H Query $QUERY_NUM ====="
echo ""

# 显示查询内容
echo "--- 查询语句 ---"
cat "$QUERY_FILE"
echo ""

# 运行查询并显示执行计划
echo "--- 执行计划 (EXPLAIN ANALYZE) ---"
# 将查询包装在 EXPLAIN ANALYZE 中
QUERY_CONTENT=$(cat "$QUERY_FILE" | sed 's/;//g')
$PSQL << EOF
\timing on
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
$QUERY_CONTENT;
EOF

echo ""
echo "--- 直接执行结果 ---"
$PSQL << EOF
\timing on
\pset pager off
$(cat "$QUERY_FILE")
EOF
