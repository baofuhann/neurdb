# Direct Index Operations Architecture

## Overview

This document describes the new direct index operations architecture that eliminates the inefficient conversion between `NRIndexKey`/`NRIndexValue` and `NRAMKey`/`NRAMValue` structures.

## Problem Solved

**Previous Issue**: The original implementation converted between index-specific structures (`NRIndexKey`/`NRIndexValue`) and table-specific structures (`NRAMKey`/`NRAMValue`) for every operation, causing:
- Unnecessary serialization/deserialization overhead
- Complex conversion logic
- Potential data loss or corruption during conversion
- Poor performance

**Solution**: Implemented dedicated index operations that work directly with `NRIndexKey` and `NRIndexValue` structures throughout the entire stack.

## Architecture

### 1. Message Layer (`ipc/msg.h`)

Added new operation types for index operations:
```c
typedef enum KVOp {
    // ... existing operations ...
    kv_index_put,        /* Index put operation */
    kv_index_get,        /* Index get operation */
    kv_index_delete,     /* Index delete operation */
    kv_index_range_scan  /* Index range scan operation */
} KVOp;
```

### 2. Service Layer (`nram_storage/rocks_service.h` & `.c`)

Added dedicated index operation handlers:
- `handle_kv_index_get()`: Handle index get requests
- `handle_kv_index_put()`: Handle index put requests
- `handle_kv_index_delete()`: Handle index delete requests
- `handle_kv_index_range_scan()`: Handle index range scan requests

These handlers:
- Deserialize index keys/values directly from messages
- Call engine-level index operations
- Serialize results back to messages
- Handle proper memory management

### 3. Engine Layer (`nram_storage/rocksengine.h` & `.c`)

Added direct RocksDB operations for index data:
- `rocksengine_index_put()`: Store index key-value pairs
- `rocksengine_index_get()`: Retrieve index values by key
- `rocksengine_index_delete()`: Remove index entries
- `rocksengine_index_range_scan()`: Perform range scans over index keys

These functions:
- Work directly with RocksDB C API
- Handle index key/value serialization
- Manage RocksDB iterators for range operations
- Provide proper error handling

### 4. Client Layer (`nram_storage/rocks_handler.h` & `.c`)

Added client-side index operations:
- `RocksClientIndexGet()`: Client-side index get
- `RocksClientIndexPut()`: Client-side index put
- `RocksClientIndexDelete()`: Client-side index delete
- `RocksClientIndexRangeScan()`: Client-side index range scan

These functions:
- Create appropriate messages for index operations
- Send requests to the service layer
- Receive and deserialize responses
- Handle communication errors

### 5. Index Access Layer (`nrindex_access/nrindex_kv.c`)

Simplified index operations to use direct handlers:
```c
NRIndexValue nrindex_rocks_get(NRIndexKey ikey) {
    return RocksClientIndexGet(ikey);
}

bool nrindex_rocks_put(NRIndexKey ikey, NRIndexValue ivalue) {
    return RocksClientIndexPut(ikey, ivalue);
}
```

## Data Flow

### Index Put Operation
1. **Index AM**: `nrindex_insert()` calls `nrindex_rocks_put()`
2. **Index Access**: `nrindex_rocks_put()` calls `RocksClientIndexPut()`
3. **Client**: `RocksClientIndexPut()` creates `kv_index_put` message
4. **Service**: `handle_kv_index_put()` processes message
5. **Engine**: `rocksengine_index_put()` stores in RocksDB
6. **Response**: Success/failure flows back through the stack

### Index Get Operation
1. **Index AM**: `nrindex_rescan()` calls `nrindex_rocks_get()`
2. **Index Access**: `nrindex_rocks_get()` calls `RocksClientIndexGet()`
3. **Client**: `RocksClientIndexGet()` creates `kv_index_get` message
4. **Service**: `handle_kv_index_get()` processes message
5. **Engine**: `rocksengine_index_get()` retrieves from RocksDB
6. **Response**: Index value flows back through the stack

## Benefits

### 1. Performance Improvements
- **Eliminated Conversions**: No more conversion between index and table structures
- **Reduced Serialization**: Direct serialization of index keys/values
- **Faster Operations**: Streamlined data path through all layers

### 2. Code Simplification
- **Cleaner Interfaces**: Direct operations without conversion logic
- **Reduced Complexity**: Simpler error handling and memory management
- **Better Maintainability**: Clear separation between table and index operations

### 3. Data Integrity
- **No Conversion Errors**: Direct handling prevents data corruption
- **Consistent Format**: Index data maintains its original format throughout
- **Proper Serialization**: Dedicated serialization for index-specific data

### 4. Extensibility
- **Index-Specific Features**: Easy to add index-specific optimizations
- **Future Enhancements**: Simple to add new index operations
- **Separation of Concerns**: Clear distinction between table and index handling

## Implementation Details

### Message Format
Index operations use the same message structure but with different operation types:
```c
typedef struct KVMsg {
    KVMsgHeader header;  /* Contains kv_index_* operation type */
    void* entity;        /* Serialized index key/value data */
} KVMsg;
```

### Serialization Format
Index keys and values are serialized directly:
- **Index Key**: `[indexOid][key_size][serialized_key_data]`
- **Index Value**: `[heap_tid][xact_id][flags]`

### Error Handling
All layers provide consistent error handling:
- **Service Layer**: Validates message format and handles deserialization errors
- **Engine Layer**: Handles RocksDB errors and memory allocation failures
- **Client Layer**: Manages communication timeouts and response validation

## Testing

The implementation includes:
- **Unit Tests**: For each layer of the index operations
- **Integration Tests**: End-to-end index operation testing
- **Performance Tests**: Benchmarking against the old conversion approach
- **Error Tests**: Validation of error handling in each layer

## Future Enhancements

1. **Batch Operations**: Support for batch index operations
2. **Compression**: Index data compression for storage efficiency
3. **Caching**: Client-side caching of frequently accessed index entries
4. **Parallel Operations**: Concurrent index operations for better throughput
5. **Index Statistics**: Collection of index usage statistics

## Migration Notes

The new architecture is backward compatible:
- Existing table operations continue to work unchanged
- Index operations automatically use the new direct handlers
- No changes required to existing application code
- Gradual migration path for any custom index implementations
