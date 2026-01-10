#!/bin/bash
# =============================================
# 对比测试两种 ALEX 配置
# =============================================

CONFIG_FILE="/code/neurdb-dev/dbengine/nr_kernel/nr_am/src/nram_storage/ALEX/alex_config.conf"
PG_CTL="/code/neurdb-dev/psql/bin/pg_ctl"
PG_DATA="/hdd9/benjamin/neurdb_data"
PG_LOG="/code/neurdb-dev/logfile"

# RL最优配置
CONFIG_OPTIMAL="# RL最优配置
expected_insert_frac=0.0
max_node_size=67108864
init_density=0.25
max_density=0.30
min_density=0.20
exp_search_iterations_weight=5.0
shifts_weight=0.56
node_lookups_weight=5.0
model_size_weight=1.0e-05
approximate_model=true
approximate_cost=false"

# 最差配置
CONFIG_WORST="# 最差配置
expected_insert_frac=0.0
max_node_size=4194304
init_density=0.66
max_density=0.90
min_density=0.61
exp_search_iterations_weight=34.3
shifts_weight=0.10
node_lookups_weight=5.0
model_size_weight=1.0e-08
approximate_model=true
approximate_cost=false"

echo "=============================================="
echo "测试1: RL最优配置 (64MB, 低密度)"
echo "=============================================="
echo "$CONFIG_OPTIMAL" > "$CONFIG_FILE"
echo "配置已写入:"
cat "$CONFIG_FILE"
echo ""
echo "重启数据库..."
$PG_CTL -D "$PG_DATA" -l "$PG_LOG" restart -w -t 60
sleep 3
echo "运行测试..."
./pgbench_compare_v3.sh 500000 2>&1 | tee /tmp/result_optimal.txt

echo ""
echo "=============================================="
echo "测试2: 最差配置 (4MB, 高密度)"
echo "=============================================="
echo "$CONFIG_WORST" > "$CONFIG_FILE"
echo "配置已写入:"
cat "$CONFIG_FILE"
echo ""
echo "重启数据库..."
$PG_CTL -D "$PG_DATA" -l "$PG_LOG" restart -w -t 60
sleep 3
echo "运行测试..."
./pgbench_compare_v3.sh 500000 2>&1 | tee /tmp/result_worst.txt

echo ""
echo "=============================================="
echo "结果对比"
echo "=============================================="
echo ""
echo "--- RL最优配置结果 ---"
grep -A5 "汇总统计" /tmp/result_optimal.txt | tail -4
echo ""
echo "--- 最差配置结果 ---"
grep -A5 "汇总统计" /tmp/result_worst.txt | tail -4

# 恢复最优配置
echo "$CONFIG_OPTIMAL" > "$CONFIG_FILE"
echo ""
echo "已恢复为RL最优配置"
