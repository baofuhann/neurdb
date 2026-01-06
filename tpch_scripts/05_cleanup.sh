#!/bin/bash
# TPC-H 清理脚本

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TPCH_DIR="/hdd9/benjamin/tpch-kit"

# ===== 配置参数 =====
DB_NAME="${1:-tpch_test}"
DB_USER="${2:-neurdb}"
DB_HOST="${3:-localhost}"
DB_PORT="${4:-5432}"

PSQL="/code/neurdb-dev/psql/bin/psql -U $DB_USER -h $DB_HOST -p $DB_PORT"

echo "===== TPC-H 清理脚本 ====="
echo ""

read -p "确定要删除数据库 $DB_NAME 吗? (y/N): " confirm
if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
    echo "已取消"
    exit 0
fi

# 删除数据库
echo "删除数据库 $DB_NAME..."
$PSQL -c "DROP DATABASE IF EXISTS $DB_NAME;"

read -p "是否删除 tpch-kit 生成的数据文件? (y/N): " confirm2
if [ "$confirm2" == "y" ] || [ "$confirm2" == "Y" ]; then
    echo "删除 tpch-kit 数据文件..."
    rm -f "$TPCH_DIR/dbgen/"*.tbl
    echo "删除查询文件..."
    rm -rf "$TPCH_DIR/queries"
    echo "删除结果文件..."
    rm -rf "$SCRIPT_DIR/results"
fi

echo ""
echo "清理完成"
