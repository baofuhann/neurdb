#!/bin/bash
# TPC-H 安装和数据生成脚本
# 在 Docker 容器内执行

set -e

TPCH_DIR="/hdd9/benjamin/tpch-kit"
SCALE_FACTOR=${1:-1}  # 默认 1GB，可通过参数指定

# echo "===== TPC-H 安装脚本 (Docker) ====="
# echo "Scale Factor: $SCALE_FACTOR (数据量约 ${SCALE_FACTOR}GB)"

# # 1. 检查 tpch-kit 是否存在
# if [ ! -d "$TPCH_DIR" ]; then
#     echo "错误: tpch-kit 目录不存在: $TPCH_DIR"
#     echo "请先克隆: git clone https://github.com/gregrahn/tpch-kit.git $TPCH_DIR"
#     exit 1
# else
#     echo "tpch-kit 目录: $TPCH_DIR"
# fi

# 2. 编译 dbgen
echo "编译 dbgen..."
cd "$TPCH_DIR/dbgen"
# make clean 2>/dev/null || true
# make MACHINE=LINUX DATABASE=POSTGRESQL

# 3. 生成数据
echo "生成测试数据 (Scale Factor = $SCALE_FACTOR)..."
./dbgen -s $SCALE_FACTOR -f

# 4. 处理 tbl 文件（去掉行末的 |）
echo "处理 tbl 文件..."
for f in *.tbl; do
    sed -i 's/|$//' "$f"
done

# 5. 生成查询文件
echo "生成查询文件..."
mkdir -p "$TPCH_DIR/queries"
export DSS_QUERY="$TPCH_DIR/dbgen/queries"
for i in $(seq 1 22); do
    ./qgen $i > "$TPCH_DIR/queries/q$i.sql" 2>/dev/null || true
done

echo ""
echo "===== 安装完成 ====="
echo "数据文件位置: $TPCH_DIR/dbgen/*.tbl"
echo "查询文件位置: $TPCH_DIR/queries/"
echo ""
echo "下一步: 运行 ./02_load_data.sh 导入数据"
