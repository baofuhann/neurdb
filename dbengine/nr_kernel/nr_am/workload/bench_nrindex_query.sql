\set kid random(1, 1000000)
SELECT * FROM bench_read_nrindex(:kid);
