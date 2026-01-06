#!/bin/bash
# Index Performance Benchmark Script
# Runs 100,000 queries to measure throughput

PSQL="/code/neurdb-dev/psql/bin/psql -h /tmp -d neurdb"
QUERY_COUNT=100000

echo "=============================================="
echo "Index Performance Benchmark"
echo "Query count: $QUERY_COUNT"
echo "=============================================="

# Setup: disable noise
$PSQL -c "SET client_min_messages = 'error';" 2>/dev/null

# Function to run benchmark
run_benchmark() {
    local index_type=$1
    local index_name=$2

    echo ""
    echo "------------------------------------------"
    echo "Testing: $index_type ($index_name)"
    echo "------------------------------------------"

    # Generate random query values (1-1000000 range for 1M rows)
    # Using a fixed set of values for fair comparison

    # Warm up
    echo "Warming up..."
    $PSQL -c "SET client_min_messages = 'error'; SELECT * FROM books WHERE val = 21;" >/dev/null 2>&1
    $PSQL -c "SET client_min_messages = 'error'; SELECT * FROM books WHERE val = 100;" >/dev/null 2>&1
    $PSQL -c "SET client_min_messages = 'error'; SELECT * FROM books WHERE val = 500;" >/dev/null 2>&1

    echo "Running $QUERY_COUNT queries..."

    # Create SQL file with 100k queries
    local sql_file="/tmp/benchmark_queries_$$.sql"
    echo "SET client_min_messages = 'error';" > $sql_file
    echo "SET max_parallel_workers_per_gather = 0;" >> $sql_file
    echo "SET enable_seqscan = off;" >> $sql_file
    echo "\\timing off" >> $sql_file

    # Generate queries with random values
    for i in $(seq 1 $QUERY_COUNT); do
        # Use modulo to create repeatable "random" values
        val=$((($i * 7919) % 1000000 + 1))
        echo "SELECT * FROM books WHERE val = $val;" >> $sql_file
    done

    # Run benchmark
    local start_time=$(date +%s.%N)
    $PSQL -f $sql_file >/dev/null 2>&1
    local end_time=$(date +%s.%N)

    # Calculate results
    local elapsed=$(echo "$end_time - $start_time" | bc)
    local qps=$(echo "scale=2; $QUERY_COUNT / $elapsed" | bc)
    local avg_latency=$(echo "scale=4; $elapsed / $QUERY_COUNT * 1000" | bc)

    echo ""
    echo "Results for $index_type:"
    echo "  Total time:    ${elapsed} seconds"
    echo "  Throughput:    ${qps} queries/second"
    echo "  Avg latency:   ${avg_latency} ms/query"

    # Cleanup
    rm -f $sql_file
}

# Ensure table exists
echo "Checking table..."
TABLE_EXISTS=$($PSQL -t -c "SELECT COUNT(*) FROM pg_tables WHERE tablename = 'books';" 2>/dev/null | tr -d ' ')
if [ "$TABLE_EXISTS" -eq "0" ]; then
    echo "Error: Table 'books' does not exist!"
    exit 1
fi

ROW_COUNT=$($PSQL -t -c "SELECT COUNT(*) FROM books;" 2>/dev/null | tr -d ' ')
echo "Table 'books' has $ROW_COUNT rows"

# Test 1: nrindex (LIPP with direct call)
echo ""
echo "=============================================="
echo "Benchmark 1: nrindex (LIPP - Direct Call)"
echo "=============================================="

$PSQL -c "DROP INDEX IF EXISTS idx_books_val_btree;" 2>/dev/null
$PSQL -c "DROP INDEX IF EXISTS idx_books_val;" 2>/dev/null

echo "Creating nrindex..."
$PSQL -c "SET client_min_messages = 'warning'; CREATE INDEX idx_books_val ON books USING nrindex(val);" 2>/dev/null

run_benchmark "nrindex" "idx_books_val"

# Test 2: B-tree
echo ""
echo "=============================================="
echo "Benchmark 2: B-tree"
echo "=============================================="

$PSQL -c "DROP INDEX IF EXISTS idx_books_val;" 2>/dev/null

echo "Creating btree index..."
$PSQL -c "CREATE INDEX idx_books_val_btree ON books USING btree(val);" 2>/dev/null

run_benchmark "btree" "idx_books_val_btree"

# Summary
echo ""
echo "=============================================="
echo "Benchmark Complete"
echo "=============================================="
