#!/bin/bash
# pgbench 对比测试: 无索引 vs nrindex vs B-tree
# Usage: ./pgbench_compare.sh

PSQL="/code/neurdb-dev/psql/bin/psql -h /tmp -d neurdb"
PGBENCH="/code/neurdb-dev/psql/bin/pgbench -h /tmp -d neurdb"
QUERY_COUNT=100000

echo "=============================================="
echo "pgbench 索引性能对比测试"
echo "查询数量: $QUERY_COUNT"
echo "测试项目: 无索引 / nrindex (LIPP) / B-tree"
echo "=============================================="

# 生成测试查询文件
echo ""
echo "Step 1: 生成 $QUERY_COUNT 条随机查询..."

$PSQL -t -A -c "
SELECT 'SELECT * FROM books WHERE val = ' || val || ';'
FROM books
ORDER BY random()
LIMIT $QUERY_COUNT;
" > /tmp/queries_raw.sql

# 创建带索引的测试文件 (禁用 seqscan)
cat > /tmp/pgbench_with_index.sql << 'EOF'
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;
EOF
cat /tmp/queries_raw.sql >> /tmp/pgbench_with_index.sql

# # 创建无索引的测试文件 (启用 seqscan)
# cat > /tmp/pgbench_no_index.sql << 'EOF'
# SET enable_seqscan = on;
# SET max_parallel_workers_per_gather = 0;
# EOF
# cat /tmp/queries_raw.sql >> /tmp/pgbench_no_index.sql

echo "生成完成"
echo "查询数量: $(wc -l < /tmp/queries_raw.sql)"

# ============================================
# 测试 1: 无索引 (Sequential Scan)
# ============================================
# echo ""
# echo "=============================================="
# echo "Benchmark 1: 无索引 (Sequential Scan)"
# echo "=============================================="

# $PSQL -c "DROP INDEX IF EXISTS idx_books_val_btree;" 2>/dev/null
# $PSQL -c "DROP INDEX IF EXISTS idx_books_val;" 2>/dev/null

# echo "无索引，使用顺序扫描..."
# echo ""
# echo "运行 pgbench 测试..."
# $PGBENCH -n -f /tmp/pgbench_no_index.sql -c 1 -t 1 2>/dev/null

# ============================================
# 测试 2: nrindex (LIPP)
# ============================================
echo ""
echo "=============================================="
echo "Benchmark 2: nrindex (LIPP)"
echo "=============================================="

echo "创建 nrindex 索引..."
$PSQL -c "\\timing on" -c "CREATE INDEX idx_books_val ON books USING nrindex(val);"

echo ""
echo "运行 pgbench 测试..."
$PGBENCH -n -f /tmp/pgbench_with_index.sql -c 1 -t 1 2>/dev/null

# ============================================
# 测试 3: B-tree
# ============================================
echo ""
echo "=============================================="
echo "Benchmark 3: B-tree"
echo "=============================================="

$PSQL -c "DROP INDEX IF EXISTS idx_books_val;" 2>/dev/null

echo "创建 B-tree 索引..."
$PSQL -c "\\timing on" -c "CREATE INDEX idx_books_val_btree ON books USING btree(val);"

echo ""
echo "运行 pgbench 测试..."
$PGBENCH -n -f /tmp/pgbench_with_index.sql -c 1 -t 1 2>/dev/null

# ============================================
# 清理并恢复
# ============================================
echo ""
echo "=============================================="
echo "测试完成，恢复 nrindex 索引"
echo "=============================================="
$PSQL -c "DROP INDEX IF EXISTS idx_books_val_btree;" 2>/dev/null
$PSQL -c "CREATE INDEX idx_books_val ON books USING nrindex(val);" 2>/dev/null

# 清理临时文件
rm -f /tmp/queries_raw.sql /tmp/pgbench_with_index.sql /tmp/pgbench_no_index.sql

echo ""
echo "=============================================="
echo "结果说明:"
echo "  latency average = 总延迟 (越小越好)"
echo "  tps = 每秒事务数 (越大越好)"
echo "  单次查询延迟 = latency / $QUERY_COUNT"
echo "=============================================="
