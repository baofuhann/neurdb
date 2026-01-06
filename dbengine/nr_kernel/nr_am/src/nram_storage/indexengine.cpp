/* -------------------------------------------------------------------------
 * indexengine.cpp
 * LIPP-based learned index storage engine
 *
 * This implementation uses LIPP (Learned Index with Precise Positions)
 * for efficient key-value operations with learned index structure.
 *
 * IMPORTANT: LIPP uses union internally, so value type must be POD.
 * We use uint64_t to store compressed heap_tid (BlockNumber + OffsetNumber).
 * -------------------------------------------------------------------------
 */

extern "C" {
#include "indexengine.h"
#include "nrindex_access/nrindex_kv.h"
#include "utils/memutils.h"
#include "postgres.h"
#include "storage/itemptr.h"
}

#include "lipp/src/core/lipp.h"
#include <map>
#include <string>
#include <vector>
#include <algorithm>

/* -------------------------------------------------------------------------
 * Key encoding/decoding for LIPP
 *
 * LIPP requires numeric keys. We encode int32 values as int64_t with
 * sign bit flipping to ensure correct sort order:
 *   - Negative numbers: sign bit 1 -> 0 (comes before positive)
 *   - Positive numbers: sign bit 0 -> 1 (comes after negative)
 * -------------------------------------------------------------------------
 */

/* Encode int32 value to int64_t key for LIPP */
static inline int64_t encode_lipp_key(int32_t val) {
    /* Flip sign bit: ensures -100 < 0 < 100 in lexicographic order */
    return (int64_t)((uint32_t)val ^ 0x80000000);
}

/* Decode int64_t key back to int32 value */
static inline int32_t decode_lipp_key(int64_t key) {
    return (int32_t)((uint32_t)key ^ 0x80000000);
}

/* Extract int32 value from NRIndexKey */
static inline int32_t extract_int_from_key(NRIndexKey ikey) {
    if (ikey->key_size < 4) {
        elog(ERROR, "LIPP: key_size too small (%u), expected >= 4", ikey->key_size);
    }

    /* Key data is stored in big-endian format with sign bit flipped.
     * We need to decode it back to get the original int32 value. */
    const unsigned char* buf = (const unsigned char*)ikey->key_data;
    uint32_t encoded = ((uint32_t)buf[0] << 24) |
                       ((uint32_t)buf[1] << 16) |
                       ((uint32_t)buf[2] << 8) |
                       ((uint32_t)buf[3]);

    /* Flip sign bit back to get original value */
    return (int32_t)(encoded ^ 0x80000000);
}

/* -------------------------------------------------------------------------
 * Value encoding/decoding for LIPP
 *
 * We compress NRIndexValue into a uint64_t:
 *   - High 32 bits: BlockNumber
 *   - Low 16 bits: OffsetNumber
 *   - Middle 16 bits: reserved (set to 0)
 *
 * Note: xact_id and flags are not stored (simplified for now)
 * -------------------------------------------------------------------------
 */

/* Compress heap_tid into uint64_t */
static inline uint64_t compress_heap_tid(ItemPointer tid) {
    BlockNumber blk = ItemPointerGetBlockNumber(tid);
    OffsetNumber off = ItemPointerGetOffsetNumber(tid);
    return ((uint64_t)blk << 32) | (uint64_t)off;
}

/* Decompress uint64_t back to heap_tid */
static inline void decompress_heap_tid(uint64_t compressed, ItemPointer tid) {
    BlockNumber blk = (BlockNumber)(compressed >> 32);
    OffsetNumber off = (OffsetNumber)(compressed & 0xFFFF);
    ItemPointerSet(tid, blk, off);
}

/* -------------------------------------------------------------------------
 * LIPP Index Engine Implementation
 *
 * Each index (identified by indexOid) has its own LIPP instance.
 * This provides natural isolation between different indexes.
 *
 * LIPP<int64_t, uint64_t>:
 *   - Key: encoded int value (with sign bit flip)
 *   - Value: compressed heap_tid (POD type, safe in union)
 * -------------------------------------------------------------------------
 */

class LIPPIndexEngine {
private:
    /* Map from indexOid to LIPP instance
     * Using uint64_t as value type (POD, safe in LIPP's union) */
    std::map<Oid, LIPP<int64_t, uint64_t>*> indexes;

public:
    LIPPIndexEngine() {
        elog(LOG, "LIPP IndexEngine created");
    }

    ~LIPPIndexEngine() {
        /* Clean up all LIPP instances */
        for (auto& pair : indexes) {
            delete pair.second;
        }
        indexes.clear();
        elog(LOG, "LIPP IndexEngine destroyed");
    }

    /* Get or create LIPP instance for an index */
    LIPP<int64_t, uint64_t>* getIndex(Oid indexOid) {
        auto it = indexes.find(indexOid);
        if (it == indexes.end()) {
            /* Create new LIPP instance for this index */
            LIPP<int64_t, uint64_t>* lipp = new LIPP<int64_t, uint64_t>();
            indexes[indexOid] = lipp;
            elog(LOG, "LIPP: Created new index instance for indexOid=%u", indexOid);
            return lipp;
        }
        return it->second;
    }

    /* Insert key-value pair */
    void put(Oid indexOid, int32_t val, uint64_t compressed_tid) {
        LIPP<int64_t, uint64_t>* lipp = getIndex(indexOid);
        int64_t key = encode_lipp_key(val);

        elog(NOTICE, "LIPP: calling lipp->insert(key=%ld, val=%d)", key, val);
        lipp->insert(key, compressed_tid);
        elog(NOTICE, "LIPP: insert done, indexOid=%u, val=%d, tid=%lu",
             indexOid, val, compressed_tid);
    }

    /* Get value by key */
    bool get(Oid indexOid, int32_t val, uint64_t* compressed_tid) {
        auto it = indexes.find(indexOid);
        if (it == indexes.end()) {
            return false;
        }

        LIPP<int64_t, uint64_t>* lipp = it->second;
        int64_t key = encode_lipp_key(val);

        if (lipp->exists(key)) {
            *compressed_tid = lipp->at(key);
            elog(DEBUG1, "LIPP get: indexOid=%u, val=%d, found=true", indexOid, val);
            return true;
        }
        elog(DEBUG1, "LIPP get: indexOid=%u, val=%d, found=false", indexOid, val);
        return false;
    }

    /* Check if key exists */
    bool exists(Oid indexOid, int32_t val) {
        auto it = indexes.find(indexOid);
        if (it == indexes.end()) {
            return false;
        }

        LIPP<int64_t, uint64_t>* lipp = it->second;
        int64_t key = encode_lipp_key(val);
        return lipp->exists(key);
    }

    /* Get count of entries for an index (approximate) */
    size_t getCount(Oid indexOid) {
        auto it = indexes.find(indexOid);
        if (it == indexes.end()) {
            return 0;
        }
        return it->second->index_size();
    }

    /* Bulk load - much faster than individual inserts for index building */
    void bulkLoad(Oid indexOid, int32_t* keys, uint64_t* values, int count) {
        if (count <= 0) {
            return;
        }

        elog(LOG, "LIPP: bulkLoad starting, indexOid=%u, count=%d", indexOid, count);

        /* Create sorted array of key-value pairs for LIPP */
        typedef std::pair<int64_t, uint64_t> KVPair;
        std::vector<KVPair> pairs;
        pairs.reserve(count);

        for (int i = 0; i < count; i++) {
            int64_t encoded_key = encode_lipp_key(keys[i]);
            pairs.push_back(std::make_pair(encoded_key, values[i]));
        }

        /* Sort by key (LIPP bulk_load requires sorted data) */
        std::sort(pairs.begin(), pairs.end(),
                  [](const KVPair& a, const KVPair& b) {
                      return a.first < b.first;
                  });

        /* Remove duplicates (keep last occurrence for each key) */
        auto last = std::unique(pairs.begin(), pairs.end(),
                                [](const KVPair& a, const KVPair& b) {
                                    return a.first == b.first;
                                });
        pairs.erase(last, pairs.end());

        elog(LOG, "LIPP: bulkLoad after dedup, unique_count=%zu", pairs.size());

        /* Get or create LIPP instance */
        LIPP<int64_t, uint64_t>* lipp = getIndex(indexOid);

        /* Call LIPP bulk_load */
        lipp->bulk_load(pairs.data(), pairs.size());

        elog(LOG, "LIPP: bulkLoad completed, indexOid=%u, loaded=%zu entries",
             indexOid, pairs.size());
    }
};

/* -------------------------------------------------------------------------
 * C interface implementation
 * -------------------------------------------------------------------------
 */

extern "C" {

IndexEngine* indexengine_open(void) {
    try {
        return reinterpret_cast<IndexEngine*>(new LIPPIndexEngine());
    } catch (const std::exception& e) {
        elog(ERROR, "Failed to create LIPP IndexEngine: %s", e.what());
        return nullptr;
    }
}

void indexengine_close(IndexEngine* engine) {
    if (engine) {
        delete reinterpret_cast<LIPPIndexEngine*>(engine);
    }
}

void indexengine_put(IndexEngine* engine, NRIndexKey ikey, NRIndexValue ivalue) {
    if (!engine) {
        elog(ERROR, "LIPP IndexEngine: null engine pointer");
        return;
    }

    try {
        LIPPIndexEngine* impl = reinterpret_cast<LIPPIndexEngine*>(engine);

        /* Extract indexOid and int value from key */
        Oid indexOid = ikey->indexOid;
        int32_t val = extract_int_from_key(ikey);

        /* Compress heap_tid into uint64_t */
        uint64_t compressed_tid = compress_heap_tid(&ivalue->heap_tid);

        impl->put(indexOid, val, compressed_tid);
    } catch (const std::exception& e) {
        elog(ERROR, "LIPP IndexEngine put failed: %s", e.what());
    }
}

NRIndexValue indexengine_get(IndexEngine* engine, NRIndexKey ikey) {
    if (!engine) {
        elog(ERROR, "LIPP IndexEngine: null engine pointer");
        return nullptr;
    }

    try {
        LIPPIndexEngine* impl = reinterpret_cast<LIPPIndexEngine*>(engine);

        /* Extract indexOid and int value from key */
        Oid indexOid = ikey->indexOid;
        int32_t val = extract_int_from_key(ikey);

        uint64_t compressed_tid;
        if (impl->get(indexOid, val, &compressed_tid)) {
            /* Allocate and populate NRIndexValue */
            NRIndexValue ivalue = (NRIndexValue)palloc0(sizeof(NRIndexValueData));
            decompress_heap_tid(compressed_tid, &ivalue->heap_tid);
            ivalue->xact_id = InvalidTransactionId;  /* Not stored in LIPP */
            ivalue->flags = 0;
            return ivalue;
        }
        return nullptr;
    } catch (const std::exception& e) {
        elog(ERROR, "LIPP IndexEngine get failed: %s", e.what());
        return nullptr;
    }
}

void indexengine_delete(IndexEngine* engine, NRIndexKey ikey) {
    if (!engine) {
        elog(ERROR, "LIPP IndexEngine: null engine pointer");
        return;
    }

    /* LIPP does not support delete operation */
    elog(WARNING, "LIPP IndexEngine: delete operation not supported, ignoring");
}

void indexengine_range_scan(IndexEngine* engine,
                           NRIndexKey start_key,
                           NRIndexKey end_key,
                           uint32_t* out_count,
                           NRIndexKey** keys,
                           NRIndexValue** values) {
    if (!engine) {
        elog(ERROR, "LIPP IndexEngine: null engine pointer");
        *out_count = 0;
        *keys = nullptr;
        *values = nullptr;
        return;
    }

    /* Initialize output */
    *out_count = 0;
    *keys = nullptr;
    *values = nullptr;

    /* Check if this is an equality query (start_key == end_key) */
    if (start_key && end_key &&
        start_key->indexOid == end_key->indexOid &&
        start_key->key_size == end_key->key_size &&
        memcmp(start_key->key_data, end_key->key_data, start_key->key_size) == 0) {

        /* Equality query - use LIPP point lookup */
        try {
            LIPPIndexEngine* impl = reinterpret_cast<LIPPIndexEngine*>(engine);
            Oid indexOid = start_key->indexOid;
            int32_t val = extract_int_from_key(start_key);

            uint64_t compressed_tid;
            if (impl->get(indexOid, val, &compressed_tid)) {
                /* Found! Return single result */
                *out_count = 1;
                *keys = (NRIndexKey*)palloc(sizeof(NRIndexKey));
                *values = (NRIndexValue*)palloc(sizeof(NRIndexValue));

                /* Copy the key */
                (*keys)[0] = nrindex_key_copy(start_key);

                /* Create value from compressed tid */
                (*values)[0] = (NRIndexValue)palloc0(sizeof(NRIndexValueData));
                decompress_heap_tid(compressed_tid, &(*values)[0]->heap_tid);
                (*values)[0]->xact_id = InvalidTransactionId;
                (*values)[0]->flags = 0;

                elog(NOTICE, "LIPP: equality query found val=%d, tid=(%u,%u)",
                     val,
                     ItemPointerGetBlockNumber(&(*values)[0]->heap_tid),
                     ItemPointerGetOffsetNumber(&(*values)[0]->heap_tid));
            } else {
                elog(NOTICE, "LIPP: equality query not found val=%d", val);
            }
        } catch (const std::exception& e) {
            elog(ERROR, "LIPP IndexEngine range scan failed: %s", e.what());
        }
    } else {
        /* True range query - not supported yet */
        elog(WARNING, "LIPP IndexEngine: true range scan not supported yet");
    }
}

bool indexengine_exists(IndexEngine* engine, NRIndexKey ikey) {
    if (!engine) {
        elog(ERROR, "LIPP IndexEngine: null engine pointer");
        return false;
    }

    try {
        LIPPIndexEngine* impl = reinterpret_cast<LIPPIndexEngine*>(engine);

        /* Extract indexOid and int value from key */
        Oid indexOid = ikey->indexOid;
        int32_t val = extract_int_from_key(ikey);

        return impl->exists(indexOid, val);
    } catch (const std::exception& e) {
        elog(ERROR, "LIPP IndexEngine exists failed: %s", e.what());
        return false;
    }
}

void indexengine_clear_range(IndexEngine* engine, NRIndexKey start_key, NRIndexKey end_key) {
    if (!engine) {
        elog(ERROR, "LIPP IndexEngine: null engine pointer");
        return;
    }

    /* LIPP does not support range clear */
    elog(WARNING, "LIPP IndexEngine: clear_range operation not supported, ignoring");
}

uint64_t indexengine_get_count(IndexEngine* engine, Oid indexOid) {
    if (!engine) {
        elog(ERROR, "LIPP IndexEngine: null engine pointer");
        return 0;
    }

    try {
        LIPPIndexEngine* impl = reinterpret_cast<LIPPIndexEngine*>(engine);
        return impl->getCount(indexOid);
    } catch (const std::exception& e) {
        elog(ERROR, "LIPP IndexEngine get count failed: %s", e.what());
        return 0;
    }
}

void indexengine_compact(IndexEngine* engine) {
    if (!engine) {
        elog(ERROR, "LIPP IndexEngine: null engine pointer");
        return;
    }

    /* No-op for LIPP - it's an in-memory structure */
    elog(DEBUG1, "LIPP IndexEngine: compact is no-op for in-memory index");
}

void indexengine_bulk_load(IndexEngine* engine,
                           Oid indexOid,
                           int32_t* keys,
                           uint64_t* values,
                           int count) {
    if (!engine) {
        elog(ERROR, "LIPP IndexEngine: null engine pointer");
        return;
    }

    try {
        LIPPIndexEngine* impl = reinterpret_cast<LIPPIndexEngine*>(engine);
        impl->bulkLoad(indexOid, keys, values, count);
    } catch (const std::exception& e) {
        elog(ERROR, "LIPP IndexEngine bulk_load failed: %s", e.what());
    }
}

} // extern "C"
