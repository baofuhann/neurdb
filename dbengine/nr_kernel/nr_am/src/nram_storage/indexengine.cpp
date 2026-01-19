/* -------------------------------------------------------------------------
 * indexengine.cpp
 * Learned index storage engine using concurrent ALEX (alexol)
 *
 * 单Backend模式优化版本 - 无持久化，无锁
 * -------------------------------------------------------------------------
 */

extern "C" {
#include "indexengine.h"
#include "nrindex_access/nrindex_kv.h"
#include "utils/memutils.h"
#include "postgres.h"
#include "storage/itemptr.h"
}

// 保存并取消 PostgreSQL 的 LOG 定义，避免与 alexol 冲突
#ifdef LOG
#undef LOG
#endif

// 使用单线程版本的 ALEX
#include "ALEX/src/core/alex.h"

// 取消 ALEX 的 LOG 定义，恢复 PostgreSQL 的 LOG (值为 15)
#ifdef LOG
#undef LOG
#endif
#define LOG 15
#include <map>
#include <vector>
#include <algorithm>
#include <cstdlib>

/* -------------------------------------------------------------------------
 * Key encoding/decoding (supports both INT and BIGINT)
 * -------------------------------------------------------------------------
 */

// Encode int64 to uint64 for correct sort order (flip sign bit)
static inline uint64_t encode_key_64(int64_t val) {
    return (uint64_t)val ^ 0x8000000000000000ULL;
}

// Decode uint64 back to int64
static inline int64_t decode_key_64(uint64_t key) {
    return (int64_t)(key ^ 0x8000000000000000ULL);
}

// Extract key from NRIndexKey - supports both 4-byte (INT) and 8-byte (BIGINT)
static inline int64_t extract_int_from_key(NRIndexKey ikey) {
    const unsigned char* buf = (const unsigned char*)ikey->key_data;

    if (ikey->key_size == 8) {
        // BIGINT: 8 bytes, big-endian
        uint64_t encoded = ((uint64_t)buf[0] << 56) |
                           ((uint64_t)buf[1] << 48) |
                           ((uint64_t)buf[2] << 40) |
                           ((uint64_t)buf[3] << 32) |
                           ((uint64_t)buf[4] << 24) |
                           ((uint64_t)buf[5] << 16) |
                           ((uint64_t)buf[6] << 8) |
                           ((uint64_t)buf[7]);
        return (int64_t)(encoded ^ 0x8000000000000000ULL);
    } else if (ikey->key_size >= 4) {
        // INT: 4 bytes, big-endian
        uint32_t encoded = ((uint32_t)buf[0] << 24) |
                           ((uint32_t)buf[1] << 16) |
                           ((uint32_t)buf[2] << 8) |
                           ((uint32_t)buf[3]);
        return (int64_t)((int32_t)(encoded ^ 0x80000000));
    } else {
        elog(ERROR, "IndexEngine: key_size too small (%u)", ikey->key_size);
        return 0;
    }
}

/* -------------------------------------------------------------------------
 * Value encoding/decoding
 * -------------------------------------------------------------------------
 */

static inline uint64_t compress_heap_tid(ItemPointer tid) {
    BlockNumber blk = ItemPointerGetBlockNumber(tid);
    OffsetNumber off = ItemPointerGetOffsetNumber(tid);
    return ((uint64_t)blk << 32) | (uint64_t)off;
}

static inline void decompress_heap_tid(uint64_t compressed, ItemPointer tid) {
    BlockNumber blk = (BlockNumber)(compressed >> 32);
    OffsetNumber off = (OffsetNumber)(compressed & 0xFFFF);
    ItemPointerSet(tid, blk, off);
}

/* -------------------------------------------------------------------------
 * ALEX Index Engine - 单Backend模式优化版
 * 无锁、无持久化，直接访问
 * -------------------------------------------------------------------------
 */
class ALEXIndexEngine {
private:
    // 索引map - 单backend无需锁
    std::map<Oid, alex::Alex<int64_t, uint64_t>*> indexes;

    // 缓存最近使用的索引，避免频繁map查找
    Oid cached_oid = 0;
    alex::Alex<int64_t, uint64_t>* cached_index = nullptr;

    // 配置参数
    int max_node_size = 1 << 24;      // 16MB default
    int max_data_node_size = 1 << 19; // 512KB default

public:
    ALEXIndexEngine() {
        elog(LOG, "ALEX IndexEngine initialized (single-backend optimized, no locks)");
    }

    ~ALEXIndexEngine() {
        for (auto& pair : indexes) {
            delete pair.second;
        }
        indexes.clear();
    }

    // 快速获取索引 - 使用缓存避免map查找
    inline alex::Alex<int64_t, uint64_t>* getIndex(Oid indexOid) {
        // 缓存命中 - 最快路径
        if (indexOid == cached_oid && cached_index != nullptr) {
            return cached_index;
        }

        auto it = indexes.find(indexOid);
        if (it != indexes.end()) {
            // 更新缓存
            cached_oid = indexOid;
            cached_index = it->second;
            return cached_index;
        }

        // 创建新索引
        alex::Alex<int64_t, uint64_t>* idx = new alex::Alex<int64_t, uint64_t>();
        idx->set_max_node_size(max_node_size);
        indexes[indexOid] = idx;

        // 更新缓存
        cached_oid = indexOid;
        cached_index = idx;

        return idx;
    }

    inline void put(Oid indexOid, int64_t val, uint64_t tid) {
        alex::Alex<int64_t, uint64_t>* idx = getIndex(indexOid);
        int64_t key = (int64_t)encode_key_64(val);
        idx->insert(key, tid);
    }

    inline bool get(Oid indexOid, int64_t val, uint64_t* tid) {
        alex::Alex<int64_t, uint64_t>* idx = getIndex(indexOid);
        if (idx->get_stats().num_keys == 0) return false;

        int64_t key = (int64_t)encode_key_64(val);
        uint64_t* result = idx->get_payload(key);
        if (result != nullptr) {
            *tid = *result;
            return true;
        }
        return false;
    }

    inline bool exists(Oid indexOid, int64_t val) {
        uint64_t dummy;
        return get(indexOid, val, &dummy);
    }

    size_t getCount(Oid indexOid) {
        auto it = indexes.find(indexOid);
        if (it == indexes.end()) return 0;
        return it->second->get_stats().num_keys;
    }

    void bulkLoad(Oid indexOid, int64_t* keys, uint64_t* values, int count) {
        if (count <= 0) return;

        typedef std::pair<int64_t, uint64_t> KVPair;
        std::vector<KVPair> pairs;
        pairs.reserve(count);

        for (int i = 0; i < count; i++) {
            pairs.push_back(std::make_pair((int64_t)encode_key_64(keys[i]), values[i]));
        }

        std::sort(pairs.begin(), pairs.end(),
                  [](const KVPair& a, const KVPair& b) { return a.first < b.first; });

        auto last = std::unique(pairs.begin(), pairs.end(),
                                [](const KVPair& a, const KVPair& b) { return a.first == b.first; });
        pairs.erase(last, pairs.end());

        alex::Alex<int64_t, uint64_t>* idx = getIndex(indexOid);
        idx->bulk_load(pairs.data(), pairs.size());

        auto stats = idx->get_stats();
        elog(LOG, "ALEX: bulkLoad completed, indexOid=%u, count=%zu, data_nodes=%d, model_nodes=%d",
             indexOid, pairs.size(), stats.num_data_nodes, stats.num_model_nodes);
    }
};

/* -------------------------------------------------------------------------
 * C interface implementation
 * -------------------------------------------------------------------------
 */

extern "C" {

IndexEngine* indexengine_open(void) {
    try {
        return reinterpret_cast<IndexEngine*>(new ALEXIndexEngine());
    } catch (const std::exception& e) {
        elog(ERROR, "Failed to create IndexEngine: %s", e.what());
        return nullptr;
    }
}

void indexengine_close(IndexEngine* engine) {
    if (engine) {
        delete reinterpret_cast<ALEXIndexEngine*>(engine);
    }
}

void indexengine_put(IndexEngine* engine, NRIndexKey ikey, NRIndexValue ivalue) {
    if (!engine) return;

    ALEXIndexEngine* impl = reinterpret_cast<ALEXIndexEngine*>(engine);
    Oid indexOid = ikey->indexOid;
    int64_t val = extract_int_from_key(ikey);
    uint64_t compressed_tid = compress_heap_tid(&ivalue->heap_tid);
    impl->put(indexOid, val, compressed_tid);
}

NRIndexValue indexengine_get(IndexEngine* engine, NRIndexKey ikey) {
    if (!engine) return nullptr;

    ALEXIndexEngine* impl = reinterpret_cast<ALEXIndexEngine*>(engine);
    Oid indexOid = ikey->indexOid;
    int64_t val = extract_int_from_key(ikey);

    uint64_t compressed_tid;
    if (impl->get(indexOid, val, &compressed_tid)) {
        NRIndexValue ivalue = (NRIndexValue)palloc0(sizeof(NRIndexValueData));
        decompress_heap_tid(compressed_tid, &ivalue->heap_tid);
        ivalue->xact_id = InvalidTransactionId;
        ivalue->flags = 0;
        return ivalue;
    }
    return nullptr;
}

void indexengine_delete(IndexEngine* engine, NRIndexKey ikey) {
    elog(WARNING, "IndexEngine: delete not supported");
}

void indexengine_range_scan(IndexEngine* engine,
                           NRIndexKey start_key,
                           NRIndexKey end_key,
                           uint32_t* out_count,
                           NRIndexKey** keys,
                           NRIndexValue** values) {
    *out_count = 0;
    *keys = nullptr;
    *values = nullptr;

    if (!engine || !start_key || !end_key) return;

    // Equality query check
    if (start_key->indexOid == end_key->indexOid &&
        start_key->key_size == end_key->key_size &&
        memcmp(start_key->key_data, end_key->key_data, start_key->key_size) == 0) {

        ALEXIndexEngine* impl = reinterpret_cast<ALEXIndexEngine*>(engine);
        Oid indexOid = start_key->indexOid;
        int64_t val = extract_int_from_key(start_key);

        uint64_t compressed_tid;
        if (impl->get(indexOid, val, &compressed_tid)) {
            *out_count = 1;
            *keys = (NRIndexKey*)palloc(sizeof(NRIndexKey));
            *values = (NRIndexValue*)palloc(sizeof(NRIndexValue));

            (*keys)[0] = nrindex_key_copy(start_key);
            (*values)[0] = (NRIndexValue)palloc0(sizeof(NRIndexValueData));
            decompress_heap_tid(compressed_tid, &(*values)[0]->heap_tid);
            (*values)[0]->xact_id = InvalidTransactionId;
            (*values)[0]->flags = 0;
        }
    } else {
        elog(WARNING, "IndexEngine: true range scan not supported");
    }
}

bool indexengine_exists(IndexEngine* engine, NRIndexKey ikey) {
    if (!engine) return false;

    ALEXIndexEngine* impl = reinterpret_cast<ALEXIndexEngine*>(engine);
    return impl->exists(ikey->indexOid, extract_int_from_key(ikey));
}

void indexengine_clear_range(IndexEngine* engine, NRIndexKey start_key, NRIndexKey end_key) {
    elog(WARNING, "IndexEngine: clear_range not supported");
}

uint64_t indexengine_get_count(IndexEngine* engine, Oid indexOid) {
    if (!engine) return 0;

    ALEXIndexEngine* impl = reinterpret_cast<ALEXIndexEngine*>(engine);
    return impl->getCount(indexOid);
}

void indexengine_compact(IndexEngine* engine) {
    // No-op for in-memory indexes
}

void indexengine_bulk_load(IndexEngine* engine,
                           Oid indexOid,
                           int64_t* keys,
                           uint64_t* values,
                           int count) {
    if (!engine) return;

    ALEXIndexEngine* impl = reinterpret_cast<ALEXIndexEngine*>(engine);
    impl->bulkLoad(indexOid, keys, values, count);
}

} // extern "C"
