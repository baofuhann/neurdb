#!/bin/bash
# =============================================
# 从源数据文件生成 pgbench 测试数据
# =============================================
# Usage: ./pgbench_data.sh <source_file> <data_size_N>
#
# 处理流程:
#   1. 读取源文件前 2N 行
#   2. Shuffle 全部 2N 个数据
#   3. 对前 N 个元素排序 → 批量加载文件 (bulk_load)
#   4. 后 N 个保持乱序 → 插入键文件 (insert_keys)
#   5. 复制批量加载文件 → 查询键文件 (query_keys)
#
# Example:
#   ./pgbench_data.sh /tmp/books_200M_uint64 5000000

# 检查参数
if [ $# -lt 2 ]; then
    echo "Usage: $0 <source_file> <data_size_N>"
    echo ""
    echo "参数说明:"
    echo "  source_file:  源数据文件路径 (单列数值文件)"
    echo "  data_size_N:  数据量 N (将读取 2N 行)"
    echo ""
    echo "处理流程:"
    echo "  1. 读取源文件前 2N 行"
    echo "  2. Shuffle 全部 2N 个数据"
    echo "  3. 对前 N 个元素排序 → bulk_load_XM.csv"
    echo "  4. 后 N 个保持乱序 → insert_keys_XM.csv"
    echo "  5. 复制批量加载文件 → query_keys_XM.csv"
    echo ""
    echo "Example: $0 /code/neurdb-dev/books_40m.csv 5000000"
    exit 1
fi

SOURCE_FILE=$1
DATA_SIZE=$2

# 输出目录
OUTPUT_DIR="/code/neurdb-dev/data"
mkdir -p "$OUTPUT_DIR"

# 计算百万数后缀
SIZE_M=$((DATA_SIZE / 1000000))
if [ "$SIZE_M" -eq 0 ]; then
    SIZE_M="0"  # 小于100万时显示0M
fi

BULK_CSV="${OUTPUT_DIR}/bulk_load_${SIZE_M}M.csv"
QUERY_CSV="${OUTPUT_DIR}/query_keys_${SIZE_M}M.csv"
INSERT_CSV="${OUTPUT_DIR}/insert_keys_${SIZE_M}M.csv"
TEMP_FILE="${OUTPUT_DIR}/_temp_shuffled.txt"

echo "=============================================="
echo "从源数据文件生成 pgbench 测试数据"
echo "=============================================="
echo "源文件: $SOURCE_FILE"
echo "数据量 N: $DATA_SIZE"
echo "读取行数: $((DATA_SIZE * 2)) (2N)"
echo "=============================================="

# =============================================
# Step 1: 检查源文件
# =============================================
echo ""
echo "Step 1: 检查源文件..."

if [ ! -f "$SOURCE_FILE" ]; then
    echo "错误: 源文件不存在: $SOURCE_FILE"
    exit 1
fi

SOURCE_LINES=$(wc -l < "$SOURCE_FILE")
echo "  源文件行数: $SOURCE_LINES"

REQUIRED_LINES=$((DATA_SIZE * 2))
if [ "$SOURCE_LINES" -lt "$REQUIRED_LINES" ]; then
    echo "错误: 源文件行数不足"
    echo "  需要: $REQUIRED_LINES 行 (2N)"
    echo "  实际: $SOURCE_LINES 行"
    exit 1
fi
echo "  ✓ 源文件行数充足"

# =============================================
# Step 2: 读取前 2N 行并 Shuffle
# =============================================
echo ""
echo "Step 2: 读取前 2N 行并 Shuffle..."

# 跳过源文件 header (第1行)，只取 val 列（第2列），读取前 2N 行，然后 shuffle
tail -n +2 "$SOURCE_FILE" | cut -d',' -f2 | head -n $REQUIRED_LINES | shuf > "$TEMP_FILE"

SHUFFLED_LINES=$(wc -l < "$TEMP_FILE")
echo "  ✓ Shuffle 完成: $SHUFFLED_LINES 行"

# =============================================
# Step 3: 前 N 个排序 → 批量加载文件
# =============================================
echo ""
echo "Step 3: 生成批量加载文件 (前 N 个排序)..."

echo "id,val" > "$BULK_CSV"
# 取前 N 行，数值排序，添加行号作为 id
head -n $DATA_SIZE "$TEMP_FILE" | sort -n | awk '{print NR","$1}' >> "$BULK_CSV"

BULK_ACTUAL=$(tail -n +2 "$BULK_CSV" | wc -l)
echo "  ✓ 生成 $BULK_ACTUAL 行 → $BULK_CSV"

# =============================================
# Step 4: 后 N 个保持乱序 → 插入键文件
# =============================================
echo ""
echo "Step 4: 生成插入键文件 (后 N 个保持乱序)..."

echo "val" > "$INSERT_CSV"
# 取后 N 行（从第 N+1 行开始）
tail -n $DATA_SIZE "$TEMP_FILE" >> "$INSERT_CSV"

INSERT_ACTUAL=$(tail -n +2 "$INSERT_CSV" | wc -l)
echo "  ✓ 生成 $INSERT_ACTUAL 行 → $INSERT_CSV"

# =============================================
# Step 5: 复制批量加载文件 → 查询键文件
# =============================================
echo ""
echo "Step 5: 生成查询键文件 (从批量加载复制)..."

echo "val" > "$QUERY_CSV"
# 从 bulk_load 提取 val 列
tail -n +2 "$BULK_CSV" | cut -d',' -f2 >> "$QUERY_CSV"

QUERY_ACTUAL=$(tail -n +2 "$QUERY_CSV" | wc -l)
echo "  ✓ 生成 $QUERY_ACTUAL 行 → $QUERY_CSV"

# =============================================
# 清理临时文件
# =============================================
rm -f "$TEMP_FILE"

# =============================================
# 显示结果
# =============================================
echo ""
echo "=============================================="
echo "生成完成"
echo "=============================================="
echo ""
echo "批量加载文件: $BULK_CSV"
echo "  - 数据行数: $BULK_ACTUAL"
echo "  - 文件大小: $(du -h "$BULK_CSV" | cut -f1)"
echo "  - 格式: id,val (排序后的前 N 个)"
echo ""
echo "查询键文件: $QUERY_CSV"
echo "  - 数据行数: $QUERY_ACTUAL"
echo "  - 文件大小: $(du -h "$QUERY_CSV" | cut -f1)"
echo "  - 格式: val (与批量加载相同)"
echo ""
echo "插入键文件: $INSERT_CSV"
echo "  - 数据行数: $INSERT_ACTUAL"
echo "  - 文件大小: $(du -h "$INSERT_CSV" | cut -f1)"
echo "  - 格式: val (乱序的后 N 个)"

echo ""
echo "=============================================="
echo "预览文件内容"
echo "=============================================="
echo ""
echo "批量加载文件 (前5行，已排序):"
head -6 "$BULK_CSV"
echo "..."
echo ""
echo "查询键文件 (前5行):"
head -6 "$QUERY_CSV"
echo "..."
echo ""
echo "插入键文件 (前5行，乱序):"
head -6 "$INSERT_CSV"
echo "..."

echo ""
echo "=============================================="
echo "数据流程示意"
echo "=============================================="
echo ""
echo "原始 2N 数据: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]"
echo "      ↓ Shuffle"
echo "Shuffle 后:   [7, 2, 9, 4, 1, 6, 3, 8, 5, 10]"
echo "      ↓ 分割"
echo "前 N 个:      [7, 2, 9, 4, 1] → 排序 → [1, 2, 4, 7, 9] → bulk_load"
echo "后 N 个:      [6, 3, 8, 5, 10]         (保持乱序)     → insert_keys"
echo "查询键:       复制 bulk_load                          → query_keys"
