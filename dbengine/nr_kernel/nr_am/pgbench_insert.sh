#!/bin/bash
# pgbench 插入性能对比测试: nrindex vs B-tree
# Usage: ./pgbench_insert.sh [insert_count]

PSQL="/code/neurdb-dev/psql/bin/psql -h /tmp -d neurdb"
PGBENCH="/code/neurdb-dev/psql/bin/pgbench -h /tmp -d neurdb"
INSERT_COUNT=${1:-10000}
BULK_CSV="/tmp/books_bulk.csv"
INSERT_CSV="/tmp/books_insert.csv"

echo "=============================================="
echo "pgbench 插入性能对比测试"
echo "插入数量: $INSERT_COUNT"
echo "批量加载: $BULK_CSV"
echo "插入数据: $INSERT_CSV"
echo "测试项目: nrindex (LIPP) / B-tree"
echo "=============================================="

# 检查数据文件
if [[ ! -f "$BULK_CSV" ]]; then
    echo "错误: 批量加载文件不存在: $BULK_CSV"
    echo "请先运行: ./prepare_test_data.sh"
    exit 1
fi

if [[ ! -f "$INSERT_CSV" ]]; then
    echo "错误: 插入数据文件不存在: $INSERT_CSV"
    echo "请先运行: ./prepare_test_data.sh"
    exit 1
fi

# ============================================
# 初始化表函数：重置到一致的初始状态
# ============================================
reset_table() {
    echo ""
    echo "重置表到初始状态..."
    $PSQL -c "DROP TABLE IF EXISTS books CASCADE;" 2>/dev/null
    $PSQL -c "CREATE UNLOGGED TABLE books (id INT, val INT);" 2>/dev/null
    $PSQL -c "\copy books FROM '$BULK_CSV' CSV HEADER" 2>/dev/null
    $PSQL -c "ALTER TABLE books ADD PRIMARY KEY (id);" 2>/dev/null

    local count=$($PSQL -t -A -c "SELECT COUNT(*) FROM books;")
    echo "表初始化完成，数据量: $count"
}

# 获取最大 id
get_max_id() {
    $PSQL -t -A -c "SELECT COALESCE(MAX(id), 0) FROM books;"
}

# ============================================
# 测试 1: nrindex (LIPP) 插入
# ============================================
echo ""
echo "=============================================="
echo "Benchmark 1: nrindex (LIPP) 插入"
echo "=============================================="

# 重置表到初始状态
reset_table

# 获取最大 id 用于生成插入语句
MAX_ID=$(get_max_id)
echo "当前最大 ID: $MAX_ID"

# 生成插入语句
echo "生成 $INSERT_COUNT 条插入语句..."
tail -n +2 "$INSERT_CSV" | head -n "$INSERT_COUNT" | awk -F',' -v start_id="$((MAX_ID + 1))" '
BEGIN { id = start_id }
{
    print "INSERT INTO books (id, val) VALUES (" id ", " $2 ");"
    id++
}
' > /tmp/inserts_raw.sql

ACTUAL_COUNT=$(wc -l < /tmp/inserts_raw.sql)
echo "生成完成: $ACTUAL_COUNT 条插入语句"

# 创建测试文件
cat > /tmp/pgbench_insert.sql << 'EOF'
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;
EOF
cat /tmp/inserts_raw.sql >> /tmp/pgbench_insert.sql

# 创建 nrindex 索引
echo ""
echo "创建 nrindex 索引..."
$PSQL -c "\timing on" -c "CREATE INDEX idx_books_val ON books USING nrindex(val);"

ORIGINAL_COUNT=$($PSQL -t -A -c "SELECT COUNT(*) FROM books;")
echo "插入前数据量: $ORIGINAL_COUNT"

echo ""
echo "运行 pgbench 插入测试..."
$PGBENCH -n -f /tmp/pgbench_insert.sql -c 1 -t 1 2>/dev/null

AFTER_NRINDEX=$($PSQL -t -A -c "SELECT COUNT(*) FROM books;")
echo "插入后数据量: $AFTER_NRINDEX (插入了 $((AFTER_NRINDEX - ORIGINAL_COUNT)) 条)"

# ============================================
# 测试 2: B-tree 插入
# ============================================
echo ""
echo "=============================================="
echo "Benchmark 2: B-tree 插入"
echo "=============================================="

# 重置表到初始状态（保证与 nrindex 测试一致）
reset_table

# 获取最大 id
MAX_ID=$(get_max_id)
echo "当前最大 ID: $MAX_ID"

# 重新生成插入语句（id 相同）
echo "生成 $INSERT_COUNT 条插入语句..."
tail -n +2 "$INSERT_CSV" | head -n "$INSERT_COUNT" | awk -F',' -v start_id="$((MAX_ID + 1))" '
BEGIN { id = start_id }
{
    print "INSERT INTO books (id, val) VALUES (" id ", " $2 ");"
    id++
}
' > /tmp/inserts_raw.sql

cat > /tmp/pgbench_insert.sql << 'EOF'
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;
EOF
cat /tmp/inserts_raw.sql >> /tmp/pgbench_insert.sql

# 创建 B-tree 索引
echo ""
echo "创建 B-tree 索引..."
$PSQL -c "\timing on" -c "CREATE INDEX idx_books_val_btree ON books USING btree(val);"

ORIGINAL_COUNT=$($PSQL -t -A -c "SELECT COUNT(*) FROM books;")
echo "插入前数据量: $ORIGINAL_COUNT"

echo ""
echo "运行 pgbench 插入测试..."
$PGBENCH -n -f /tmp/pgbench_insert.sql -c 1 -t 1 2>/dev/null

AFTER_BTREE=$($PSQL -t -A -c "SELECT COUNT(*) FROM books;")
echo "插入后数据量: $AFTER_BTREE (插入了 $((AFTER_BTREE - ORIGINAL_COUNT)) 条)"

# ============================================
# 清理
# ============================================
echo ""
echo "=============================================="
echo "清理临时文件"
echo "=============================================="

rm -f /tmp/inserts_raw.sql /tmp/pgbench_insert.sql
echo "清理完成"

echo ""
echo "=============================================="
echo "结果说明:"
echo "  latency average = 总延迟 (越小越好)"
echo "  tps = 每秒事务数 (越大越好)"
echo "  单次插入延迟 = latency / $ACTUAL_COUNT"
echo "=============================================="
