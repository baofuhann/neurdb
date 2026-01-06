# TPC-H 性能测试脚本

本目录包含用于 TPC-H 数据库性能基准测试的脚本。

## 脚本说明

| 脚本 | 说明 |
|------|------|
| `01_install_tpch.sh` | 下载、编译 TPC-H 工具并生成测试数据 |
| `02_load_data.sh` | 创建数据库表结构并导入数据 |
| `03_run_benchmark.sh` | 运行完整的 22 个查询性能测试 |
| `04_run_single_query.sh` | 运行单个查询并显示执行计划 |
| `05_cleanup.sh` | 清理测试数据库和文件 |

## 快速开始

```bash
# 1. 添加执行权限
chmod +x *.sh

# 2. 安装 TPC-H 并生成 1GB 数据
./01_install_tpch.sh 1

# 3. 导入数据到 PostgreSQL
./02_load_data.sh tpch_test neurdb localhost 5432

# 4. 运行性能测试
./03_run_benchmark.sh tpch_test neurdb localhost 5432 3
```

## 脚本参数

### 01_install_tpch.sh

```bash
./01_install_tpch.sh [scale_factor]
# scale_factor: 数据规模，默认 1 (约 1GB)
# 示例: ./01_install_tpch.sh 10  # 生成 10GB 数据
```

### 02_load_data.sh

```bash
./02_load_data.sh [db_name] [db_user] [db_host] [db_port]
# 默认值: tpch_test neurdb localhost 5432
```

### 03_run_benchmark.sh

```bash
./03_run_benchmark.sh [db_name] [db_user] [db_host] [db_port] [runs]
# runs: 每个查询运行次数，默认 3
```

### 04_run_single_query.sh

```bash
./04_run_single_query.sh <query_number> [db_name] [db_user] [db_host] [db_port]
# query_number: 1-22
# 示例: ./04_run_single_query.sh 6
```

## 目录结构

运行脚本后会生成以下目录：

```
tpch_scripts/
├── tpch-kit/          # TPC-H 工具源码和数据文件
│   └── dbgen/
│       ├── *.tbl      # 生成的数据文件
│       └── ...
├── queries/           # 生成的 22 个查询文件
│   ├── q1.sql
│   ├── q2.sql
│   └── ...
└── results/           # 测试结果
    ├── benchmark_*.csv
    └── summary_*.txt
```

## Scale Factor 参考

| Scale Factor | 数据量 | lineitem 行数 |
|--------------|--------|---------------|
| 0.1 | ~100MB | ~600K |
| 1 | ~1GB | ~6M |
| 10 | ~10GB | ~60M |
| 100 | ~100GB | ~600M |

## 注意事项

1. 确保 PostgreSQL 服务正在运行
2. 确保有足够的磁盘空间存储数据
3. 大规模数据 (SF>=10) 导入可能需要较长时间
4. 建议在测试前关闭其他消耗资源的应用
