-- nrindex 插入操作测试脚本 (从 CSV 文件读取插入数据)
-- Usage: psql -h /tmp -d neurdb -f test_insert.sql

\echo '=============================================='
\echo 'nrindex 插入操作测试'
\echo '=============================================='

-- 设置
SET client_min_messages = 'warning';
SET max_parallel_workers_per_gather = 0;
SET enable_seqscan = off;

-- 检查当前数据范围
\echo ''
\echo 'Step 1: 当前数据范围...'
SELECT MIN(val) AS min_val, MAX(val) AS max_val, COUNT(*) AS total FROM books;

-- 加载插入测试数据
\echo ''
\echo 'Step 2: 加载插入测试数据...'
DROP TABLE IF EXISTS books_insert;
CREATE TABLE books_insert (id INT, val INT);
\copy books_insert FROM '/tmp/books_insert.csv' CSV HEADER
SELECT COUNT(*) AS insert_count FROM books_insert;

-- 确保使用 nrindex
\echo ''
\echo 'Step 3: 确保 nrindex 索引存在...'
DROP INDEX IF EXISTS idx_books_val_btree;
DROP INDEX IF EXISTS idx_books_val;
CREATE INDEX idx_books_val ON books USING nrindex(val);

-- 测试单条插入
\echo ''
\echo '=============================================='
\echo 'Test 1: 单条插入测试'
\echo '=============================================='

\timing on

DO $$
DECLARE
    new_id INT;
    new_val INT;
    existing RECORD;
BEGIN
    SELECT COALESCE(MAX(id), 0) + 1 INTO new_id FROM books;

    -- 从插入测试表中取第一条
    SELECT val INTO new_val FROM books_insert ORDER BY id LIMIT 1;

    -- 检查该值是否已存在
    SELECT * INTO existing FROM books WHERE val = new_val LIMIT 1;
    IF FOUND THEN
        RAISE WARNING '值 % 已存在，跳过插入', new_val;
    ELSE
        RAISE WARNING '插入前: 查询 val = % (应该不存在)', new_val;

        -- 插入新数据
        INSERT INTO books (id, val) VALUES (new_id, new_val);
        RAISE WARNING '插入完成: id = %, val = %', new_id, new_val;

        -- 立即验证能否查到
        SELECT * INTO existing FROM books WHERE val = new_val LIMIT 1;
        IF FOUND THEN
            RAISE WARNING '✅ 插入后立即查询: 找到了! id = %', existing.id;
        ELSE
            RAISE WARNING '❌ 插入后立即查询: 找不到!';
        END IF;
    END IF;
END $$;

-- 测试批量插入 (从 CSV 文件)
\echo ''
\echo '=============================================='
\echo 'Test 2: 批量插入 100 条 (从 CSV 文件)'
\echo '=============================================='

DO $$
DECLARE
    start_id INT;
    rec RECORD;
    start_ts TIMESTAMP;
    end_ts TIMESTAMP;
    elapsed_ms NUMERIC;
    inserted_count INT := 0;
    i INT := 0;
BEGIN
    SELECT COALESCE(MAX(id), 0) + 1 INTO start_id FROM books;

    start_ts := clock_timestamp();

    -- 从 books_insert 表读取前 100 条（跳过第一条，已在 Test1 插入）
    FOR rec IN SELECT val FROM books_insert ORDER BY id OFFSET 1 LIMIT 100 LOOP
        BEGIN
            INSERT INTO books (id, val) VALUES (start_id + i, rec.val);
            inserted_count := inserted_count + 1;
        EXCEPTION WHEN unique_violation THEN
            NULL;
        END;
        i := i + 1;
    END LOOP;

    end_ts := clock_timestamp();
    elapsed_ms := EXTRACT(EPOCH FROM (end_ts - start_ts)) * 1000;

    RAISE WARNING '批量插入完成:';
    RAISE WARNING '  插入数量: % 条', inserted_count;
    RAISE WARNING '  总时间: % ms', ROUND(elapsed_ms, 2);
    IF inserted_count > 0 THEN
        RAISE WARNING '  平均每条: % ms', ROUND(elapsed_ms / inserted_count, 4);
    END IF;
END $$;

-- 测试批量插入 1000 条
\echo ''
\echo '=============================================='
\echo 'Test 3: 批量插入 1000 条 (从 CSV 文件)'
\echo '=============================================='

DO $$
DECLARE
    start_id INT;
    rec RECORD;
    start_ts TIMESTAMP;
    end_ts TIMESTAMP;
    elapsed_ms NUMERIC;
    inserted_count INT := 0;
    i INT := 0;
BEGIN
    SELECT COALESCE(MAX(id), 0) + 1 INTO start_id FROM books;

    start_ts := clock_timestamp();

    -- 从 books_insert 表读取 1000 条（跳过前 101 条）
    FOR rec IN SELECT val FROM books_insert ORDER BY id OFFSET 101 LIMIT 1000 LOOP
        BEGIN
            INSERT INTO books (id, val) VALUES (start_id + i, rec.val);
            inserted_count := inserted_count + 1;
        EXCEPTION WHEN unique_violation THEN
            NULL;
        END;
        i := i + 1;
    END LOOP;

    end_ts := clock_timestamp();
    elapsed_ms := EXTRACT(EPOCH FROM (end_ts - start_ts)) * 1000;

    RAISE WARNING '批量插入完成:';
    RAISE WARNING '  插入数量: % 条', inserted_count;
    RAISE WARNING '  总时间: % ms', ROUND(elapsed_ms, 2);
    IF inserted_count > 0 THEN
        RAISE WARNING '  平均每条: % ms', ROUND(elapsed_ms / inserted_count, 4);
    END IF;
END $$;

-- 验证插入结果
\echo ''
\echo '=============================================='
\echo '验证插入结果'
\echo '=============================================='

-- 检查插入的数据是否能查到
DO $$
DECLARE
    rec RECORD;
    found_count INT := 0;
    total_count INT := 0;
    result RECORD;
BEGIN
    FOR rec IN SELECT val FROM books_insert LIMIT 100 LOOP
        total_count := total_count + 1;
        SELECT * INTO result FROM books WHERE val = rec.val LIMIT 1;
        IF FOUND THEN
            found_count := found_count + 1;
        END IF;
    END LOOP;

    RAISE WARNING '验证结果: 查询前 100 条插入数据';
    RAISE WARNING '  找到: %/%', found_count, total_count;
    IF found_count = total_count THEN
        RAISE WARNING '✅ 所有数据都能查询到';
    ELSE
        RAISE WARNING '⚠️ 部分数据无法查询到';
    END IF;
END $$;

-- 最终数据量
-- \echo ''
-- \echo '=============================================='
-- \echo '最终状态'
-- \echo '=============================================='
-- SELECT COUNT(*) AS final_rows FROM books;
-- SELECT
--     (SELECT COUNT(*) FROM books) - 40000000 AS inserted_total,
--     (SELECT COUNT(*) FROM books_insert) AS expected_insert;

-- \echo ''
\echo '测试完成!'
