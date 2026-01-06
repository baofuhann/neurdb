#!/bin/bash
# TPC-H 数据导入脚本

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TPCH_DIR="/hdd9/benjamin/tpch-kit/dbgen"

# ===== 配置参数 =====
DB_NAME="${1:-tpch_test}"
DB_USER="${2:-neurdb}"
DB_HOST="${3:-localhost}"
DB_PORT="${4:-5432}"
PGDATA="/home/benjamin/neurdb"

PSQL="/code/neurdb-dev/psql/bin/psql -U $DB_USER -h $DB_HOST -p $DB_PORT"

echo "===== TPC-H 数据导入脚本 ====="
echo "数据库: $DB_NAME"
echo "用户: $DB_USER"
echo "主机: $DB_HOST:$DB_PORT"
echo ""

# 1. 创建数据库
echo "创建数据库..."
$PSQL -c "DROP DATABASE IF EXISTS $DB_NAME;" 2>/dev/null || true
$PSQL -c "CREATE DATABASE $DB_NAME;"

# 2. 创建表结构
echo "创建表结构..."
$PSQL -d $DB_NAME << 'EOF'
-- 地区表
CREATE TABLE region (
    r_regionkey  INTEGER PRIMARY KEY,
    r_name       CHAR(25),
    r_comment    VARCHAR(152)
);

-- 国家表
CREATE TABLE nation (
    n_nationkey  INTEGER PRIMARY KEY,
    n_name       CHAR(25),
    n_regionkey  INTEGER,
    n_comment    VARCHAR(152)
);

-- 供应商表
CREATE TABLE supplier (
    s_suppkey    INTEGER PRIMARY KEY,
    s_name       CHAR(25),
    s_address    VARCHAR(40),
    s_nationkey  INTEGER,
    s_phone      CHAR(15),
    s_acctbal    DECIMAL(15,2),
    s_comment    VARCHAR(101)
);

-- 客户表
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

-- 零件表
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

-- 零件供应表
CREATE TABLE partsupp (
    ps_partkey    INTEGER,
    ps_suppkey    INTEGER,
    ps_availqty   INTEGER,
    ps_supplycost DECIMAL(15,2),
    ps_comment    VARCHAR(199),
    PRIMARY KEY (ps_partkey, ps_suppkey)
);

-- 订单表
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

-- 订单明细表
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
EOF

# 3. 导入数据
echo "导入数据..."
echo "  - region..."
$PSQL -d $DB_NAME -c "\copy region FROM '$TPCH_DIR/region.tbl' DELIMITER '|' CSV"
echo "  - nation..."
$PSQL -d $DB_NAME -c "\copy nation FROM '$TPCH_DIR/nation.tbl' DELIMITER '|' CSV"
echo "  - supplier..."
$PSQL -d $DB_NAME -c "\copy supplier FROM '$TPCH_DIR/supplier.tbl' DELIMITER '|' CSV"
echo "  - customer..."
$PSQL -d $DB_NAME -c "\copy customer FROM '$TPCH_DIR/customer.tbl' DELIMITER '|' CSV"
echo "  - part..."
$PSQL -d $DB_NAME -c "\copy part FROM '$TPCH_DIR/part.tbl' DELIMITER '|' CSV"
echo "  - partsupp..."
$PSQL -d $DB_NAME -c "\copy partsupp FROM '$TPCH_DIR/partsupp.tbl' DELIMITER '|' CSV"
echo "  - orders..."
$PSQL -d $DB_NAME -c "\copy orders FROM '$TPCH_DIR/orders.tbl' DELIMITER '|' CSV"
echo "  - lineitem (最大表，请耐心等待)..."
$PSQL -d $DB_NAME -c "\copy lineitem FROM '$TPCH_DIR/lineitem.tbl' DELIMITER '|' CSV"

# 4. 创建索引
echo "创建索引..."
$PSQL -d $DB_NAME << 'EOF'
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
EOF

# 5. 分析表
echo "分析表统计信息..."
$PSQL -d $DB_NAME -c "ANALYZE;"

# 6. 验证
echo ""
echo "===== 数据导入验证 ====="
$PSQL -d $DB_NAME << 'EOF'
SELECT 'region' as table_name, COUNT(*) as rows FROM region
UNION ALL SELECT 'nation', COUNT(*) FROM nation
UNION ALL SELECT 'supplier', COUNT(*) FROM supplier
UNION ALL SELECT 'customer', COUNT(*) FROM customer
UNION ALL SELECT 'part', COUNT(*) FROM part
UNION ALL SELECT 'partsupp', COUNT(*) FROM partsupp
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'lineitem', COUNT(*) FROM lineitem
ORDER BY table_name;
EOF

echo ""
echo "===== 数据导入完成 ====="
echo "下一步: 运行 ./03_run_benchmark.sh 进行性能测试"
