/* ------------------------------------------------------------------------
 * nrindex_kv.c
 * NeurDB Index key-value implementation for nrindex access method.
 * ------------------------------------------------------------------------
 */

#include "nrindex_kv.h"
#include "nram_storage/rocks_service.h"
#include "nram_storage/rocks_handler.h"
#include "utils/datum.h"
#include "utils/lsyscache.h"
#include "access/htup_details.h"
#include "catalog/pg_type.h"
#include "utils/builtins.h"
#include "utils/rel.h"
#include "utils/memutils.h"

/* ------------------------------------------------------------------------
 * Index key implementation
 * ------------------------------------------------------------------------
 */

NRIndexKey
nrindex_key_create(Oid indexOid, Datum *values, bool *isnull, int nkeys, TupleDesc indexTupDesc)
{
    NRIndexKey ikey;
    Size total_size;
    char *pos;
    Size *lens;

    elog(DEBUG1, "nrindex_key_create: indexOid=%u, nkeys=%d", indexOid, nkeys);

    /* Calculate total size needed */
    total_size = offsetof(NRIndexKeyData, key_data);
    lens = palloc(sizeof(Size) * nkeys);

    for (int i = 0; i < nkeys; i++) {
        if (!isnull[i]) {
            Form_pg_attribute attr = TupleDescAttr(indexTupDesc, i);
            lens[i] = datumEstimateSpace(values[i], false, attr->attbyval, attr->attlen);
            total_size += lens[i];
            elog(DEBUG1, "  Key[%d]: type=%u, len=%zu, isnull=false", i, attr->atttypid, lens[i]);
        } else {
            lens[i] = 0;
            elog(DEBUG1, "  Key[%d]: isnull=true", i);
        }
    }

    /* Allocate key structure */
    ikey = (NRIndexKey)palloc0(total_size);
    ikey->indexOid = indexOid;
    ikey->key_size = total_size - offsetof(NRIndexKeyData, key_data);

    elog(DEBUG1, "  Total key_size=%u, total_struct_size=%zu", ikey->key_size, total_size);

    /* Serialize key values */
    pos = ikey->key_data;
    for (int i = 0; i < nkeys; i++) {
        if (!isnull[i]) {
            Form_pg_attribute attr = TupleDescAttr(indexTupDesc, i);
            datumSerialize(values[i], false, attr->attbyval, attr->attlen, &pos);
        }
    }

    pfree(lens);
    return ikey;
}

char *
nrindex_key_serialize(NRIndexKey ikey, Size *out_len)
{
    char *buf;
    
    *out_len = sizeof(Oid) + sizeof(uint32) + ikey->key_size;
    buf = palloc0(*out_len);
    
    memcpy(buf, &ikey->indexOid, sizeof(Oid));
    memcpy(buf + sizeof(Oid), &ikey->key_size, sizeof(uint32));
    memcpy(buf + sizeof(Oid) + sizeof(uint32), ikey->key_data, ikey->key_size);
    
    return buf;
}

NRIndexKey
nrindex_key_deserialize(const char *buf, Size len)
{
    NRIndexKey ikey;
    uint32 key_size;
    
    if (len < sizeof(Oid) + sizeof(uint32)) {
        elog(ERROR, "nrindex_key_deserialize: buffer too small");
    }
    
    key_size = *(uint32*)(buf + sizeof(Oid));
    
    if (len != sizeof(Oid) + sizeof(uint32) + key_size) {
        elog(ERROR, "nrindex_key_deserialize: buffer size mismatch");
    }
    
    ikey = (NRIndexKey)palloc0(offsetof(NRIndexKeyData, key_data) + key_size);
    memcpy(&ikey->indexOid, buf, sizeof(Oid));
    ikey->key_size = key_size;
    memcpy(ikey->key_data, buf + sizeof(Oid) + sizeof(uint32), key_size);
    
    return ikey;
}

NRIndexKey
nrindex_key_copy(NRIndexKey src)
{
    NRIndexKey dst;
    Size size = offsetof(NRIndexKeyData, key_data) + src->key_size;
    
    dst = (NRIndexKey)palloc0(size);
    memcpy(dst, src, size);
    
    return dst;
}

void
nrindex_key_free(NRIndexKey ikey)
{
    if (ikey) {
        pfree(ikey);
    }
}

int
nrindex_key_compare(NRIndexKey key1, NRIndexKey key2)
{
    if (key1->indexOid != key2->indexOid) {
        return (key1->indexOid < key2->indexOid) ? -1 : 1;
    }
    
    /* Compare serialized key data */
    int cmp = memcmp(key1->key_data, key2->key_data, 
                     Min(key1->key_size, key2->key_size));
    if (cmp != 0) {
        return cmp;
    }
    
    /* If one is longer, it's greater */
    if (key1->key_size != key2->key_size) {
        return (key1->key_size < key2->key_size) ? -1 : 1;
    }
    
    return 0;
}

bool
nrindex_key_matches_scan(NRIndexKey ikey, ScanKey scankey, int nscankeys)
{
    /* For now, implement a simple approach */
    /* TODO: Properly deserialize key values and compare with scan keys */
    return true;
}

/* ------------------------------------------------------------------------
 * Index value implementation
 * ------------------------------------------------------------------------
 */

NRIndexValue
nrindex_value_create(ItemPointer heap_tid)
{
    NRIndexValue ivalue;
    
    ivalue = (NRIndexValue)palloc0(sizeof(NRIndexValueData));
    ivalue->heap_tid = *heap_tid;
    ivalue->xact_id = GetCurrentTransactionId();
    ivalue->flags = 0;
    
    return ivalue;
}

char *
nrindex_value_serialize(NRIndexValue ivalue, Size *out_len)
{
    char *buf;
    
    *out_len = sizeof(NRIndexValueData);
    buf = palloc0(*out_len);
    memcpy(buf, ivalue, *out_len);
    
    return buf;
}

NRIndexValue
nrindex_value_deserialize(const char *buf, Size len)
{
    NRIndexValue ivalue;
    
    if (len != sizeof(NRIndexValueData)) {
        elog(ERROR, "nrindex_value_deserialize: invalid buffer size");
    }
    
    ivalue = (NRIndexValue)palloc0(sizeof(NRIndexValueData));
    memcpy(ivalue, buf, sizeof(NRIndexValueData));
    
    return ivalue;
}

NRIndexValue
nrindex_value_copy(NRIndexValue src)
{
    NRIndexValue dst;
    
    dst = (NRIndexValue)palloc0(sizeof(NRIndexValueData));
    *dst = *src;
    
    return dst;
}

void
nrindex_value_free(NRIndexValue ivalue)
{
    if (ivalue) {
        pfree(ivalue);
    }
}

/* ------------------------------------------------------------------------
 * Index-specific RocksDB operations
 * ------------------------------------------------------------------------
 */

NRIndexValue
nrindex_rocks_get(NRIndexKey ikey)
{
    /* Use direct index handler */
    return RocksClientIndexGet(ikey);
}

bool
nrindex_rocks_put(NRIndexKey ikey, NRIndexValue ivalue)
{
    bool result;

    elog(DEBUG1, "nrindex_rocks_put: indexOid=%u, key_size=%u",
         ikey->indexOid, ikey->key_size);
    elog(DEBUG1, "  heap_tid=(%u,%u), xact_id=%u, flags=%u",
         ItemPointerGetBlockNumber(&ivalue->heap_tid),
         ItemPointerGetOffsetNumber(&ivalue->heap_tid),
         ivalue->xact_id, ivalue->flags);

    /* Use direct index handler */
    result = RocksClientIndexPut(ikey, ivalue); // 发送 IPC 消息

    elog(DEBUG1, "  RocksDB put result: %s", result ? "success" : "failed");
    return result;
}

bool
nrindex_rocks_delete(NRIndexKey ikey)
{
    /* Use direct index handler */
    return RocksClientIndexDelete(ikey);
}

bool
nrindex_rocks_range_scan(NRIndexKey min_key, NRIndexKey max_key,
                        NRIndexKey **keys_out, NRIndexValue **values_out,
                        int *count_out)
{
    /* Use direct index handler */
    return RocksClientIndexRangeScan(min_key, max_key, keys_out, values_out, count_out);
}
