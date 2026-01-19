\set iid random(1, 1000000)
\set newid random(5000001, 55000001)
SELECT bench_write_btree(:iid, :newid);
