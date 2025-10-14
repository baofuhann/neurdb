# IndexEngine Architecture - Map-Based Implementation

## Overview

The `indexengine` is a dedicated C++ in-memory storage engine for index data using `std::map`. This is separate from the `rocksengine` which uses RocksDB for persistent table data storage.

## Why a Map-Based IndexEngine?

### Design Philosophy
1. **Simplicity**: In-memory `std::map` is simple and reliable
2. **Performance**: Fast lookups and range scans with O(log n) complexity
3. **No External Dependencies**: Only requires C++ STL, no RocksDB needed
4. **Separation of Concerns**: Tables and indexes use different storage strategies

### Key Differences from RocksEngine

| Feature | RocksEngine (Tables) | IndexEngine (Indexes) |
|---------|---------------------|----------------------|
| **Language** | C (rocksdb/c.h) | C++ (std::map) |
| **Storage** | Persistent (RocksDB) | In-memory (std::map) |
| **Data Structures** | NRAMKey/NRAMValue | NRIndexKey/NRIndexValue |
| **Dependencies** | RocksDB library | C++ STL only |
| **Persistence** | Disk-based | Memory-based |
| **Complexity** | O(log n) + disk I/O | O(log n) in memory |

## Architecture

### 1. C++ Implementation (`indexengine.cpp`)

```cpp
class IndexEngineImpl {
private:
    std::map<std::string, std::string> data_store;
    
public:
    // Core operations - all O(log n)
    void put(const std::string& key, const std::string& value);
    bool get(const std::string& key, std::string* value);
    void remove(const std::string& key);
    void rangeScan(...);  // Uses map iterators
    void clearRange(...);
    size_t size() const;
};
```

**Features:**
- **STL Map**: Balanced binary tree (typically Red-Black tree)
- **Sorted Keys**: Automatic key ordering for efficient range scans
- **In-Memory**: All data stored in process memory
- **RAII**: Automatic cleanup when engine is destroyed
- **Thread-Safe**: PostgreSQL's single-threaded access model

### 2. C Interface (`indexengine.h`)

The C++ implementation is wrapped with a C interface for PostgreSQL integration:

```c
typedef struct IndexEngine IndexEngine;  /* Opaque pointer */

IndexEngine* indexengine_open(void);
void indexengine_close(IndexEngine* engine);
void indexengine_put(IndexEngine* engine, NRIndexKey ikey, NRIndexValue ivalue);
NRIndexValue indexengine_get(IndexEngine* engine, NRIndexKey ikey);
void indexengine_delete(IndexEngine* engine, NRIndexKey ikey);
void indexengine_range_scan(IndexEngine* engine, ...);
```

**Benefits:**
- PostgreSQL can call C++ code through C interface
- Opaque pointer pattern hides C++ implementation details
- Type-safe conversion between C and C++ types

### 3. Integration with Rocks Service

The rocks service maintains a global index engine instance:

```c
static IndexEngine *index_engine = NULL;

void nram_rocks_service_init(void) {
    index_engine = indexengine_open();  // Creates std::map
    // ... rest of initialization
}

void nram_rocks_service_terminate(void) {
    indexengine_close(index_engine);  // Destroys std::map
    // ... rest of cleanup
}
```

## std::map Implementation Details

### Why std::map?

1. **Sorted Storage**: Keys are automatically sorted, perfect for range scans
2. **Balanced Tree**: Guarantees O(log n) for all operations
3. **Standard Library**: No external dependencies, highly reliable
4. **Iterator Support**: Efficient range operations
5. **Memory Efficient**: Only stores what's needed, no pre-allocation

### Performance Characteristics

| Operation | Complexity | Notes |
|-----------|-----------|-------|
| **Insert** | O(log n) | Self-balancing tree |
| **Lookup** | O(log n) | Binary search in tree |
| **Delete** | O(log n) | Tree rebalancing |
| **Range Scan** | O(log n + k) | k = number of results |
| **Iterator** | O(1) per step | In-order traversal |

### Memory Model

```
std::map<std::string, std::string>
    ├── Red-Black Tree nodes
    ├── Each node: [key, value, pointers]
    ├── Automatic balancing
    └── In-order iteration guaranteed
```

## Data Flow

### Index Put Operation
```
nrindex_insert()
  ↓
nrindex_rocks_put()
  ↓
RocksClientIndexPut()
  ↓
[IPC Message: kv_index_put]
  ↓
handle_kv_index_put()
  ↓
indexengine_put()
  ↓
IndexEngineImpl::put()
  ↓
std::map::operator[]  [In-memory insert]
```

### Index Get Operation
```
nrindex_rescan()
  ↓
nrindex_rocks_get()
  ↓
RocksClientIndexGet()
  ↓
[IPC Message: kv_index_get]
  ↓
handle_kv_index_get()
  ↓
indexengine_get()
  ↓
IndexEngineImpl::get()
  ↓
std::map::find()  [In-memory lookup]
```

### Index Range Scan Operation
```
nrindex_rescan()
  ↓
nrindex_rocks_range_scan()
  ↓
RocksClientIndexRangeScan()
  ↓
[IPC Message: kv_index_range_scan]
  ↓
handle_kv_index_range_scan()
  ↓
indexengine_range_scan()
  ↓
IndexEngineImpl::rangeScan()
  ↓
std::map::lower_bound()
  ↓
Iterator traversal  [In-memory scan]
```

## Performance Advantages

### 1. In-Memory Speed
- **No Disk I/O**: All operations happen in memory
- **Cache Friendly**: Data locality in tree structure
- **Fast Iteration**: Direct pointer traversal

### 2. Simple Implementation
- **No Serialization Overhead**: Direct memory access
- **No Transaction Log**: Immediate updates
- **No Compaction**: Tree automatically balanced

### 3. Predictable Performance
- **Guaranteed O(log n)**: No worst-case scenarios
- **No GC Pauses**: Deterministic memory management
- **No Background Tasks**: Synchronous operations

## Memory Management

### C++ Side
```cpp
// Automatic cleanup through RAII
IndexEngineImpl::~IndexEngineImpl() {
    data_store.clear();  // std::map destructor handles rest
}
```

### Memory Characteristics
- **Per-Entry Overhead**: ~32-40 bytes (node pointers + color bit)
- **Key/Value Storage**: Actual serialized data
- **Tree Overhead**: Minimal, self-organizing
- **Total Memory**: O(n) where n = number of entries

### Memory Safety
```cpp
extern "C" {
    NRIndexValue indexengine_get(IndexEngine* engine, NRIndexKey ikey) {
        try {
            // C++ operations with automatic cleanup
            std::string value;
            if (impl->get(key, &value)) {
                // Copy to PostgreSQL memory context
                return deserialize_index_value(value);
            }
            return nullptr;
        } catch (const std::exception& e) {
            elog(ERROR, "IndexEngine get failed: %s", e.what());
            return nullptr;
        }
    }
}
```

## Persistence Considerations

### Current Implementation: Volatile
- **In-Memory Only**: Data lost on process restart
- **No Disk Writes**: Fastest possible performance
- **Transaction Safe**: PostgreSQL handles crash recovery

### Future: Optional Persistence
Could add periodic snapshots:
```cpp
void snapshot(const std::string& path) {
    // Serialize entire map to disk
    std::ofstream file(path, std::ios::binary);
    for (const auto& kv : data_store) {
        // Write key length, key, value length, value
    }
}

void restore(const std::string& path) {
    // Deserialize from disk back to map
}
```

## Error Handling

### C++ Exceptions → PostgreSQL Errors
```cpp
extern "C" {
    void indexengine_put(IndexEngine* engine, NRIndexKey ikey, NRIndexValue ivalue) {
        try {
            IndexEngineImpl* impl = reinterpret_cast<IndexEngineImpl*>(engine);
            // std::map operations that may throw std::bad_alloc
            impl->put(key, value);
        } catch (const std::exception& e) {
            elog(ERROR, "IndexEngine put failed: %s", e.what());
        }
    }
}
```

### Exception Safety Guarantees
- **Basic Guarantee**: No memory leaks on exception
- **Strong Guarantee**: std::map provides transaction-like semantics
- **No-throw**: Destructor guaranteed not to throw

## Range Scan Implementation

### Using std::map Iterators
```cpp
void rangeScan(const std::string& start_key, const std::string& end_key,
              std::vector<std::pair<std::string, std::string>>& results) {
    // lower_bound: first element >= start_key
    auto it = data_store.lower_bound(start_key);
    
    // Iterate until we hit end_key
    while (it != data_store.end() && it->first < end_key) {
        results.push_back(std::make_pair(it->first, it->second));
        ++it;  // O(1) tree traversal
    }
}
```

### Efficiency
- **Start**: O(log n) to find starting position
- **Traverse**: O(1) per entry (in-order tree walk)
- **Total**: O(log n + k) where k = number of results

## Building and Compilation

### Makefile Configuration
```makefile
# C++ compiler flags - only STL needed
PG_CXXFLAGS += -std=c++11 -I./src/

# Link C++ standard library (no RocksDB for indexes)
SHLIB_LINK += -lstdc++

# Custom rule for C++ files
%.o: %.cpp
	$(CXX) $(PG_CXXFLAGS) $(CPPFLAGS) -fPIC -c $< -o $@
```

### Dependencies
- **C++11 Compiler**: g++ 4.8+ or clang++ 3.3+
- **STL**: C++ Standard Library (included with compiler)
- **PostgreSQL**: Development headers (pg_config)
- **No RocksDB**: Index engine doesn't need it!

## Usage Example

### Creating an Index
```sql
CREATE TABLE test_table (
    id INTEGER,
    name TEXT,
    value INTEGER
) USING nram;

-- Create index using nrindex access method
CREATE INDEX test_idx ON test_table (name, value) USING nrindex;

-- Index data is stored in-memory in std::map
```

### Index Operations
```sql
-- Fast in-memory lookups
SELECT * FROM test_table WHERE name = 'test';

-- Efficient range scans using map iterators
SELECT * FROM test_table WHERE name BETWEEN 'a' AND 'z';
```

## Advantages Over RocksDB-Based Index

### 1. Simplicity
- ✅ No external dependencies
- ✅ No configuration needed
- ✅ No disk management
- ✅ Easier to debug

### 2. Performance
- ✅ No disk I/O latency
- ✅ Faster for small to medium datasets
- ✅ Predictable performance
- ✅ No compaction overhead

### 3. Development
- ✅ Easier to test
- ✅ Simpler build process
- ✅ No version conflicts
- ✅ Standard C++ only

## Limitations and Trade-offs

### Current Limitations
- **Memory Only**: Data lost on crash (PostgreSQL handles recovery)
- **Size Limited**: By available RAM
- **No Compression**: Full data stored in memory
- **Single Process**: No distributed indexing

### When to Consider Disk-Based Alternative
- Very large indexes (> available RAM)
- Need for persistence across restarts
- Extremely high write volumes
- Need for compression

## Monitoring and Maintenance

### Statistics
```c
// Get count of index entries
uint64_t count = indexengine_get_count(engine, indexOid);

// Check if key exists
bool exists = indexengine_exists(engine, ikey);

// Get total map size
size_t size = impl->size();
```

### Memory Usage
```bash
# Check process memory
ps aux | grep postgres | grep neurdb
```

## Best Practices

1. **Bounded Size**: Ensure indexes fit in memory
2. **Regular Cleanup**: Remove old entries periodically
3. **Monitor Memory**: Track process memory usage
4. **Test Thoroughly**: Verify behavior with large datasets
5. **Use RAII**: Let C++ destructors handle cleanup
6. **Exception Safety**: Always wrap C++ in try-catch at boundary

## Future Enhancements

1. **Memory-Mapped File**: Add optional persistence
2. **Custom Allocator**: Pool allocator for better performance
3. **Concurrent Access**: Lock-free data structures
4. **Compression**: LZ4 compression for values
5. **Eviction Policy**: LRU cache for very large indexes
6. **Statistics**: Track hit rates and performance metrics

## Debugging

### Enable Debugging
```cpp
// Add debug output
void put(const std::string& key, const std::string& value) {
    std::cerr << "IndexEngine PUT: key size=" << key.size() 
              << " value size=" << value.size() << std::endl;
    data_store[key] = value;
}
```

### Memory Debugging
```bash
# Valgrind with C++ support
valgrind --leak-check=full --show-leak-kinds=all ./postgres

# Address Sanitizer
CXXFLAGS="-fsanitize=address -g" make
```

## Comparison: Map vs RocksDB

| Feature | std::map (Current) | RocksDB (Alternative) |
|---------|-------------------|----------------------|
| **Speed** | Very fast (in-memory) | Fast (with caching) |
| **Persistence** | No | Yes |
| **Size Limit** | RAM | Disk space |
| **Dependencies** | None | RocksDB library |
| **Complexity** | Simple | Complex |
| **Best For** | Small-medium indexes | Large persistent indexes |

## Conclusion

The map-based `indexengine` provides a simple, fast, and reliable solution for index storage:
- **Perfect for**: Development, testing, small-medium production workloads
- **Simple**: Only requires C++ STL
- **Fast**: All operations in memory
- **Reliable**: Battle-tested std::map implementation
- **Clean**: Clear separation from table storage (RocksDB)