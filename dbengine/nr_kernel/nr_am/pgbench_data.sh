#!/bin/bash
# =============================================
# 生成 pgbench 测试数据文件
# =============================================
# Usage: ./pgbench_data.sh <data_size> <query_size> [insert_size]
#   data_size:   数据表大小 (必填)
#   query_size:  查询数量 (必填)
#   insert_size: 插入数量 (可选)
# Example:
#   ./pgbench_data.sh 1000000 100000
#   ./pgbench_data.sh 10000000 1000000 500000

# 检查参数
if [ $# -lt 2 ]; then
    echo "Usage: $0 <data_size> <query_size> [insert_size]"
    echo "Example: $0 1000000 100000"
    exit 1
fi

DATA_SIZE=$1
QUERY_SIZE=$2
INSERT_SIZE=${3:-0}

DATA_CSV="/tmp/covid_${DATA_SIZE}.csv"
QUERY_CSV="/tmp/covid_query_${QUERY_SIZE}.csv"
INSERT_CSV="/tmp/covid_insert_${INSERT_SIZE}.csv"

echo "=============================================="
echo "生成 pgbench 测试数据文件"
echo "=============================================="
echo "数据文件大小: $DATA_SIZE 行"
echo "查询文件大小: $QUERY_SIZE 行"
if [ "$INSERT_SIZE" -gt 0 ]; then
    echo "插入文件大小: $INSERT_SIZE 行"
fi
echo "=============================================="

# =============================================
# 生成主数据文件
# =============================================
echo ""
echo "Step 1: 生成主数据文件 $DATA_CSV ..."

if [ -f "$DATA_CSV" ]; then
    echo "文件已存在，是否覆盖? (y/n)"
    read -r answer
    if [ "$answer" != "y" ]; then
        echo "跳过生成主数据文件"
    else
        rm -f "$DATA_CSV"
    fi
fi

if [ ! -f "$DATA_CSV" ]; then
    echo "正在生成 $DATA_SIZE 行数据..."
    echo "id,val" > "$DATA_CSV"
    awk -v n=$DATA_SIZE 'BEGIN {
        srand();
        for (i = 1; i <= n; i++) {
            val = int(rand() * 9223372036854775807);
            printf "%d,%.0f\n", i, val;
            if (i % 100000 == 0) {
                print "已生成 " i " 行..." > "/dev/stderr";
            }
        }
    }' >> "$DATA_CSV"
    echo "完成: $(wc -l < "$DATA_CSV") 行"
fi

# =============================================
# 生成查询键文件
# =============================================
echo ""
echo "Step 2: 生成查询键文件 $QUERY_CSV ..."

if [ -f "$QUERY_CSV" ]; then
    echo "文件已存在，是否覆盖? (y/n)"
    read -r answer
    if [ "$answer" != "y" ]; then
        echo "跳过生成查询键文件"
    else
        rm -f "$QUERY_CSV"
    fi
fi

if [ ! -f "$QUERY_CSV" ]; then
    echo "正在从主数据文件随机抽取 $QUERY_SIZE 行..."
    head -1 "$DATA_CSV" > "$QUERY_CSV"
    tail -n +2 "$DATA_CSV" | shuf | head -n $QUERY_SIZE >> "$QUERY_CSV"
    echo "完成: $(wc -l < "$QUERY_CSV") 行"
fi

# =============================================
# 生成插入数据文件 (可选)
# =============================================
if [ "$INSERT_SIZE" -gt 0 ]; then
    echo ""
    echo "Step 3: 生成插入数据文件 $INSERT_CSV ..."

    if [ -f "$INSERT_CSV" ]; then
        echo "文件已存在，是否覆盖? (y/n)"
        read -r answer
        if [ "$answer" != "y" ]; then
            echo "跳过生成插入数据文件"
        else
            rm -f "$INSERT_CSV"
        fi
    fi

    if [ ! -f "$INSERT_CSV" ]; then
        echo "正在生成 $INSERT_SIZE 行插入数据..."
        # 插入数据的 id 从 DATA_SIZE+1 开始
        START_ID=$((DATA_SIZE + 1))
        echo "id,val" > "$INSERT_CSV"
        awk -v n=$INSERT_SIZE -v start=$START_ID 'BEGIN {
            srand();
            for (i = 0; i < n; i++) {
                val = int(rand() * 9223372036854775807);
                printf "%d,%.0f\n", (start + i), val;
                if ((i + 1) % 100000 == 0) {
                    print "已生成 " (i + 1) " 行..." > "/dev/stderr";
                }
            }
        }' >> "$INSERT_CSV"
        echo "完成: $(wc -l < "$INSERT_CSV") 行"
    fi
fi

# =============================================
# 显示文件信息
# =============================================
echo ""
echo "=============================================="
echo "生成完成"
echo "=============================================="
echo ""
echo "主数据文件: $DATA_CSV"
echo "  - 行数: $(wc -l < "$DATA_CSV")"
echo "  - 大小: $(du -h "$DATA_CSV" | cut -f1)"
echo ""
echo "查询键文件: $QUERY_CSV"
echo "  - 行数: $(wc -l < "$QUERY_CSV")"
echo "  - 大小: $(du -h "$QUERY_CSV" | cut -f1)"

if [ "$INSERT_SIZE" -gt 0 ] && [ -f "$INSERT_CSV" ]; then
    echo ""
    echo "插入数据文件: $INSERT_CSV"
    echo "  - 行数: $(wc -l < "$INSERT_CSV")"
    echo "  - 大小: $(du -h "$INSERT_CSV" | cut -f1)"
fi

echo ""
echo "=============================================="
echo "预览文件内容"
echo "=============================================="
echo ""
echo "主数据文件 (前5行):"
head -5 "$DATA_CSV"
echo "..."
echo ""
echo "查询键文件 (前5行):"
head -5 "$QUERY_CSV"
echo "..."

if [ "$INSERT_SIZE" -gt 0 ] && [ -f "$INSERT_CSV" ]; then
    echo ""
    echo "插入数据文件 (前5行):"
    head -5 "$INSERT_CSV"
    echo "..."
fi
