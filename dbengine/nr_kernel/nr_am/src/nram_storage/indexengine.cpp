/* -------------------------------------------------------------------------
 * indexengine.cpp
 * In-memory map-based index storage engine using C++ STL
 *
 * This C++ implementation provides a simple in-memory index storage engine
 * using std::map for efficient key-value operations.
 * -------------------------------------------------------------------------
 */

extern "C" {
#include "indexengine.h"
#include "nrindex_access/nrindex_kv.h"
#include "utils/memutils.h"
#include "postgres.h"
}

#include <map>
#include <string>
#include <vector>
#include <algorithm>

/* C++ IndexEngine class implementation using std::map */
class IndexEngineImpl {
private:
    std::map<std::string, std::string> data_store;
    
public:
    IndexEngineImpl() {
        // Simple in-memory map - no initialization needed
    }
    
    ~IndexEngineImpl() {
        // Map destructor handles cleanup automatically
        data_store.clear();
    }
    
    void put(const std::string& key, const std::string& value) {
        data_store[key] = value;
    }
    
    bool get(const std::string& key, std::string* value) {
        auto it = data_store.find(key);
        if (it != data_store.end()) {
            *value = it->second;
            return true;
        }
        return false;
    }
    
    void remove(const std::string& key) {
        data_store.erase(key);
    }
    
    bool exists(const std::string& key) {
        return data_store.find(key) != data_store.end();
    }
    
    void rangeScan(const std::string& start_key, const std::string& end_key,
                  std::vector<std::pair<std::string, std::string>>& results) {
        // Find the starting position
        auto it = data_store.lower_bound(start_key);

        // Iterate until we pass the end key or end of map
        // Use <= to include end_key (important for equality searches where start_key == end_key)
        while (it != data_store.end() && it->first <= end_key) {
            results.push_back(std::make_pair(it->first, it->second));
            ++it;
        }
    }
    
    void clearRange(const std::string& start_key, const std::string& end_key) {
        auto it = data_store.lower_bound(start_key);
        auto end_it = data_store.lower_bound(end_key);
        data_store.erase(it, end_it);
    }
    
    size_t size() const {
        return data_store.size();
    }
    
    void clear() {
        data_store.clear();
    }
};

/* Helper functions to convert between C and C++ types */
static std::string serialize_index_key(NRIndexKey ikey) {
    Size len;
    char* buf = nrindex_key_serialize(ikey, &len);
    std::string result(buf, len);
    pfree(buf);
    return result;
}

static std::string serialize_index_value(NRIndexValue ivalue) {
    Size len;
    char* buf = nrindex_value_serialize(ivalue, &len);
    std::string result(buf, len);
    pfree(buf);
    return result;
}

static NRIndexKey deserialize_index_key(const std::string& data) {
    return nrindex_key_deserialize(data.c_str(), data.size());
}

static NRIndexValue deserialize_index_value(const std::string& data) {
    return nrindex_value_deserialize(data.c_str(), data.size());
}

/* C interface implementation */
extern "C" {

IndexEngine* indexengine_open(void) {
    try {
        return reinterpret_cast<IndexEngine*>(new IndexEngineImpl());
    } catch (const std::exception& e) {
        elog(ERROR, "Failed to create IndexEngine: %s", e.what());
        return nullptr;
    }
}

void indexengine_close(IndexEngine* engine) {
    if (engine) {
        delete reinterpret_cast<IndexEngineImpl*>(engine);
    }
}

void indexengine_put(IndexEngine* engine, NRIndexKey ikey, NRIndexValue ivalue) {
    if (!engine) {
        elog(ERROR, "IndexEngine: null engine pointer");
        return;
    }
    
    try {
        IndexEngineImpl* impl = reinterpret_cast<IndexEngineImpl*>(engine);
        std::string key = serialize_index_key(ikey);
        std::string value = serialize_index_value(ivalue);
        impl->put(key, value);
    } catch (const std::exception& e) {
        elog(ERROR, "IndexEngine put failed: %s", e.what());
    }
}

NRIndexValue indexengine_get(IndexEngine* engine, NRIndexKey ikey) {
    if (!engine) {
        elog(ERROR, "IndexEngine: null engine pointer");
        return nullptr;
    }
    
    try {
        IndexEngineImpl* impl = reinterpret_cast<IndexEngineImpl*>(engine);
        std::string key = serialize_index_key(ikey);
        std::string value;
        
        if (impl->get(key, &value)) {
            return deserialize_index_value(value);
        } else {
            return nullptr;
        }
    } catch (const std::exception& e) {
        elog(ERROR, "IndexEngine get failed: %s", e.what());
        return nullptr;
    }
}

void indexengine_delete(IndexEngine* engine, NRIndexKey ikey) {
    if (!engine) {
        elog(ERROR, "IndexEngine: null engine pointer");
        return;
    }
    
    try {
        IndexEngineImpl* impl = reinterpret_cast<IndexEngineImpl*>(engine);
        std::string key = serialize_index_key(ikey);
        impl->remove(key);
    } catch (const std::exception& e) {
        elog(ERROR, "IndexEngine delete failed: %s", e.what());
    }
}

void indexengine_range_scan(IndexEngine* engine, 
                           NRIndexKey start_key, 
                           NRIndexKey end_key,
                           uint32_t* out_count, 
                           NRIndexKey** keys, 
                           NRIndexValue** values) {
    if (!engine) {
        elog(ERROR, "IndexEngine: null engine pointer");
        *out_count = 0;
        return;
    }
    
    try {
        IndexEngineImpl* impl = reinterpret_cast<IndexEngineImpl*>(engine);
        std::string start_key_str = serialize_index_key(start_key);
        std::string end_key_str = serialize_index_key(end_key);
        
        std::vector<std::pair<std::string, std::string>> results;
        impl->rangeScan(start_key_str, end_key_str, results);
        
        *out_count = results.size();
        
        if (*out_count > 0) {
            *keys = (NRIndexKey*)palloc(sizeof(NRIndexKey) * (*out_count));
            *values = (NRIndexValue*)palloc(sizeof(NRIndexValue) * (*out_count));
            
            for (size_t i = 0; i < results.size(); i++) {
                (*keys)[i] = deserialize_index_key(results[i].first);
                (*values)[i] = deserialize_index_value(results[i].second);
            }
        } else {
            *keys = nullptr;
            *values = nullptr;
        }
    } catch (const std::exception& e) {
        elog(ERROR, "IndexEngine range scan failed: %s", e.what());
        *out_count = 0;
        *keys = nullptr;
        *values = nullptr;
    }
}

bool indexengine_exists(IndexEngine* engine, NRIndexKey ikey) {
    if (!engine) {
        elog(ERROR, "IndexEngine: null engine pointer");
        return false;
    }
    
    try {
        IndexEngineImpl* impl = reinterpret_cast<IndexEngineImpl*>(engine);
        std::string key = serialize_index_key(ikey);
        return impl->exists(key);
    } catch (const std::exception& e) {
        elog(ERROR, "IndexEngine exists failed: %s", e.what());
        return false;
    }
}

void indexengine_clear_range(IndexEngine* engine, NRIndexKey start_key, NRIndexKey end_key) {
    if (!engine) {
        elog(ERROR, "IndexEngine: null engine pointer");
        return;
    }
    
    try {
        IndexEngineImpl* impl = reinterpret_cast<IndexEngineImpl*>(engine);
        std::string start_key_str = serialize_index_key(start_key);
        std::string end_key_str = serialize_index_key(end_key);
        impl->clearRange(start_key_str, end_key_str);
    } catch (const std::exception& e) {
        elog(ERROR, "IndexEngine clear range failed: %s", e.what());
    }
}

uint64_t indexengine_get_count(IndexEngine* engine, Oid indexOid) {
    if (!engine) {
        elog(ERROR, "IndexEngine: null engine pointer");
        return 0;
    }
    
    try {
        IndexEngineImpl* impl = reinterpret_cast<IndexEngineImpl*>(engine);
        
        // Create min and max keys for this index
        NRIndexKeyData min_key_data, max_key_data;
        min_key_data.indexOid = indexOid;
        min_key_data.key_size = 0;
        max_key_data.indexOid = indexOid + 1;
        max_key_data.key_size = 0;
        
        std::string start_key_str = serialize_index_key(&min_key_data);
        std::string end_key_str = serialize_index_key(&max_key_data);
        
        std::vector<std::pair<std::string, std::string>> results;
        impl->rangeScan(start_key_str, end_key_str, results);
        
        return results.size();
    } catch (const std::exception& e) {
        elog(ERROR, "IndexEngine get count failed: %s", e.what());
        return 0;
    }
}

void indexengine_compact(IndexEngine* engine) {
    if (!engine) {
        elog(ERROR, "IndexEngine: null engine pointer");
        return;
    }
    
    // No-op for in-memory map implementation
    // In a real implementation, this could trigger memory optimization
}

} // extern "C"
