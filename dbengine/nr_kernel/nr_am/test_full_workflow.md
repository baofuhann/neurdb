# NRINDEX vs BTREE 性能测试完整流程

## 1. 数据准备

### 1.1 数据来源

使用 SOSD (Search On Sorted Data) 基准测试数据集：
- 文件：`osm_cellids_800M_uint64`
- 位置：`/hdd9/benjamin/SOSD/scripts/data/`
- 数据量：8 亿条 uint64 整数

### 1.2 数据处理脚本

创建脚本 `sosd_sort_top.py`：

```python
#!/usr/bin/env python3
"""
读取 SOSD 数据集，排序后取前 N 个 key 输出 CSV
"""

import struct
import numpy as np
import sys
import os

def main():
    input_file = "osm_cellids_800M_uint64"
    output_file = "osm_200M_sorted.csv"
    top_n = 200_000_000  # 前 2 亿

    print(f"输入文件: {input_file}")
    print(f"输出文件: {output_file}")
    print(f"取前 {top_n:,} 个 key")
    print()

    # 读取 SOSD 文件
    print("Step 1: 读取数据...")
    with open(input_file, 'rb') as f:
        # 读取记录数（前 8 字节）
        count_data = f.read(8)
        total_count = struct.unpack('<Q', count_data)[0]
        print(f"  文件总记录数: {total_count:,}")

        # 读取所有数据到 numpy 数组
        print(f"  读取数据到内存...")
        data = np.fromfile(f, dtype=np.uint64, count=total_count)
        print(f"  实际读取: {len(data):,} 条")

    # 排序
    print()
    print("Step 2: 排序...")
    data.sort()
    print("  排序完成")

    # 取前 N 个
    print()
    print(f"Step 3: 取前 {top_n:,} 个...")
    top_data = data[:top_n]
    print(f"  选取完成: {len(top_data):,} 条")

    # 输出 CSV
    print()
    print("Step 4: 输出 CSV...")
    with open(output_file, 'w') as f:
        f.write("id,val\n")
        for i, val in enumerate(top_data, 1):
            f.write(f"{i},{val}\n")
            if i % 10_000_000 == 0:
                print(f"  已写入 {i:,} 条...")

    print()
    print(f"完成！输出文件: {output_file}")
    print(f"文件大小: {os.path.getsize(output_file) / 1024 / 1024:.2f} MB")

if __name__ == '__main__':
    main()
```

### 1.3 执行数据处理

```bash
cd /hdd9/benjamin/SOSD/scripts/data
python sosd_sort_top.py
```

输出结果：
```
输入文件: osm_cellids_800M_uint64
输出文件: osm_200M_sorted.csv
取前 200,000,000 个 key

Step 1: 读取数据...
  文件总记录数: 800,000,000
  读取数据到内存...
  实际读取: 800,000,000 条

Step 2: 排序...
  排序完成

Step 3: 取前 200,000,000 个...
  选取完成: 200,000,000 条

Step 4: 输出 CSV...
  已写入 10,000,000 条...
  已写入 20,000,000 条...
  ...
  已写入 200,000,000 条...

完成！输出文件: osm_200M_sorted.csv
文件大小: 5591.73 MB
```

### 1.4 数据格式

输出 CSV 文件格式：
```csv
id,val
1,33246697004540789
2,33253772415041913
3,33722134959521311
...
```

- `id`: 行号（1 到 200,000,000）
- `val`: 排序后的 uint64 值（升序）

## 2. 导入 PostgreSQL

### 2.1 创建表并导入数据

```bash
/code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb << 'EOF'
-- 创建主表
DROP TABLE IF EXISTS osm CASCADE;
CREATE TABLE osm (id INT PRIMARY KEY, val BIGINT);

-- 导入数据
\copy osm FROM '/hdd9/benjamin/SOSD/scripts/data/osm_200M_sorted.csv' CSV HEADER;

-- 验证数据量
SELECT COUNT(*) FROM osm;
EOF
```

### 2.2 创建查询键表

```bash
/code/neurdb-dev/psql/bin/psql -h 127.0.0.1 -d neurdb << 'EOF'
-- 从主表随机抽取 100 万个键作为查询键
DROP TABLE IF EXISTS query_keys;
CREATE TABLE query_keys (val BIGINT);
INSERT INTO query_keys SELECT val FROM osm ORDER BY RANDOM() LIMIT 1000000;
SELECT COUNT(*) FROM query_keys;
EOF
```

## 3. 性能测试

### 3.1 测试脚本

使用 `pgbench_point_query.sh` 进行测试：

```bash
cd /code/neurdb-dev/dbengine/nr_kernel/nr_am
./pgbench_point_query.sh
```

### 3.2 测试流程

1. **检查表是否存在**：covid, query_keys
2. **显示数据量**：统计各表行数
3. **创建测试表**：covid_nrindex, covid_btree（仅在不存在时创建）
4. **重建索引**：每次测试前删除并重新创建索引
5. **准备查询键表**：qk_idx
6. **测试 NRINDEX**：pgbench 点查询 60 秒
7. **测试 BTREE**：pgbench 点查询 60 秒
8. **结果对比**：输出 TPS 和延迟对比

### 3.3 测试参数

```bash
CLIENTS=64          # 并发连接数
THREADS=10          # 线程数
DURATION=60         # 测试时长(秒)
PROGRESS=5          # 进度输出间隔(秒)
```

### 3.4 测试 SQL

```sql
SET enable_seqscan = off;
SET max_parallel_workers_per_gather = 0;
\set kid random(1, 1000000)
SELECT * FROM covid_nrindex WHERE val = (SELECT val FROM qk_idx WHERE id = :kid) LIMIT 1;
```

## 4. 预期输出

```
==============================================
测试结果对比
==============================================

索引创建时间:
  NRINDEX: xxxms
  BTREE:   xxxms

索引       | TPS             | 平均延迟(ms)
-----------+-----------------+---------------
NRINDEX    | xxxx            | x.xxx
BTREE      | xxxx            | x.xxx

NRINDEX 相比 BTREE 提升: x.xxx
```

## 5. 相关文件

| 文件 | 说明 |
|------|------|
| `/hdd9/benjamin/SOSD/scripts/data/osm_cellids_800M_uint64` | 原始 SOSD 数据集 |
| `/hdd9/benjamin/SOSD/scripts/data/sosd_sort_top.py` | 数据处理脚本 |
| `/hdd9/benjamin/SOSD/scripts/data/osm_200M_sorted.csv` | 处理后的 CSV 文件 |
| `/code/neurdb-dev/dbengine/nr_kernel/nr_am/pgbench_point_query.sh` | 性能测试脚本 |
| `/code/neurdb-dev/dbengine/nr_kernel/nr_am/benchmark_all_threads.sh` | 多线程测试脚本 |
| `/code/neurdb-dev/dbengine/nr_kernel/nr_am/benchmark_all_threads_pgbench.sh` | pgbench 多线程测试脚本 |
