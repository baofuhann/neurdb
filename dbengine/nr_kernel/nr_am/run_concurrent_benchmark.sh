#!/bin/bash
# =============================================
# 完整并发测试脚本
# 1. 检查/创建数据表
# 2. 创建索引
# 3. 执行并发测试
# =============================================
# Usage: ./run_concurrent_benchmark.sh [threads] [queries_per_thread]
# Example: ./run_concurrent_benchmark.sh 4 25000

THREADS=${1:-4}
QUERIES_PER_THREAD=${2:-25000}

PSQL="/code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=============================================="
echo "NRINDEX vs BTREE 完整并发测试"
echo "=============================================="
echo "并发线程数: $THREADS"
echo "每线程查询数: $QUERIES_PER_THREAD"
echo "总查询数: $((THREADS * QUERIES_PER_THREAD))"
echo "=============================================="

# =============================================
# Step 1: 检查并创建数据表
# =============================================
echo ""
echo "Step 1: 检查数据表..."

$PSQL -t -A << 'EOF'
SET client_min_messages = NOTICE;

DO $$
BEGIN
    -- 检查源表 covid 是否存在
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'covid') THEN
        RAISE EXCEPTION '源表 covid 不存在，请先创建并导入数据';
    END IF;

    -- 检查 query_keys 表是否存在
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'query_keys') THEN
        RAISE EXCEPTION '查询键表 query_keys 不存在，请先创建并导入数据';
    END IF;

    -- 创建 covid_nrindex 表
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'covid_nrindex') THEN
        RAISE NOTICE '创建 covid_nrindex 表...';
        CREATE TABLE covid_nrindex (id INT PRIMARY KEY, val BIGINT);
        INSERT INTO covid_nrindex SELECT id, val FROM covid;
        RAISE NOTICE 'covid_nrindex 表创建完成';
    ELSE
        RAISE NOTICE 'covid_nrindex 表已存在，跳过创建';
    END IF;

    -- 创建 covid_btree 表
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'covid_btree') THEN
        RAISE NOTICE '创建 covid_btree 表...';
        CREATE TABLE covid_btree (id INT PRIMARY KEY, val BIGINT);
        INSERT INTO covid_btree SELECT id, val FROM covid;
        RAISE NOTICE 'covid_btree 表创建完成';
    ELSE
        RAISE NOTICE 'covid_btree 表已存在，跳过创建';
    END IF;
END $$;
EOF

if [ $? -ne 0 ]; then
    echo "错误: 数据表准备失败"
    exit 1
fi

# 显示数据量
echo ""
echo "数据量统计:"
$PSQL -t << 'EOF'
SELECT '  covid_nrindex: ' || COUNT(*) || ' 行' FROM covid_nrindex
UNION ALL
SELECT '  covid_btree:   ' || COUNT(*) || ' 行' FROM covid_btree
UNION ALL
SELECT '  query_keys:    ' || COUNT(*) || ' 行' FROM query_keys;
EOF

# =============================================
# Step 2: 创建索引
# =============================================
echo ""
echo "Step 2: 创建索引..."

# 检查并创建 NRINDEX
NRINDEX_EXISTS=$($PSQL -t -A -c "SELECT COUNT(*) FROM pg_indexes WHERE indexname = 'idx_nrindex';")
if [ "$NRINDEX_EXISTS" -eq 0 ]; then
    echo "创建 NRINDEX 索引..."
    start_time=$(date +%s%3N)
    $PSQL -c "CREATE INDEX idx_nrindex ON covid_nrindex USING nrindex(val);" 2>&1
    end_time=$(date +%s%3N)
    echo "NRINDEX 创建时间: $((end_time - start_time)) ms"
else
    echo "idx_nrindex 索引已存在，跳过创建"
fi

# 检查并创建 BTREE
BTREE_EXISTS=$($PSQL -t -A -c "SELECT COUNT(*) FROM pg_indexes WHERE indexname = 'idx_btree';")
if [ "$BTREE_EXISTS" -eq 0 ]; then
    echo "创建 BTREE 索引..."
    start_time=$(date +%s%3N)
    $PSQL -c "CREATE INDEX idx_btree ON covid_btree USING btree(val);" 2>&1
    end_time=$(date +%s%3N)
    echo "BTREE 创建时间: $((end_time - start_time)) ms"
else
    echo "idx_btree 索引已存在，跳过创建"
fi

# 显示索引信息
echo ""
echo "索引信息:"
$PSQL -t << 'EOF'
SELECT '  ' || indexname || ' (' || indexdef || ')'
FROM pg_indexes
WHERE tablename IN ('covid_nrindex', 'covid_btree')
  AND indexname IN ('idx_nrindex', 'idx_btree');
EOF

# =============================================
# Step 3: 执行并发测试
# =============================================
echo ""
echo "Step 3: 执行并发测试..."
echo ""

# 检查 concurrent_test.sh 是否存在
if [ ! -f "$SCRIPT_DIR/concurrent_test.sh" ]; then
    echo "错误: concurrent_test.sh 不存在"
    exit 1
fi

chmod +x "$SCRIPT_DIR/concurrent_test.sh"
"$SCRIPT_DIR/concurrent_test.sh" "$THREADS" "$QUERIES_PER_THREAD" both

echo ""
echo "=============================================="
echo "完整测试结束!"
echo "=============================================="
