#!/bin/bash
# =============================================
# 创建测试表并加载数据
# =============================================
# Usage: ./pgbench_create_table.sh <bulk_size_M> <query_size_M> <insert_size_M>
#   bulk_size_M:   批量加载数据量 (百万)
#   query_size_M:  查询键数量 (百万)
#   insert_size_M: 插入键数量 (百万)
#
# Example:
#   ./pgbench_create_table.sh 5 1 1

# 检查参数
if [ $# -lt 3 ]; then
    echo "Usage: $0 <bulk_size_M> <query_size_M> <insert_size_M>"
    echo ""
    echo "参数说明:"
    echo "  bulk_size_M:   批量加载数据量 (百万)"
    echo "  query_size_M:  查询键数量 (百万)"
    echo "  insert_size_M: 插入键数量 (百万)"
    echo ""
    echo "Example: $0 5 1 1"
    exit 1
fi

BULK_M=$1
QUERY_M=$2
INSERT_M=$3

# 文件路径
DATA_DIR="/code/neurdb-dev/data"
BULK_CSV="${DATA_DIR}/bulk_load_${BULK_M}M.csv"
QUERY_CSV="${DATA_DIR}/query_keys_${QUERY_M}M.csv"
INSERT_CSV="${DATA_DIR}/insert_keys_${INSERT_M}M.csv"

# PostgreSQL 配置
DB_NAME="neurdb"

echo "=============================================="
echo "创建测试表并加载数据 (无主键，只有单个索引)"
echo "=============================================="
echo "批量加载文件: $BULK_CSV"
echo "查询键文件: $QUERY_CSV"
echo "插入键文件: $INSERT_CSV"
echo "=============================================="

# 检查文件是否存在
for f in "$BULK_CSV" "$QUERY_CSV" "$INSERT_CSV"; do
    if [ ! -f "$f" ]; then
        echo "错误: 文件不存在: $f"
        exit 1
    fi
done

echo ""
echo "=== 步骤1: 清理旧表 ==="
psql -d ${DB_NAME} -c "DROP TABLE IF EXISTS covid_nrindex CASCADE;"
psql -d ${DB_NAME} -c "DROP TABLE IF EXISTS covid_btree CASCADE;"
psql -d ${DB_NAME} -c "DROP TABLE IF EXISTS query_keys CASCADE;"
psql -d ${DB_NAME} -c "DROP TABLE IF EXISTS insert_keys CASCADE;"
echo "旧表已清理"

echo ""
echo "=== 步骤2: 创建新表 (无主键) ==="
psql -d ${DB_NAME} -c "CREATE TABLE covid_nrindex (id INT, val BIGINT);"
psql -d ${DB_NAME} -c "CREATE TABLE covid_btree (id INT, val BIGINT);"
psql -d ${DB_NAME} -c "CREATE TABLE query_keys (val BIGINT);"
psql -d ${DB_NAME} -c "CREATE TABLE insert_keys (val BIGINT);"
echo "新表已创建"

echo ""
echo "=== 步骤3: 加载数据到 covid_nrindex ==="
psql -d ${DB_NAME} -c "\COPY covid_nrindex FROM '${BULK_CSV}' WITH (FORMAT csv, HEADER true);"

echo ""
echo "=== 步骤4: 加载数据到 covid_btree ==="
psql -d ${DB_NAME} -c "\COPY covid_btree FROM '${BULK_CSV}' WITH (FORMAT csv, HEADER true);"

echo ""
echo "=== 步骤5: 加载查询键数据 ==="
psql -d ${DB_NAME} -c "\COPY query_keys FROM '${QUERY_CSV}' WITH (FORMAT csv, HEADER true);"

echo ""
echo "=== 步骤6: 加载插入键数据 ==="
psql -d ${DB_NAME} -c "\COPY insert_keys FROM '${INSERT_CSV}' WITH (FORMAT csv, HEADER true);"

echo ""
echo "=== 步骤7: 创建索引 ==="
echo "创建 nrindex 索引..."
psql -d ${DB_NAME} -c "CREATE INDEX idx_covid_nrindex ON covid_nrindex USING nrindex(val);"
echo "创建 btree 索引..."
psql -d ${DB_NAME} -c "CREATE INDEX idx_covid_btree ON covid_btree USING btree(val);"
echo "索引创建完成"

echo ""
echo "=== 步骤8: 验证数据和索引 ==="
psql -d ${DB_NAME} -c "SELECT 'covid_nrindex' as table_name, COUNT(*) as row_count FROM covid_nrindex UNION ALL SELECT 'covid_btree', COUNT(*) FROM covid_btree UNION ALL SELECT 'query_keys', COUNT(*) FROM query_keys UNION ALL SELECT 'insert_keys', COUNT(*) FROM insert_keys;"

echo ""
echo "索引信息:"
psql -d ${DB_NAME} -c "SELECT indexname, indexdef FROM pg_indexes WHERE tablename IN ('covid_nrindex', 'covid_btree') ORDER BY tablename;"

echo ""
echo "=============================================="
echo "完成!"
echo "=============================================="
echo ""
echo "表结构: covid_nrindex 和 covid_btree 都是 (id INT, val BIGINT)"
echo "索引: covid_nrindex 使用 nrindex(val), covid_btree 使用 btree(val)"
echo "无主键约束，可准确测试 nrindex vs btree 性能差异"
