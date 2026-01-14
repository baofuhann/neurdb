-- ============================================
-- 测试 nrindex 索引已实现的功能
-- ============================================

-- 清理之前的测试
DROP TABLE IF EXISTS test_idx CASCADE;
DROP OPERATOR CLASS IF EXISTS int4_nrindex_ops USING nrindex CASCADE;

-- 确保扩展已加载
CREATE EXTENSION IF NOT EXISTS nram;

-- 为 nrindex 创建操作符类 (借用 btree 的比较函数)
CREATE OPERATOR CLASS int4_nrindex_ops
DEFAULT FOR TYPE int4 USING nrindex AS
    OPERATOR 1 <,
    OPERATOR 2 <=,
    OPERATOR 3 =,
    OPERATOR 4 >=,
    OPERATOR 5 >,
    FUNCTION 1 btint4cmp(int4, int4);

\echo ''
\echo '=== 测试 1: 索引构建 (nrindex_build) ==='

-- 创建测试表
CREATE TABLE test_idx (
    id   INT,
    val  INT
) USING;

INSERT INTO test_idx VALUES (1, 100);
INSERT INTO test_idx VALUES (2, 200);
INSERT INTO test_idx VALUES (3, 300);
INSERT INTO test_idx VALUES (4, 400);
INSERT INTO test_idx VALUES (5, 500);

-- ============================================
-- 插入 N 条数据 (使用 generate_series)
-- ============================================
-- 语法: INSERT INTO table SELECT ... FROM generate_series(1, N)
--
-- 生成的数据:
--   id  = 1, 2, 3, ..., N
--   val = 10, 20, 30, ..., N*10
-- ============================================

-- 插入 N 条数据
INSERT INTO test_idx SELECT i, i * 10 FROM generate_series(1,10000) AS i;

\echo ''
\echo '插入数据完成，共插入:'
SELECT COUNT(*) AS total_rows FROM test_idx;

-- 查看前 10 条数据
\echo ''
\echo '前 10 条数据:'
SELECT * FROM test_idx LIMIT 10;

-- 创建索引 (语法: CREATE INDEX name ON table USING method (column))
CREATE INDEX test_idx_val ON test_idx USING nrindex (val);

\echo ''
\echo '索引创建成功! nrindex_build() 已执行'

-- 查看索引信息
\echo ''
\echo '=== 索引信息 ==='
SELECT indexname, indexdef FROM pg_indexes WHERE tablename = 'test_idx';

\echo ''

-- 验证查询计划
EXPLAIN SELECT * FROM test_idx WHERE val = 500;
-- 强制使用索引扫描
SET enable_seqscan = off;
SELECT * FROM test_idx WHERE val = 500;



-- 重新创建测试数据
  DROP TABLE IF EXISTS test_idx CASCADE;
  CREATE TABLE test_idx (id INT, val INT);
  INSERT INTO test_idx SELECT i, i * 10 FROM generate_series(1, 100) AS i;
  CREATE INDEX test_idx_val ON test_idx USING nrindex (val);

  SET enable_seqscan = off;

  -- 测试大于查询 (min_key=900, max_key=NULL)
  SELECT * FROM test_idx WHERE val > 900;
  -- 测试小于查询 (min_key=NULL, max_key=50)
  SELECT * FROM test_idx WHERE val < 50;


  -- 1. 创建表 (val 使用 BIGINT)
  DROP TABLE IF EXISTS covid;
  CREATE TABLE covid (
      id INT,
      val BIGINT
  ) USING;

  -- 2. 导入 CSV 数据
  \copy covid FROM '/tmp/covid_1m.csv' CSV HEADER;

  -- 3. 验证数据
  SELECT COUNT(*) FROM covid;
  SELECT * FROM covid LIMIT 5;

  -- 4. 创建 SELIX 索引
  DROP INDEX IF EXISTS idx_covid_val;
  CREATE INDEX idx_covid_val ON covid USING nrindex(val);
  