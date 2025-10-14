#include "nrindex.h"
#include "nrindex_access/nrindex_kv.h"
#include "postgres.h"
#include "access/amapi.h"
#include "access/reloptions.h"
#include "access/relscan.h"
#include "catalog/index.h"
#include "commands/vacuum.h"
#include "nodes/pathnodes.h"
#include "utils/guc.h"
#include "utils/rel.h"
#include "utils/memutils.h"
#include "utils/builtins.h"
#include "storage/ipc.h"
#include "storage/lwlock.h"
#include "storage/shmem.h"
#include "fmgr.h"
#include "access/heapam.h"
#include "access/htup_details.h"
#include "executor/tuptable.h"
#include "utils/elog.h"
#include "utils/snapmgr.h"
#include "access/xact.h"
#include "access/heapam.h"
#include "access/multixact.h"
#include "nram_storage/rocks_service.h"
#include "nram_storage/rocks_handler.h"
#include "nram_access/kv.h"
#include "nram_xact/xact.h"
#include "nram_xact/action.h"

PG_MODULE_MAGIC;

/* ------------------------------------------------------------------------
 * Global variables and structures
 * ------------------------------------------------------------------------
 */

/* Index scan descriptor for nrindex - now using proper index structures */

/* Index build state for nrindex */
typedef struct NRIndexBuildState
{
    Relation heap;
    Relation index;
    IndexInfo *indexInfo;
    NRIndexKey **keys;
    NRIndexValue **values;
    int count;
    int capacity;
} NRIndexBuildState;

/* ------------------------------------------------------------------------
 * Helper functions
 * ------------------------------------------------------------------------
 */

/* Helper functions now use the new index key-value structures */

/* ------------------------------------------------------------------------
 * Index AM implementation functions
 * ------------------------------------------------------------------------
 */

/*
 * Build a new index.
 */
static IndexBuildResult *
nrindex_build(Relation heap, Relation index, IndexInfo *indexInfo)
{
    IndexBuildResult *result;
    TableScanDesc scan;
    HeapTuple heapTuple;
    TupleDesc heapTupDesc;
    TupleDesc indexTupDesc;
    Datum values[INDEX_MAX_KEYS];
    bool isnull[INDEX_MAX_KEYS];
    int nkeys;
    int ntuples = 0;
    
    heapTupDesc = RelationGetDescr(heap);
    indexTupDesc = RelationGetDescr(index);
    nkeys = indexInfo->ii_NumIndexKeyAttrs;
    
    result = (IndexBuildResult *) palloc(sizeof(IndexBuildResult));
    
    /* Start a heap scan */
    scan = table_beginscan(heap, SnapshotAny, 0, NULL);
    
    /* Process each tuple in the heap */
    while ((heapTuple = heap_getnext(scan, ForwardScanDirection)) != NULL) {
        /* Extract index key values from heap tuple */
        for (int i = 0; i < nkeys; i++) {
            int heapAttrNum = indexInfo->ii_IndexAttrNumbers[i];
            if (heapAttrNum == 0) {
                /* System column */
                values[i] = heap_getsysattr(heapTuple, heapAttrNum, heapTupDesc, &isnull[i]);
            } else {
                /* Regular column */
                values[i] = heap_getattr(heapTuple, heapAttrNum, heapTupDesc, &isnull[i]);
            }
        }
        
        /* Build index entry using new index structures */
        NRIndexKey ikey = nrindex_key_create(index->rd_id, values, isnull, nkeys, indexTupDesc);
        NRIndexValue ivalue = nrindex_value_create(&heapTuple->t_self);
        
        /* Store in RocksDB */
        if (!nrindex_rocks_put(ikey, ivalue)) {
            elog(ERROR, "Failed to insert index entry during build");
        }
        
        ntuples++;
        
        nrindex_key_free(ikey);
        nrindex_value_free(ivalue);
    }
    
    table_endscan(scan);
    
    result->heap_tuples = ntuples;
    result->index_tuples = ntuples;
    
    return result;
}

/*
 * Build an empty index.
 */
static void
nrindex_buildempty(Relation index)
{
    /* No need to build an init fork for RocksDB-based index */
}

/*
 * Insert new tuple to index.
 */
static bool
nrindex_insert(Relation index, Datum *values, bool *isnull,
               ItemPointer ht_ctid, Relation heapRel,
               IndexUniqueCheck checkUnique,
               bool indexUnchanged,
               IndexInfo *indexInfo)
{
    NRIndexKey ikey;
    NRIndexValue ivalue;
    bool result = true;
    
    /* Build index key and value using new structures */
    ikey = nrindex_key_create(index->rd_id, values, isnull, indexInfo->ii_NumIndexKeyAttrs, RelationGetDescr(index));
    ivalue = nrindex_value_create(ht_ctid);
    
    /* Check for uniqueness if required */
    if (checkUnique != UNIQUE_CHECK_NO) {
        NRIndexValue existing_value = nrindex_rocks_get(ikey);
        if (existing_value != NULL) {
            /* Check if it's the same tuple */
            if (!ItemPointerEquals(ht_ctid, &existing_value->heap_tid)) {
                result = false; /* Duplicate key violation */
            }
            nrindex_value_free(existing_value);
        }
    }
    
    if (result) {
        /* Store in RocksDB */
        if (!nrindex_rocks_put(ikey, ivalue)) {
            elog(ERROR, "Failed to insert index entry");
        }
    }
    
    nrindex_key_free(ikey);
    nrindex_value_free(ivalue);
    
    return result;
}

/*
 * Bulk deletion of index entries.
 */
static IndexBulkDeleteResult *
nrindex_bulkdelete(IndexVacuumInfo *info, IndexBulkDeleteResult *stats,
                   IndexBulkDeleteCallback callback, void *callback_state)
{
    /* For now, return NULL indicating no work was done */
    /* TODO: Implement bulk delete using RocksDB range operations */
    return NULL;
}

/*
 * Post-VACUUM cleanup for index.
 */
static IndexBulkDeleteResult *
nrindex_vacuumcleanup(IndexVacuumInfo *info, IndexBulkDeleteResult *stats)
{
    /* For now, return NULL indicating no work was done */
    /* TODO: Implement vacuum cleanup */
    return NULL;
}

/*
 * Estimate cost of using this index.
 */
static void
nrindex_costestimate(PlannerInfo *root, IndexPath *path, double loop_count,
                     Cost *indexStartupCost, Cost *indexTotalCost,
                     Selectivity *indexSelectivity, double *indexCorrelation,
                     double *indexPages)
{
    /* Simple cost estimation */
    *indexStartupCost = 1.0;
    *indexTotalCost = path->path.rows + 1.0;
    *indexSelectivity = 1.0;
    *indexCorrelation = 0.0;
    *indexPages = 1.0;
}

/*
 * Parse relation options for index.
 */
static bytea *
nrindex_options(Datum reloptions, bool validate)
{
    /* No special options for now */
    return NULL;
}

/*
 * Validate operator class for index.
 */
static bool
nrindex_validate(Oid opclassoid)
{
    /* Accept any operator class for now */
    return true;
}

/*
 * Begin scan of index.
 */
static IndexScanDesc
nrindex_beginscan(Relation r, int nkeys, int norderbys)
{
    NRIndexScanDesc scan;
    
    scan = (NRIndexScanDesc) RelationGetIndexScan(r, nkeys, norderbys);
    scan->min_key = NULL;
    scan->max_key = NULL;
    scan->results_key = NULL;
    scan->results = NULL;
    scan->result_count = 0;
    scan->cursor = 0;
    scan->is_range_scan = false;
    scan->is_null_scan = false;
    
    return (IndexScanDesc) scan;
}

/*
 * Rescan index.
 */
static void
nrindex_rescan(IndexScanDesc scan, ScanKey scankey, int nscankeys,
               ScanKey orderbys, int norderbys)
{
    NRIndexScanDesc nrscan = (NRIndexScanDesc) scan;
    
    /* Free previous results */
    if (nrscan->results_key) {
        for (int i = 0; i < nrscan->result_count; i++) {
            nrindex_key_free(nrscan->results_key[i]);
            nrindex_value_free(nrscan->results[i]);
        }
        pfree(nrscan->results_key);
        pfree(nrscan->results);
    }
    
    nrscan->result_count = 0;
    nrscan->cursor = 0;
    
    /* Build scan keys for RocksDB range scan */
    if (nscankeys > 0 && scankey[0].sk_flags & SK_ISNULL) {
        /* Handle IS NULL scan */
        nrscan->is_range_scan = false;
        nrscan->is_null_scan = true;
        /* TODO: Implement NULL handling */
    } else if (nscankeys > 0) {
        /* Range scan based on scan keys */
        /* TODO: Build proper min/max keys from scan keys */
        nrscan->min_key = NULL; /* Will be created from scan keys */
        nrscan->max_key = NULL; /* Will be created from scan keys */
        
        nrscan->is_range_scan = true;
        nrscan->is_null_scan = false;
        
        /* Perform range scan using new index functions */
        if (!nrindex_rocks_range_scan(nrscan->min_key, nrscan->max_key,
                                     &nrscan->results_key, &nrscan->results,
                                     &nrscan->result_count)) {
            elog(ERROR, "Failed to perform range scan");
        }
    }
}

/*
 * Get next tuple from index scan.
 */
static bool
nrindex_gettuple(IndexScanDesc scan, ScanDirection direction)
{
    NRIndexScanDesc nrscan = (NRIndexScanDesc) scan;
    
    if (direction != ForwardScanDirection) {
        elog(WARNING, "nrindex only supports forward scan");
        return false;
    }
    
    if (nrscan->cursor >= nrscan->result_count) {
        return false;
    }
    
    /* Get the current result */
    NRIndexKey ikey = nrscan->results_key[nrscan->cursor];
    NRIndexValue ivalue = nrscan->results[nrscan->cursor];
    
    /* Set the tuple identifier */
    scan->xs_heaptid = ivalue->heap_tid;
    
    nrscan->cursor++;
    
    return true;
}

/*
 * Get bitmap of matching tuples.
 */
static int64
nrindex_getbitmap(IndexScanDesc scan, TIDBitmap *tbm)
{
    NRIndexScanDesc nrscan = (NRIndexScanDesc) scan;
    int64 ntids = 0;
    
    /* Add all matching TIDs to bitmap */
    for (int i = 0; i < nrscan->result_count; i++) {
        NRIndexValue ivalue = nrscan->results[i];
        
        tbm_add_tuples(tbm, &ivalue->heap_tid, 1, false);
        ntids++;
    }
    
    return ntids;
}

/*
 * End scan of index.
 */
static void
nrindex_endscan(IndexScanDesc scan)
{
    NRIndexScanDesc nrscan = (NRIndexScanDesc) scan;
    
    /* Free scan results */
    if (nrscan->results_key) {
        for (int i = 0; i < nrscan->result_count; i++) {
            nrindex_key_free(nrscan->results_key[i]);
            nrindex_value_free(nrscan->results[i]);
        }
        pfree(nrscan->results_key);
        pfree(nrscan->results);
    }
    
    if (nrscan->min_key) nrindex_key_free(nrscan->min_key);
    if (nrscan->max_key) nrindex_key_free(nrscan->max_key);
}

/*
 * Index AM handler function: returns IndexAmRoutine with access method
 * parameters and callbacks.
 */
Datum nrindex_handler(PG_FUNCTION_ARGS);
PG_FUNCTION_INFO_V1(nrindex_handler);

Datum
nrindex_handler(PG_FUNCTION_ARGS)
{
    IndexAmRoutine *amroutine = makeNode(IndexAmRoutine);
    
    /* Set AM capabilities */
    amroutine->amstrategies = 0;  /* No fixed strategies */
    amroutine->amsupport = 1;     /* One support function */
    amroutine->amoptsprocnum = 0; /* No options procedure */
    amroutine->amcanorder = false;
    amroutine->amcanorderbyop = false;
    amroutine->amcanbackward = false;
    amroutine->amcanunique = true;
    amroutine->amcanmulticol = true;
    amroutine->amoptionalkey = true;
    amroutine->amsearcharray = false;
    amroutine->amsearchnulls = false;
    amroutine->amstorage = false;
    amroutine->amclusterable = false;
    amroutine->ampredlocks = false;
    amroutine->amcanparallel = false;
    amroutine->amcaninclude = false;
    amroutine->amusemaintenanceworkmem = false;
    amroutine->amsummarizing = false;
    amroutine->amparallelvacuumoptions = VACUUM_OPTION_NO_PARALLEL;
    amroutine->amkeytype = InvalidOid;
    
    /* Set function pointers */
    amroutine->ambuild = nrindex_build;
    amroutine->ambuildempty = nrindex_buildempty;
    amroutine->aminsert = nrindex_insert;
    amroutine->ambulkdelete = nrindex_bulkdelete;
    amroutine->amvacuumcleanup = nrindex_vacuumcleanup;
    amroutine->amcanreturn = NULL;
    amroutine->amcostestimate = nrindex_costestimate;
    amroutine->amoptions = nrindex_options;
    amroutine->amproperty = NULL;
    amroutine->ambuildphasename = NULL;
    amroutine->amvalidate = nrindex_validate;
    amroutine->amadjustmembers = NULL;
    amroutine->ambeginscan = nrindex_beginscan;
    amroutine->amrescan = nrindex_rescan;
    amroutine->amgettuple = nrindex_gettuple;
    amroutine->amgetbitmap = nrindex_getbitmap;
    amroutine->amendscan = nrindex_endscan;
    amroutine->ammarkpos = NULL;
    amroutine->amrestrpos = NULL;
    amroutine->amestimateparallelscan = NULL;
    amroutine->aminitparallelscan = NULL;
    amroutine->amparallelrescan = NULL;
    
    PG_RETURN_POINTER(amroutine);
}

/* ------------------------------------------------------------------------
 * Module initialization
 * ------------------------------------------------------------------------
 */

void
_PG_init(void)
{
    /* Initialize RocksDB service if not already done */
    nram_rocks_service_init();
}

void
_PG_fini(void)
{
    /* Cleanup if needed */
}
