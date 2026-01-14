#!/bin/bash
# =============================================
# 导入 OSM 数据到 PostgreSQL
# =============================================
# Usage: ./import_osm_data.sh [数据量]
# Example:
#   ./import_osm_data.sh           # 导入全部数据
#   ./import_osm_data.sh 10000000  # 导入 1000 万条
#   ./import_osm_data.sh 50000000  # 导入 5000 万条
# =============================================

PSQL="/code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb"
DATA_FILE="/hdd9/benjamin/SOSD/scripts/data/osm_200M_sorted.csv"
IMPORT_LIMIT=${1:-0}  # 0 表示全部导入

echo "=============================================="
echo "导入 OSM 数据到 PostgreSQL"
echo "=============================================="
echo "数据文件: $DATA_FILE"

# 检查数据文件是否存在
if [ ! -f "$DATA_FILE" ]; then
    echo "错误: 数据文件不存在: $DATA_FILE"
    exit 1
fi

# 显示文件大小
FILE_SIZE=$(ls -lh "$DATA_FILE" | awk '{print $5}')
echo "文件大小: $FILE_SIZE"

if [ "$IMPORT_LIMIT" -eq 0 ]; then
    echo "导入数量: 全部"
else
    echo "导入数量: $IMPORT_LIMIT 条"
fi
echo ""

# Step 1: 创建主表并导入数据
echo "Step 1: 创建主表 osm 并导入数据..."
START_TIME=$(date +%s)

$PSQL -c "DROP TABLE IF EXISTS osm CASCADE;"
$PSQL -c "CREATE TABLE osm (id INT PRIMARY KEY, val BIGINT);"

if [ "$IMPORT_LIMIT" -eq 0 ]; then
    # 导入全部数据
    $PSQL -c "\copy osm FROM '$DATA_FILE' CSV HEADER;"
else
    # 导入指定数量（+1 是因为要包含 header 行）
    TEMP_FILE="/tmp/osm_import_temp.csv"
    head -n $((IMPORT_LIMIT + 1)) "$DATA_FILE" > "$TEMP_FILE"
    $PSQL -c "\copy osm FROM '$TEMP_FILE' CSV HEADER;"
    rm -f "$TEMP_FILE"
fi

$PSQL -c "SELECT COUNT(*) AS row_count FROM osm;"

END_TIME=$(date +%s)
ELAPSED=$((END_TIME - START_TIME))
echo "导入完成，耗时: ${ELAPSED}s"
echo ""

# Step 2: 创建查询键表
echo "Step 2: 创建查询键表 query_keys..."
$PSQL << 'EOF'
-- 删除旧表
DROP TABLE IF EXISTS query_keys;

-- 从主表随机抽取 100 万个键作为查询键
CREATE TABLE query_keys (val BIGINT);
INSERT INTO query_keys SELECT val FROM osm ORDER BY RANDOM() LIMIT 1000000;

-- 验证数据量
SELECT COUNT(*) AS key_count FROM query_keys;
EOF
echo "查询键表创建完成"
echo ""

# Step 3: 创建测试表
echo "Step 3: 创建测试表..."
$PSQL << 'EOF'
-- 创建 NRINDEX 测试表
DROP TABLE IF EXISTS osm_nrindex CASCADE;
CREATE TABLE osm_nrindex (id INT PRIMARY KEY, val BIGINT);
INSERT INTO osm_nrindex SELECT id, val FROM osm;
ANALYZE osm_nrindex;

-- 创建 BTREE 测试表
DROP TABLE IF EXISTS osm_btree CASCADE;
CREATE TABLE osm_btree (id INT PRIMARY KEY, val BIGINT);
INSERT INTO osm_btree SELECT id, val FROM osm;
ANALYZE osm_btree;
EOF
echo "测试表创建完成"
echo ""

# Step 4: 显示数据统计
echo "=============================================="
echo "数据统计"
echo "=============================================="
$PSQL -c "
SELECT 'osm' AS table_name, COUNT(*) AS row_count FROM osm
UNION ALL
SELECT 'osm_nrindex', COUNT(*) FROM osm_nrindex
UNION ALL
SELECT 'osm_btree', COUNT(*) FROM osm_btree
UNION ALL
SELECT 'query_keys', COUNT(*) FROM query_keys;
"

echo ""
echo "=============================================="
echo "导入完成！"
echo "=============================================="
echo ""
echo "接下来可以运行性能测试:"
echo "  ./pgbench_point_query.sh"
echo ""
