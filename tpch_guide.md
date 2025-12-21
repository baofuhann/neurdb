# TPC-H 安装与使用指南

TPC-H 是一个决策支持基准测试，用于评估数据库系统的查询性能。

## 1. 安装 TPC-H

### 方法一：从 GitHub 获取（推荐）

```bash
# 克隆已适配 PostgreSQL 的版本
git clone https://github.com/gregrahn/tpch-kit.git
cd tpch-kit/dbgen
```

### 方法二：从 TPC 官方获取

前往官网 https://www.tpc.org/tpch/ 注册下载，解压后进入 `dbgen` 目录。

## 2. 编译 dbgen

```bash
cd tpch-kit/dbgen

# 编译（指定平台和数据库类型）
make MACHINE=LINUX DATABASE=POSTGRESQL
```

**参数说明：**

| 参数 | 含义 |
|------|------|
| `MACHINE=LINUX` | 目标操作系统为 Linux |
| `DATABASE=POSTGRESQL` | 目标数据库为 PostgreSQL |

**其他可选值：**
- MACHINE: `LINUX`, `WIN32`, `MAC`, `HP`, `SUN`
- DATABASE: `POSTGRESQL`, `ORACLE`, `MYSQL`, `DB2`, `SQLSERVER`

## 3. 生成测试数据

```bash
# 生成 1GB 规模的数据
./dbgen -s 1
```

**Scale Factor 对应数据量：**

| Scale Factor | 数据量 |
|--------------|--------|
| `-s 0.1` | ~100MB |
| `-s 1` | ~1GB |
| `-s 10` | ~10GB |
| `-s 100` | ~100GB |

**生成的文件（在当前目录）：**

```
customer.tbl    # 客户表
lineitem.tbl    # 订单明细表（最大）
nation.tbl      # 国家表
orders.tbl      # 订单表
part.tbl        # 零件表
partsupp.tbl    # 零件供应表
region.tbl      # 地区表
supplier.tbl    # 供应商表
```

**指定输出目录：**

```bash
./dbgen -s 1 -O /path/to/output/
```

## 4. 生成查询语句

```bash
./qgen -s 1 > queries.sql
```

## 5. 导入 PostgreSQL

### 5.1 创建表结构

```sql
-- 创建 TPC-H 表结构
CREATE TABLE nation (
    n_nationkey  INTEGER PRIMARY KEY,
    n_name       CHAR(25),
    n_regionkey  INTEGER,
    n_comment    VARCHAR(152)
);

CREATE TABLE region (
    r_regionkey  INTEGER PRIMARY KEY,
    r_name       CHAR(25),
    r_comment    VARCHAR(152)
);

CREATE TABLE supplier (
    s_suppkey    INTEGER PRIMARY KEY,
    s_name       CHAR(25),
    s_address    VARCHAR(40),
    s_nationkey  INTEGER,
    s_phone      CHAR(15),
    s_acctbal    DECIMAL(15,2),
    s_comment    VARCHAR(101)
);

CREATE TABLE customer (
    c_custkey    INTEGER PRIMARY KEY,
    c_name       VARCHAR(25),
    c_address    VARCHAR(40),
    c_nationkey  INTEGER,
    c_phone      CHAR(15),
    c_acctbal    DECIMAL(15,2),
    c_mktsegment CHAR(10),
    c_comment    VARCHAR(117)
);

CREATE TABLE part (
    p_partkey     INTEGER PRIMARY KEY,
    p_name        VARCHAR(55),
    p_mfgr        CHAR(25),
    p_brand       CHAR(10),
    p_type        VARCHAR(25),
    p_size        INTEGER,
    p_container   CHAR(10),
    p_retailprice DECIMAL(15,2),
    p_comment     VARCHAR(23)
);

CREATE TABLE partsupp (
    ps_partkey    INTEGER,
    ps_suppkey    INTEGER,
    ps_availqty   INTEGER,
    ps_supplycost DECIMAL(15,2),
    ps_comment    VARCHAR(199),
    PRIMARY KEY (ps_partkey, ps_suppkey)
);

CREATE TABLE orders (
    o_orderkey      INTEGER PRIMARY KEY,
    o_custkey       INTEGER,
    o_orderstatus   CHAR(1),
    o_totalprice    DECIMAL(15,2),
    o_orderdate     DATE,
    o_orderpriority CHAR(15),
    o_clerk         CHAR(15),
    o_shippriority  INTEGER,
    o_comment       VARCHAR(79)
);

CREATE TABLE lineitem (
    l_orderkey      INTEGER,
    l_partkey       INTEGER,
    l_suppkey       INTEGER,
    l_linenumber    INTEGER,
    l_quantity      DECIMAL(15,2),
    l_extendedprice DECIMAL(15,2),
    l_discount      DECIMAL(15,2),
    l_tax           DECIMAL(15,2),
    l_returnflag    CHAR(1),
    l_linestatus    CHAR(1),
    l_shipdate      DATE,
    l_commitdate    DATE,
    l_receiptdate   DATE,
    l_shipinstruct  CHAR(25),
    l_shipmode      CHAR(10),
    l_comment       VARCHAR(44),
    PRIMARY KEY (l_orderkey, l_linenumber)
);
```

### 5.2 处理 tbl 文件

TPC-H 生成的 `.tbl` 文件每行末尾有多余的 `|`，需要先去掉：

```bash
cd /path/to/tpch-kit/dbgen

# 去掉每行末尾的 |
for f in *.tbl; do
    sed -i 's/|$//' "$f"
done
```

### 5.3 导入数据

```bash
# 设置数据库连接信息
DB_NAME="your_database"
TBL_DIR="/path/to/tpch-kit/dbgen"

# 按顺序导入（注意外键依赖）
psql -d $DB_NAME -c "\copy region FROM '$TBL_DIR/region.tbl' DELIMITER '|'"
psql -d $DB_NAME -c "\copy nation FROM '$TBL_DIR/nation.tbl' DELIMITER '|'"
psql -d $DB_NAME -c "\copy supplier FROM '$TBL_DIR/supplier.tbl' DELIMITER '|'"
psql -d $DB_NAME -c "\copy customer FROM '$TBL_DIR/customer.tbl' DELIMITER '|'"
psql -d $DB_NAME -c "\copy part FROM '$TBL_DIR/part.tbl' DELIMITER '|'"
psql -d $DB_NAME -c "\copy partsupp FROM '$TBL_DIR/partsupp.tbl' DELIMITER '|'"
psql -d $DB_NAME -c "\copy orders FROM '$TBL_DIR/orders.tbl' DELIMITER '|'"
psql -d $DB_NAME -c "\copy lineitem FROM '$TBL_DIR/lineitem.tbl' DELIMITER '|'"
```

### 5.4 验证导入

```sql
-- 检查各表行数
SELECT 'region' as table_name, COUNT(*) FROM region
UNION ALL SELECT 'nation', COUNT(*) FROM nation
UNION ALL SELECT 'supplier', COUNT(*) FROM supplier
UNION ALL SELECT 'customer', COUNT(*) FROM customer
UNION ALL SELECT 'part', COUNT(*) FROM part
UNION ALL SELECT 'partsupp', COUNT(*) FROM partsupp
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'lineitem', COUNT(*) FROM lineitem;
```

**Scale Factor = 1 时预期行数：**

| 表名 | 行数 |
|------|------|
| region | 5 |
| nation | 25 |
| supplier | 10,000 |
| customer | 150,000 |
| part | 200,000 |
| partsupp | 800,000 |
| orders | 1,500,000 |
| lineitem | ~6,000,000 |

## 6. 创建索引（可选）

为提升查询性能，建议创建以下索引：

```sql
CREATE INDEX idx_nation_regionkey ON nation(n_regionkey);
CREATE INDEX idx_supplier_nationkey ON supplier(s_nationkey);
CREATE INDEX idx_customer_nationkey ON customer(c_nationkey);
CREATE INDEX idx_partsupp_partkey ON partsupp(ps_partkey);
CREATE INDEX idx_partsupp_suppkey ON partsupp(ps_suppkey);
CREATE INDEX idx_orders_custkey ON orders(o_custkey);
CREATE INDEX idx_orders_orderdate ON orders(o_orderdate);
CREATE INDEX idx_lineitem_orderkey ON lineitem(l_orderkey);
CREATE INDEX idx_lineitem_partkey ON lineitem(l_partkey);
CREATE INDEX idx_lineitem_suppkey ON lineitem(l_suppkey);
CREATE INDEX idx_lineitem_shipdate ON lineitem(l_shipdate);
```

## 7. 运行 TPC-H 查询

TPC-H 包含 22 个标准查询（Q1-Q22），用于测试不同的数据库能力：

```bash
# 生成所有 22 个查询
for i in $(seq 1 22); do
    ./qgen $i > query_$i.sql
done

# 运行单个查询并计时
psql -d $DB_NAME -c "\timing" -f query_1.sql
```

## 8. 常见问题

### Q: 编译时报错找不到头文件？

确保安装了必要的开发工具：

```bash
# Ubuntu/Debian
sudo apt-get install build-essential

# CentOS/RHEL
sudo yum groupinstall "Development Tools"
```

### Q: 导入时报错 "extra data after last expected column"？

说明没有去掉行末的 `|`，请执行步骤 5.2。

### Q: 如何清理数据重新导入？

```sql
TRUNCATE lineitem, orders, partsupp, customer, supplier, part, nation, region CASCADE;
```
