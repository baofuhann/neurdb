# NeurDB 项目笔记

## 一、项目概述

NeurDB 是一个**基于 AI 驱动的自治数据系统**，构建于 PostgreSQL 16.3 之上。它将人工智能能力无缝集成到关系数据库管理系统中，使用户可以直接在数据库表上进行模型训练、微调和推理操作。

---

## 二、项目结构

```
neurdb-dev/
├── dbengine/              # 基于 PostgreSQL 的数据库引擎及扩展
├── aiengine/              # AI 运行时和优化服务器
├── api/python/            # Python 客户端 API
├── doc/                   # 文档
├── Dockerfile.cpu/.cuda11 # Docker 构建文件
├── build.sh               # 构建脚本
└── docker-init.sh         # Docker 初始化脚本
```

---

## 三、核心组件

### 3.1 数据库引擎 (`/dbengine/`)

**基础**: 修改后的 PostgreSQL 16.3

**关键子模块**:

| 模块 | 功能 |
|------|------|
| `nr_kernel/nr_pipeline/` | 主要神经网络数据管道扩展，实现 `nr_train()`, `nr_inference()`, `nr_finetune()` 等 SQL 函数 |
| `nr_kernel/nr_ext/` | 自定义执行器和规划器修改，模型预测逻辑 |
| `nr_kernel/nr_am/` | NRAM (Neural Relational Access Method)，基于 RocksDB 的高性能存储引擎 |

### 3.2 AI 引擎 (`/aiengine/`)

**目的**: 独立的 AI 服务器，提供模型分析和机器学习能力

| 子目录 | 功能 |
|--------|------|
| `runtime/` | 基于 Quart + Hypercorn 的异步 WebSocket 服务器（端口 8090） |
| `runtime/model/` | 深度学习模型架构（ARMNET、MLP分类器等） |
| `runtime/cache/` | 异步队列数据缓存系统 |
| `runtime/dataloader/` | LibSVM 格式数据加载器 |
| `pgext/nr_modelmanager/` | C++ PyTorch 集成，数据库内模型管理 |
| `query_opt/` | 学习型查询优化器 |

### 3.3 Python API (`/api/python/`)

**包名**: `neurdb`

**主要功能**：
- **模型持久化**: 将 PyTorch 模型存储到数据库
- **模型加载**: 从数据库加载已训练模型
- **模型更新**: 按层级粒度更新模型

---

## 四、组件交互架构

```
┌─────────────────────────────────────────────────────────┐
│                   用户应用 (psql)                        │
└────────────────────────┬────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────┐
│              PostgreSQL 16.3 (已修改)                   │
│  ┌─────────────────────────────────────────────────┐   │
│  │  nr_pipeline (SQL 接口层)                        │   │
│  │  - SQL 解析 (PREDICT VALUE OF 语法)             │   │
│  │  - 数据批处理 (LibSVM 格式)                      │   │
│  │  - WebSocket 客户端                             │   │
│  └─────────────────────────────────────────────────┘   │
│  ┌─────────────────────────────────────────────────┐   │
│  │  nr_ext (自定义执行器)                          │   │
│  │  nr_modelmanager (模型序列化)                   │   │
│  │  NRAM (RocksDB 存储引擎)                        │   │
│  └─────────────────────────────────────────────────┘   │
└────────────────────────┬────────────────────────────────┘
                         │ WebSocket (端口 8090)
                         ▼
┌─────────────────────────────────────────────────────────┐
│            NeurDB AI 引擎 (Python)                      │
│  ┌─────────────────────────────────────────────────┐   │
│  │  WebSocket 处理器 → Setup 编排 → 模型训练/推理  │   │
│  │  支持模型: ARMNET (注意力网络), MLP 分类器      │   │
│  │  数据缓存 + 流式数据加载器                      │   │
│  └─────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

---

## 五、核心工作流程

### 5.1 训练流程

```
用户 SQL: SELECT nr_train(...)
    ↓
PostgreSQL 解析并提取特征/标签
    ↓
WebSocket 发送 TRAIN 任务到 AI 引擎
    ↓
AI 引擎构建/加载模型 (ARMNET/MLP)
    ↓
流式接收数据并用 PyTorch 训练
    ↓
序列化模型存储到数据库
    ↓
返回 model_id 给用户
```

### 5.2 推理流程

```
用户 SQL: SELECT * FROM nr_inference(model_id, table, ...)
    ↓
PostgreSQL 批量查询数据
    ↓
WebSocket 发送 INFERENCE 任务
    ↓
AI 引擎加载模型并执行推理
    ↓
解码结果为类别标签
    ↓
返回 SETOF RECORD 到 PostgreSQL
```

---

## 六、关键技术栈

| 组件 | 技术 | 用途 |
|------|------|------|
| 数据库 | PostgreSQL 16.3 | 核心 DBMS |
| 内核扩展 | C + CMake | 自定义执行器/规划器 |
| AI 运行时 | Python 3.8+ | ML 框架 |
| Web 框架 | Quart + Hypercorn | 异步 WebSocket 服务 |
| ML 框架 | PyTorch | 深度学习模型 |
| 通信协议 | WebSocket (JSON) | DB ↔ AI 引擎 |
| 存储引擎 | RocksDB 10.3.0 | 高性能访问方法 |
| 数据格式 | LibSVM | ML 数据交换 |
| 容器化 | Docker | 开发/部署 |

---

## 七、项目核心价值

NeurDB 的设计目标是将**自治 AI 能力直接嵌入数据库**，消除数据迁移成本：

1. **数据库内模型训练** - 无需 ETL，直接在表上训练 ML 模型
2. **数据库内推理** - 预测结果作为表行返回
3. **模型微调** - 层级粒度的模型更新
4. **自治数据管理** - 学习型查询优化、自适应访问方法

---

## 八、代码规模

| 组件 | 代码行数 | 语言 |
|------|----------|------|
| 数据库引擎 (nr_kernel) | ~3,258 | C |
| AI 运行时 | ~2,619 | Python |
| Python API | ~832 | Python |
| **总计** | **~6,700+** | 混合 |

---

# 执行记录

## 1. 切换到索引开发分支

当本地有未提交的修改时，需要先暂存：

```bash
# 暂存本地修改
git stash

# 切换分支
git checkout dev-index

# 如需恢复修改
git stash pop
```

---

## 2. 重新编译 nr_kernel

### 2.1 编译步骤

```bash
cd /code/neurdb-dev/dbengine/nr_kernel
sudo make clean
sudo make install
```

### 2.2 重启数据库

```bash
/code/neurdb-dev/psql/bin/pg_ctl restart -D /code/neurdb-dev/psql/data -l /code/neurdb-dev/logfile
```

---

## 3. 常见问题排查

### 3.1 数据库启动失败

**查看日志**：
```bash
tail -50 /code/neurdb-dev/logfile
```

### 3.2 扩展库找不到问题

**错误信息**：
```
FATAL: could not access file "pg_neurstore": No such file or directory
```

**原因**：PostgreSQL 期望 `pg_neurstore.so`，但实际文件是 `libpg_neurstore.so`

**解决方案**：创建符号链接
```bash
sudo ln -sf /code/neurdb-dev/psql/lib/libpg_neurstore.so /code/neurdb-dev/psql/lib/pg_neurstore.so
sudo ln -sf /code/neurdb-dev/psql/lib/postgresql/libpg_neurstore.so /code/neurdb-dev/psql/lib/postgresql/pg_neurstore.so
```

### 3.3 CMake 版本过低

**错误信息**：
```
CMake 3.21 or higher is required. You are running version 3.10.2
```

**解决方案**：升级 CMake
```bash
cd /tmp
wget https://github.com/Kitware/CMake/releases/download/v3.28.1/cmake-3.28.1-linux-x86_64.tar.gz
sudo tar -xzf cmake-3.28.1-linux-x86_64.tar.gz -C /opt
sudo ln -sf /opt/cmake-3.28.1-linux-x86_64/bin/cmake /usr/local/bin/cmake
```

### 3.4 GCC 版本过低 (filesystem 头文件找不到)

**错误信息**：
```
fatal error: filesystem: No such file or directory
```

**解决方案**：升级 GCC 到 11+
```bash
sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test
sudo apt-get install -y gcc-11 g++-11
sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-11 110 --slave /usr/bin/g++ g++ /usr/bin/g++-11
```

---

## 4. SQL 操作命令

### 4.1 连接数据库

```bash
# 方式一：直接连接到 neurdb 数据库
/code/neurdb-dev/psql/bin/psql -h localhost -U neurdb

# 方式二：指定数据库连接
/code/neurdb-dev/psql/bin/psql -h localhost -U neurdb -d neurdb

# 方式三：设置别名后使用（可添加到 ~/.bashrc）
alias psql='/code/neurdb-dev/psql/bin/psql -h localhost -U neurdb'
psql
```

### 4.2 数据库管理命令

```sql
-- 查看所有数据库
\l

-- 切换数据库
\c database_name

-- 查看当前数据库
SELECT current_database();

-- 创建新数据库
CREATE DATABASE mydb;

-- 删除数据库
DROP DATABASE mydb;
```

### 4.3 表操作

```sql
-- 查看所有表
\dt

-- 查看表结构
\d table_name

-- 创建表（普通 PostgreSQL 表）
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(255) UNIQUE,
    age INT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 创建表（使用 NRAM 存储引擎）
CREATE TABLE users_nram (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    age INT
) USING nram;

-- 删除表
DROP TABLE table_name;

-- 清空表
TRUNCATE TABLE table_name;
```

### 4.4 数据操作 (CRUD)

```sql
-- 插入数据
INSERT INTO users (name, email, age) VALUES ('Alice', 'alice@example.com', 25);
INSERT INTO users (name, email, age) VALUES ('Bob', 'bob@example.com', 30);

-- 批量插入
INSERT INTO users (name, email, age) VALUES
    ('Charlie', 'charlie@example.com', 28),
    ('David', 'david@example.com', 35);

-- 查询数据
SELECT * FROM users;
SELECT name, age FROM users WHERE age > 25;
SELECT * FROM users ORDER BY age DESC LIMIT 10;

-- 更新数据
UPDATE users SET age = 26 WHERE name = 'Alice';

-- 删除数据
DELETE FROM users WHERE name = 'Bob';
```

### 4.5 扩展管理

```sql
-- 查看可用扩展
SELECT name, default_version, comment
FROM pg_available_extensions
WHERE name LIKE '%nr%' OR name LIKE '%nram%' OR name LIKE '%neur%';

-- 查看已安装扩展
\dx

-- 查看已预加载的库
SHOW shared_preload_libraries;

-- 安装扩展
CREATE EXTENSION nr_pipeline;
CREATE EXTENSION nram;

-- 卸载扩展
DROP EXTENSION extension_name;
```

### 4.6 当前可用的 NeurDB 扩展

| 扩展名 | 版本 | 说明 |
|--------|------|------|
| `nr_ext` | 1.0.0 | NeurDB 内核扩展 |
| `nram` | 1.0 | 基于 RocksDB 的表访问方法 |
| `pg_neurstore` | 1.0.0 | NeurDB 存储扩展 |
| `nr_pipeline` | 1.0.0 | 数据预处理管道 |

### 4.7 常用 psql 快捷命令

| 命令 | 说明 |
|------|------|
| `\l` | 列出所有数据库 |
| `\c dbname` | 切换到指定数据库 |
| `\dt` | 列出当前数据库的所有表 |
| `\d tablename` | 显示表结构 |
| `\dx` | 列出已安装的扩展 |
| `\df` | 列出所有函数 |
| `\du` | 列出所有用户/角色 |
| `\timing` | 开启/关闭查询计时 |
| `\x` | 切换扩展显示模式（竖向显示） |
| `\q` | 退出 psql |
| `\?` | 显示 psql 命令帮助 |
| `\h SQL命令` | 显示 SQL 命令帮助 |

### 4.8 实用查询示例

```sql
-- 查看表大小
SELECT pg_size_pretty(pg_total_relation_size('table_name'));

-- 查看数据库大小
SELECT pg_size_pretty(pg_database_size('neurdb'));

-- 查看当前连接
SELECT * FROM pg_stat_activity;

-- 查看表的行数（估算）
SELECT relname, reltuples::bigint AS row_count
FROM pg_class
WHERE relkind = 'r';

-- 查看索引
\di

-- 执行 SQL 文件
\i /path/to/script.sql
```

### 4.9 日志输出命令
```sql
-- 关闭 NOTICE 及以下级别的消息
SET client_min_messages = WARNING;

-- 或只显示错误
SET client_min_messages = ERROR;
  
```
---

## 5. B-tree 索引测试

### 5.1 创建测试表并插入数据

```sql
-- 创建测试表
DROP TABLE IF EXISTS test_btree;
CREATE TABLE test_btree (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100),
    value INT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- 插入 1000 条测试数据
INSERT INTO test_btree (name, value)
SELECT
    'item_' || i,
    (random() * 10000)::INT
FROM generate_series(1, 1000) AS i;

-- 验证数据
SELECT COUNT(*) FROM test_btree;
```

### 5.2 无索引时的查询（全表扫描）

```sql
EXPLAIN ANALYZE SELECT * FROM test_btree WHERE value = 5000;
```

**结果**：`Seq Scan`（顺序扫描，需要扫描所有行）

### 5.3 创建 B-tree 索引

```sql
-- 创建索引
CREATE INDEX idx_btree_value ON test_btree USING btree (value);

-- 查看表的索引
SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'test_btree';
```

### 5.4 有索引时的查询

```sql
-- 精确匹配查询
EXPLAIN ANALYZE SELECT * FROM test_btree WHERE value = 5000;
-- 结果：Index Scan（索引扫描）

-- 范围查询
EXPLAIN ANALYZE SELECT * FROM test_btree WHERE value BETWEEN 1000 AND 2000;
-- 结果：Bitmap Index Scan（位图索引扫描）

-- 排序查询（索引可加速排序）
EXPLAIN ANALYZE SELECT * FROM test_btree ORDER BY value LIMIT 10;
-- 结果：Index Scan（直接使用索引，无需额外排序）
```

### 5.5 EXPLAIN ANALYZE 与 QUERY PLAN 详解

#### 什么是 QUERY PLAN（查询计划）？

**QUERY PLAN** 是 PostgreSQL 执行 SQL 查询的**执行方案**，类似导航软件的行车路线。

```sql
-- 只看计划（不执行查询）
EXPLAIN SELECT * FROM test_btree WHERE value = 5000;

-- 看计划 + 实际执行数据（推荐）
EXPLAIN ANALYZE SELECT * FROM test_btree WHERE value = 5000;
```

#### 执行计划示例

```
                                              QUERY PLAN
------------------------------------------------------------------------------------------------------
 Index Scan using idx_btree_value on test_btree  (cost=0.28..8.29 rows=1 width=24) (actual time=0.011..0.012 rows=0 loops=1)
   Index Cond: (value = 5000)
 Planning Time: 1.694 ms
 Execution Time: 0.088 ms
```

#### 逐项解读

**第1行：扫描方式**

| 部分 | 含义 |
|------|------|
| `Index Scan` | 使用**索引扫描**（不是全表扫描 Seq Scan） |
| `using idx_btree_value` | 使用的索引名称 |
| `on test_btree` | 扫描的表名 |

**成本估算 (cost)**

```
cost=0.28..8.29
```

| 值 | 含义 |
|------|------|
| `0.28` | **启动成本**：返回第一行前的代价 |
| `8.29` | **总成本**：返回所有行的代价（数值越小越好） |

**行估算**

```
rows=1 width=24
```

| 值 | 含义 |
|------|------|
| `rows=1` | **预估**返回 1 行 |
| `width=24` | 每行平均 24 字节 |

**实际执行 (actual)**

```
actual time=0.011..0.012 rows=0 loops=1
```

| 值 | 含义 |
|------|------|
| `time=0.011..0.012` | 实际耗时（毫秒） |
| `rows=0` | **实际**返回 0 行 |
| `loops=1` | 执行了 1 次 |

**索引条件**

```
Index Cond: (value = 5000)
```

表示使用索引查找 `value = 5000` 的记录。

**时间统计**

| 指标 | 含义 |
|------|------|
| `Planning Time` | 生成执行计划的时间 |
| `Execution Time` | 实际执行查询的时间 |

#### 常见扫描类型对比

| 扫描类型 | 说明 | 性能 |
|----------|------|------|
| `Seq Scan` | 全表扫描，逐行检查 | 慢 ❌ |
| `Index Scan` | 索引扫描，直接定位 | 快 ✅ |
| `Index Only Scan` | 仅索引扫描，不回表 | 最快 ✅✅ |
| `Bitmap Index Scan` | 位图索引扫描，适合范围查询 | 快 ✅ |

#### 使用场景

| 场景 | 说明 |
|------|------|
| **分析性能** | 看查询是否使用了索引 |
| **优化查询** | 找出慢查询的原因 |
| **调试问题** | 理解 PostgreSQL 如何执行 SQL |

### 5.6 索引管理命令

```sql
-- 查看所有索引
\di

-- 查看指定表的索引, 例如 匹配以 test_btree 开头的索引
\di test_btree*

-- 删除索引
DROP INDEX idx_btree_value;

-- 重建索引
REINDEX INDEX idx_btree_value;

-- 查看索引大小
SELECT pg_size_pretty(pg_relation_size('idx_btree_value'));
```

### 查询表的索引：
```sql
SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'test_btree';
```

结果示例：
```
    indexname    |                                 indexdef
-----------------+---------------------------------------------------------------------------
 test_btree_pkey | CREATE UNIQUE INDEX test_btree_pkey ON public.test_btree USING btree (id)
 idx_btree_value | CREATE INDEX idx_btree_value ON public.test_btree USING btree (value)
```

**索引解读**：

| 索引名 | 类型 | 索引列 | 说明 |
|--------|------|--------|------|
| `test_btree_pkey` | UNIQUE B-tree | id | 主键自动创建，不允许重复 |
| `idx_btree_value` | B-tree | value | 手动创建，允许重复值 |

**索引定义关键词**：

| 关键词 | 含义 |
|--------|------|
| `UNIQUE` | 唯一索引，不允许重复值 |
| `ON public.test_btree` | 在 public 模式下的 test_btree 表上 |
| `USING btree` | 使用 B-tree 索引类型 |
| `(column)` | 索引建立在哪个列上 |

---

## 6. PostgreSQL 数据库基础知识

### 6.1 默认数据库说明

执行 `\l` 查看所有数据库：

| 数据库 | 说明 |
|--------|------|
| `neurdb` | 主数据库，用于实际工作（NeurDB 创建的） |
| `template0` | 系统模板数据库（只读，不可修改） |
| `template1` | 默认模板数据库（创建新数据库时的模板） |

### 6.2 数据库列表各列含义

| 列名 | 含义 | 示例值 |
|------|------|--------|
| `Name` | 数据库名称 | neurdb |
| `Owner` | 所有者 | neurdb（用户） |
| `Encoding` | 字符编码 | UTF8 |
| `Locale Provider` | 区域设置提供者 | libc |
| `Collate` | 排序规则 | en_US.UTF-8 |
| `Ctype` | 字符分类 | en_US.UTF-8 |
| `Access privileges` | 访问权限 | 默认 |

### 6.3 数据库关系图

```
template0  ──(只读备份)──→  系统级模板，用于恢复
     │
template1  ──(可定制)────→  CREATE DATABASE 的默认模板
     │
     └──────────────────→  neurdb  ──→  你的工作数据库
```

> **注意**：`template0` 和 `template1` 是系统数据库，不要修改。所有操作应在 `neurdb` 中进行。

---

## 7. 索引扩展开发指南

### 7.1 查看可用索引类型

```sql
-- 查询所有可用的索引访问方法
SELECT amname FROM pg_am WHERE amtype = 'i';
```

**PostgreSQL 内置索引类型**：

| 索引类型 | 全称 | 适用场景 |
|----------|------|----------|
| `btree` | B-Tree | 默认类型，适合 `=`, `<`, `>`, `BETWEEN`, `ORDER BY` |
| `hash` | Hash | 仅适合 `=` 等值查询 |
| `gist` | Generalized Search Tree | 几何数据、全文搜索、范围类型 |
| `gin` | Generalized Inverted Index | 数组、全文搜索、JSONB |
| `spgist` | Space-Partitioned GiST | 电话号码、IP地址等非平衡数据 |
| `brin` | Block Range Index | 超大表、数据有序排列（如时间序列） |

**NeurDB 自定义索引**：

| 索引类型 | 存储后端 | 特点 |
|----------|----------|------|
| `nrindex` | std::map（内存） | NeurDB 自定义索引，基于内存存储 |

### 7.2 索引扩展代码位置

```
dbengine/nr_kernel/nr_am/
├── src/
│   ├── nrindex.c              # 索引访问方法主实现
│   ├── nrindex.h              # 公共接口声明
│   ├── nrindex_access/
│   │   ├── nrindex_kv.c       # 索引键值实现
│   │   └── nrindex_kv.h       # 索引键值结构定义
│   └── nram_storage/
│       ├── indexengine.cpp    # C++ 索引存储引擎（基于 std::map）
│       └── indexengine.h      # C 接口封装
├── sql/
│   └── nram--1.0.sql          # SQL 扩展定义（注册索引访问方法）
├── Makefile
├── nram.control               # 扩展元数据
├── NRINDEX_DESIGN.md          # 索引设计文档
├── INDEXENGINE_ARCHITECTURE.md # 索引引擎架构文档
└── DIRECT_INDEX_OPERATIONS.md  # 直接索引操作文档
```

### 7.3 添加新索引扩展的步骤

#### 步骤 1：创建索引核心文件

在 `nr_am/src/` 下创建头文件：

```c
// my_index.h
typedef struct MyIndexKeyData {
    Oid indexOid;                           // 索引 OID
    uint32 key_size;                        // 键大小
    char key_data[FLEXIBLE_ARRAY_MEMBER];   // 键数据
} MyIndexKeyData;

typedef struct MyIndexValueData {
    ItemPointerData heap_tid;   // 堆元组引用
    TransactionId xact_id;      // 事务 ID
    uint16 flags;               // 标志位
} MyIndexValueData;
```

创建实现文件：

```c
// my_index.c
#include "my_index.h"

// 构建索引
IndexBuildResult *myindex_build(Relation heap, Relation index, ...);

// 插入索引项
bool myindex_insert(Relation rel, Datum *values, ...);

// 开始扫描
IndexScanDesc myindex_beginscan(Relation rel, ...);

// 获取下一个元组
bool myindex_gettuple(IndexScanDesc scan, ScanDirection dir);

// 结束扫描
void myindex_endscan(IndexScanDesc scan);
```

#### 步骤 2：注册索引访问方法

在 `sql/nram--1.0.sql` 中添加：

```sql
-- 创建索引访问方法处理函数
CREATE FUNCTION myindex_handler(internal) RETURNS index_am_handler
AS 'MODULE_PATHNAME', 'myindex_handler'
LANGUAGE C;

-- 注册索引访问方法
CREATE ACCESS METHOD myindex TYPE INDEX HANDLER myindex_handler;

-- 创建操作符类（定义支持的操作符）
CREATE OPERATOR CLASS myindex_int4_ops
DEFAULT FOR TYPE int4 USING myindex AS
    OPERATOR 1 < ,
    OPERATOR 2 <= ,
    OPERATOR 3 = ,
    OPERATOR 4 >= ,
    OPERATOR 5 > ,
    FUNCTION 1 btint4cmp(int4, int4);
```

#### 步骤 3：更新 Makefile

```makefile
OBJS = nram.o nrindex.o my_index.o ...
```

#### 步骤 4：编译安装

```bash
cd /code/neurdb-dev/dbengine/nr_kernel
sudo make clean
sudo make install

# 重启数据库
/code/neurdb-dev/psql/bin/pg_ctl restart -D /code/neurdb-dev/psql/data -l /code/neurdb-dev/logfile
```

#### 步骤 5：使用新索引

```sql
-- 重新加载扩展（如果需要）
DROP EXTENSION nram CASCADE;
CREATE EXTENSION nram;

-- 创建使用新索引的表
CREATE TABLE test (
    id INT,
    value INT
) USING nram;

-- 使用新索引类型
CREATE INDEX idx_test ON test USING myindex (value);
```

### 7.4 必须实现的索引接口函数

| 函数 | 作用 |
|------|------|
| `xxx_handler()` | 返回索引处理函数表 |
| `xxx_build()` | 构建索引（CREATE INDEX 时调用） |
| `xxx_insert()` | 插入索引项 |
| `xxx_beginscan()` | 开始索引扫描 |
| `xxx_gettuple()` | 获取下一个元组 |
| `xxx_rescan()` | 重新扫描（参数变化时） |
| `xxx_endscan()` | 结束扫描，释放资源 |
| `xxx_bulkdelete()` | 批量删除（VACUUM 时调用） |
| `xxx_vacuumcleanup()` | 清理操作 |

### 7.5 索引创建语法汇总

```sql
-- B-tree（默认）
CREATE INDEX idx_name ON table_name (column);
CREATE INDEX idx_name ON table_name USING btree (column);

-- Hash
CREATE INDEX idx_name ON table_name USING hash (column);

-- GIN（适合数组、JSONB）
CREATE INDEX idx_name ON table_name USING gin (column);

-- GiST（适合几何、全文搜索）
CREATE INDEX idx_name ON table_name USING gist (column);

-- BRIN（适合大表）
CREATE INDEX idx_name ON table_name USING brin (column);

-- SP-GiST
CREATE INDEX idx_name ON table_name USING spgist (column);

-- NeurDB 自定义索引
CREATE INDEX idx_name ON table_name USING nrindex (column);
```

### 7.6 索引类型选择建议

| 场景 | 推荐索引 |
|------|----------|
| 常规查询 `=`, `<`, `>`, `ORDER BY` | `btree` |
| 仅等值查询 `=` | `hash` |
| 数组包含查询 `@>` | `gin` |
| JSONB 字段查询 | `gin` |
| 全文搜索 | `gin` 或 `gist` |
| 几何/地理数据 | `gist` |
| 超大表（TB级）、时序数据 | `brin` |
| NeurDB NRAM 表 | `nrindex` |

### 7.7 查看参考实现

```bash
# 查看 nrindex 实现
cat /code/neurdb-dev/dbengine/nr_kernel/nr_am/src/nrindex.c

# 查看 SQL 定义
cat /code/neurdb-dev/dbengine/nr_kernel/nr_am/sql/nram--1.0.sql

# 查看设计文档
cat /code/neurdb-dev/dbengine/nr_kernel/nr_am/NRINDEX_DESIGN.md
cat /code/neurdb-dev/dbengine/nr_kernel/nr_am/INDEXENGINE_ARCHITECTURE.md
```

---
