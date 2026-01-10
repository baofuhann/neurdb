#!/bin/bash

# ==============================================
# 数据构造脚本 - 用于索引性能测试
# 将数据分为批量加载部分和插入测试部分
# ==============================================

# 配置参数
SOURCE_FILE="/hdd9/benjamin/SOSD/scripts/data/books_50m.csv"
OUTPUT_DIR="/tmp"
BULK_LOAD_COUNT=40000000      # 批量加载数据量
INSERT_TEST_COUNT=10000    # 插入测试数据量
SHUFFLE=true               # 是否随机打乱 (true/false)

# 输出文件
BULK_FILE="${OUTPUT_DIR}/books_bulk.csv"
INSERT_FILE="${OUTPUT_DIR}/books_insert.csv"

# ==============================================
# 解析命令行参数
# ==============================================
usage() {
    echo "用法: $0 [选项]"
    echo ""
    echo "选项:"
    echo "  -s, --source FILE      源数据文件 (默认: $SOURCE_FILE)"
    echo "  -o, --output DIR       输出目录 (默认: $OUTPUT_DIR)"
    echo "  -b, --bulk COUNT       批量加载数据量 (默认: $BULK_LOAD_COUNT)"
    echo "  -i, --insert COUNT     插入测试数据量 (默认: $INSERT_TEST_COUNT)"
    echo "  -r, --random           随机打乱数据"
    echo "  -h, --help             显示帮助"
    echo ""
    echo "示例:"
    echo "  $0                                    # 使用默认参数"
    echo "  $0 -b 800000 -i 200000                # 80万批量 + 20万插入"
    echo "  $0 -b 500000 -i 500000 --random       # 随机打乱后50/50划分"
    exit 1
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -s|--source) SOURCE_FILE="$2"; shift 2 ;;
        -o|--output) OUTPUT_DIR="$2"; shift 2 ;;
        -b|--bulk) BULK_LOAD_COUNT="$2"; shift 2 ;;
        -i|--insert) INSERT_TEST_COUNT="$2"; shift 2 ;;
        -r|--random) SHUFFLE=true; shift ;;
        -h|--help) usage ;;
        *) echo "未知选项: $1"; usage ;;
    esac
done

# 更新输出文件路径
BULK_FILE="${OUTPUT_DIR}/books_bulk.csv"
INSERT_FILE="${OUTPUT_DIR}/books_insert.csv"

# ==============================================
# 检查源文件
# ==============================================
if [[ ! -f "$SOURCE_FILE" ]]; then
    echo "错误: 源文件不存在: $SOURCE_FILE"
    exit 1
fi

TOTAL_LINES=$(tail -n +2 "$SOURCE_FILE" | wc -l)
REQUIRED=$((BULK_LOAD_COUNT + INSERT_TEST_COUNT))

echo "=============================================="
echo "数据构造脚本"
echo "=============================================="
echo "源文件: $SOURCE_FILE"
echo "源文件数据量: $TOTAL_LINES 条"
echo "批量加载: $BULK_LOAD_COUNT 条"
echo "插入测试: $INSERT_TEST_COUNT 条"
echo "总需求: $REQUIRED 条"
echo "随机打乱: $SHUFFLE"
echo "=============================================="

if [[ $TOTAL_LINES -lt $REQUIRED ]]; then
    echo "警告: 源文件数据量不足 ($TOTAL_LINES < $REQUIRED)"
    BULK_LOAD_COUNT=$((TOTAL_LINES * 9 / 10))
    INSERT_TEST_COUNT=$((TOTAL_LINES - BULK_LOAD_COUNT))
    echo "调整为: 批量加载 $BULK_LOAD_COUNT 条, 插入测试 $INSERT_TEST_COUNT 条"
fi

# ==============================================
# 构造数据
# ==============================================
mkdir -p "$OUTPUT_DIR"

# 获取 header
HEADER=$(head -1 "$SOURCE_FILE")

echo ""
echo "正在构造数据..."

if [[ "$SHUFFLE" == "true" ]]; then
    echo "  - 随机抽取数据中..."
    TEMP_SHUFFLED=$(mktemp)
    TEMP_BULK=$(mktemp)
    TEMP_INSERT=$(mktemp)

    # 随机打乱
    tail -n +2 "$SOURCE_FILE" | shuf > "$TEMP_SHUFFLED"

    # 抽取后按第一列(id)排序
    echo "  - 对批量加载数据排序..."
    head -n "$BULK_LOAD_COUNT" "$TEMP_SHUFFLED" | sort -t',' -k1 -n > "$TEMP_BULK"

    echo "  - 对插入测试数据排序..."
    tail -n +"$((BULK_LOAD_COUNT + 1))" "$TEMP_SHUFFLED" | head -n "$INSERT_TEST_COUNT" | sort -t',' -k1 -n > "$TEMP_INSERT"

    echo "$HEADER" > "$BULK_FILE"
    cat "$TEMP_BULK" >> "$BULK_FILE"

    echo "$HEADER" > "$INSERT_FILE"
    cat "$TEMP_INSERT" >> "$INSERT_FILE"

    rm -f "$TEMP_SHUFFLED" "$TEMP_BULK" "$TEMP_INSERT"
else
    echo "  - 顺序划分数据..."
    echo "$HEADER" > "$BULK_FILE"
    tail -n +2 "$SOURCE_FILE" | head -n "$BULK_LOAD_COUNT" >> "$BULK_FILE"

    echo "$HEADER" > "$INSERT_FILE"
    tail -n +2 "$SOURCE_FILE" | tail -n +"$((BULK_LOAD_COUNT + 1))" | head -n "$INSERT_TEST_COUNT" >> "$INSERT_FILE"
fi

# ==============================================
# 验证结果
# ==============================================
BULK_ACTUAL=$(($(wc -l < "$BULK_FILE") - 1))
INSERT_ACTUAL=$(($(wc -l < "$INSERT_FILE") - 1))

echo ""
echo "=============================================="
echo "构造完成!"
echo "=============================================="
echo "批量加载文件: $BULK_FILE ($BULK_ACTUAL 条)"
echo "插入测试文件: $INSERT_FILE ($INSERT_ACTUAL 条)"
echo ""
echo "文件大小:"
ls -lh "$BULK_FILE" "$INSERT_FILE" 2>/dev/null | awk '{print "  " $NF ": " $5}'
echo ""
echo "使用示例:"
echo "  # 批量加载"
echo "  psql -d neurdb -c \"\\copy books FROM '$BULK_FILE' CSV HEADER;\""
echo "  # 插入测试"
echo "  psql -d neurdb -c \"\\copy books_insert FROM '$INSERT_FILE' CSV HEADER;\""
echo "=============================================="
