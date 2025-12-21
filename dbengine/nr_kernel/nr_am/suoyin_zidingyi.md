# NeurDB 自定义索引实现详解

本文档详细介绍 NeurDB 中自定义索引（nrindex）的实现原理、架构设计和完整调用流程。

---

## 一、整体架构

### 1.1 多进程架构

PostgreSQL 是多进程架构，每个客户端连接对应一个独立的后端进程。但索引引擎只能有一个实例（否则数据会不一致），因此需要通过 IPC（进程间通信）来协调。

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              PostgreSQL 实例                                 │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐    │
│  │                         共享内存区域                                 │    │
│  │  ┌───────────────────────────────────────────────────────────────┐  │    │
│  │  │  KVChannel (环形缓冲区)                                        │  │    │
│  │  │  - 用于进程间传递消息                                          │  │    │
│  │  │  - 只是"通道"，不存储索引数据！                                │  │    │
│  │  └───────────────────────────────────────────────────────────────┘  │    │
│  │                                                                      │    │
│  │  ┌───────────────────────────────────────────────────────────────┐  │    │
│  │  │  PostgreSQL 表数据 (Buffer Pool)                               │  │    │
│  │  │  TID(0,1): {id:1, value:"Alice"}                              │  │    │
│  │  │  TID(0,2): {id:2, value:"Bob"}                                │  │    │
│  │  │  TID(0,3): {id:3, value:"Charlie"}                            │  │    │
│  │  └───────────────────────────────────────────────────────────────┘  │    │
│  └─────────────────────────────────────────────────────────────────────┘    │
│                                                                              │
│  ┌─────────────────────────┐         ┌────────────────────────────────┐    │
│  │  Backend Process        │         │  Rocks Service Process         │    │
│  │  (后端进程)             │         │  (后台工作进程)                 │    │
│  │                         │   IPC   │                                │    │
│  │  处理 SQL 查询          │ ◄─────► │  ┌────────────────────────┐   │    │
│  │  调用 nrindex_xxx()     │         │  │  IndexEngine           │   │    │
│  │                         │         │  │  (进程私有内存)         │   │    │
│  │                         │         │  │                        │   │    │
│  │                         │         │  │  std::map 存储索引:    │   │    │
│  │                         │         │  │  "Alice"   → (0,1)     │   │    │
│  │                         │         │  │  "Bob"     → (0,2)     │   │    │
│  │                         │         │  │  "Charlie" → (0,3)     │   │    │
│  │                         │         │  └────────────────────────┘   │    │
│  └─────────────────────────┘         └────────────────────────────────┘    │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 存储位置总结

| 组件 | 存储位置 | 说明 |
|------|----------|------|
| **KVChannel** | 共享内存 | 只是消息通道，不存数据 |
| **表数据** | 共享内存 (Buffer Pool) | PostgreSQL 管理 |
| **索引数据 (std::map)** | **Rocks Service 进程的私有内存** | 不在共享内存！ |

### 1.3 为什么需要 IPC？

```
问题：PostgreSQL 是多进程架构
─────────────────────────────────

每个客户端连接 = 一个独立的后端进程

  客户端1 ──→ Backend Process 1 (PID: 1001)
  客户端2 ──→ Backend Process 2 (PID: 1002)
  客户端3 ──→ Backend Process 3 (PID: 1003)

但是：存储引擎（IndexEngine）只能有一个实例！
     不能每个进程各自维护一个 std::map（数据会不一致）

解决方案：
─────────
  启动一个专用的后台工作进程（Rocks Service）
  所有后端进程通过 IPC 与它通信
```

---

## 二、核心组件说明

### 2.1 IPC (KVChannel)

**作用**：共享内存通道，允许后端进程与 Rocks Service 进程通信。

**实现文件**：`src/ipc/msg.c`

```c
// 基于共享内存的环形缓冲区
typedef struct KVChannelShared {
    LWLock lock;           // 互斥锁
    ConditionVariable cv;  // 条件变量（等待/唤醒）
    uint64 head;           // 读指针
    uint64 tail;           // 写指针
    char buffer[...];      // 环形缓冲区
} KVChannelShared;

// 初始化（使用 PostgreSQL 共享内存）
KVChannel* KVChannelInit(const char* name, bool create) {
    KVChannelShared* shared = ShmemInitStruct(name, ...);  // PG共享内存
    ...
}
```

### 2.2 RocksClient

**作用**：客户端 API，运行在后端进程中，向 Rocks Service 发送请求。

**实现文件**：`src/nram_storage/rocks_handler.c`

```c
// 索引查询
NRIndexValue RocksClientIndexGet(NRIndexKey ikey) {
    // 序列化 key
    char *serialized_key = nrindex_key_serialize(ikey, &key_len);

    // 构建消息
    KVMsg *msg = NewMsg(kv_index_get, ...);

    // 通过共享内存发送请求
    KVChannelPushMsg(req_chan, msg, -1);

    // 等待响应
    resp = KVChannelPopMsg(resp_chan, -1);

    // 反序列化结果
    return nrindex_value_deserialize(resp->entity, ...);
}

// 其他操作
bool RocksClientIndexPut(NRIndexKey ikey, NRIndexValue ivalue);
bool RocksClientIndexDelete(NRIndexKey ikey);
bool RocksClientIndexRangeScan(...);
```

### 2.3 Rocks Service

**作用**：后台工作进程，运行 IndexEngine，处理所有存储请求。

**实现文件**：`src/nram_storage/rocks_service.c`

```c
void run_rocks(int num_threads) {
    channel = KVChannelInit(ROCKSDB_CHANNEL, true);

    while (rocks_service_running) {
        // 从通道接收消息
        KVMsg* msg = KVChannelPopMsg(channel, timeout);

        // 分发处理
        switch (msg->header.op) {
            case kv_index_get:
                resp = handle_kv_index_get(msg);
                break;
            case kv_index_put:
                resp = handle_kv_index_put(msg);
                break;
            case kv_index_delete:
                resp = handle_kv_index_delete(msg);
                break;
            case kv_index_range_scan:
                resp = handle_kv_index_range_scan(msg);
                break;
        }

        // 发送响应
        ResultQueuePush(&result_queue, resp);
    }
}
```

### 2.4 IndexEngine

**作用**：实际的索引存储引擎，使用 C++ 的 `std::map` 实现。

**实现文件**：`src/nram_storage/indexengine.cpp`

```cpp
class IndexEngineImpl {
private:
    std::map<std::string, std::string> data_store;  // 索引数据

public:
    void put(const std::string& key, const std::string& value) {
        data_store[key] = value;  // map 插入
    }

    bool get(const std::string& key, std::string* value) {
        auto it = data_store.find(key);  // map 查找
        if (it != data_store.end()) {
            *value = it->second;
            return true;
        }
        return false;
    }

    void rangeScan(const std::string& start, const std::string& end, ...) {
        auto it = data_store.lower_bound(start);  // map 范围查找
        while (it != data_store.end() && it->first < end) {
            results.push_back(*it);
            ++it;
        }
    }
};
```

**简单理解**：

```
indexengine_xxx() = 对 std::map 的增删改查操作

indexengine_put()        →  std::map[key] = value
indexengine_get()        →  std::map.find(key)
indexengine_delete()     →  std::map.erase(key)
indexengine_range_scan() →  std::map.lower_bound() 遍历
```

---

## 三、完整调用链

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           完整调用链                                         │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  第1层: Index AM (nrindex.c)                                                │
│  ─────────────────────────────                                               │
│  nrindex_build()      →  nrindex_rocks_put()                                │
│  nrindex_insert()     →  nrindex_rocks_put() / nrindex_rocks_get()          │
│  nrindex_rescan()     →  nrindex_rocks_range_scan()                         │
│                                                                              │
│                              │                                               │
│                              ▼                                               │
│  第2层: 索引 KV 封装 (nrindex_kv.c)                                         │
│  ────────────────────────────────                                            │
│  nrindex_rocks_get()        →  RocksClientIndexGet()                        │
│  nrindex_rocks_put()        →  RocksClientIndexPut()                        │
│  nrindex_rocks_delete()     →  RocksClientIndexDelete()                     │
│  nrindex_rocks_range_scan() →  RocksClientIndexRangeScan()                  │
│                                                                              │
│                              │                                               │
│                              ▼                                               │
│  第3层: RocksClient (rocks_handler.c) - 发送 IPC 消息                       │
│  ──────────────────────────────────────────────────────                      │
│  RocksClientIndexGet()      →  KVChannelPushMsg(kv_index_get)               │
│  RocksClientIndexPut()      →  KVChannelPushMsg(kv_index_put)               │
│  RocksClientIndexDelete()   →  KVChannelPushMsg(kv_index_delete)            │
│  RocksClientIndexRangeScan()→  KVChannelPushMsg(kv_index_range_scan)        │
│                                                                              │
│                              │                                               │
│                              │  共享内存 IPC                                 │
│                              ▼                                               │
│  第4层: Rocks Service (rocks_service.c) - 处理消息                          │
│  ──────────────────────────────────────────────────                          │
│  process_request()                                                           │
│    switch(msg->op):                                                          │
│      kv_index_get        →  handle_kv_index_get()                           │
│      kv_index_put        →  handle_kv_index_put()                           │
│      kv_index_delete     →  handle_kv_index_delete()                        │
│      kv_index_range_scan →  handle_kv_index_range_scan()                    │
│                                                                              │
│                              │                                               │
│                              ▼                                               │
│  第5层: IndexEngine (indexengine.cpp) - 实际存储                            │
│  ───────────────────────────────────────────────                             │
│  handle_kv_index_get()      →  indexengine_get()      →  std::map::find()   │
│  handle_kv_index_put()      →  indexengine_put()      →  std::map::insert() │
│  handle_kv_index_delete()   →  indexengine_delete()   →  std::map::erase()  │
│  handle_kv_index_range_scan()→ indexengine_range_scan()→ std::map::lower_bound()│
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 代码对应关系

| 层级 | 文件 | 函数示例 |
|------|------|----------|
| **Index AM** | `nrindex.c` | `nrindex_rescan()` |
| **KV 封装** | `nrindex_kv.c` | `nrindex_rocks_range_scan()` |
| **Client** | `rocks_handler.c` | `RocksClientIndexRangeScan()` |
| **IPC** | `msg.c` | `KVChannelPushMsg()` / `KVChannelPopMsg()` |
| **Service** | `rocks_service.c` | `handle_kv_index_range_scan()` |
| **Engine** | `indexengine.cpp` | `indexengine_range_scan()` |

---

## 四、具体例子：CREATE INDEX 流程

### 4.1 场景

```sql
-- 1. 创建表
CREATE TABLE test (id INT, value VARCHAR(50));

-- 2. 插入数据
INSERT INTO test VALUES (1, 'Alice');
INSERT INTO test VALUES (2, 'Bob');
INSERT INTO test VALUES (3, 'Charlie');

-- 3. 创建索引
CREATE INDEX idx_value ON test USING nrindex (value);
```

### 4.2 完整执行流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  CREATE INDEX idx_value ON test USING nrindex (value);                      │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Backend Process (后端进程)                                                  │
│                                                                              │
│  1. nrindex_build() 被调用                                                  │
│                                                                              │
│  2. 扫描 test 表的每一行:                                                   │
│     ┌────────────────────────────────────────────────────────────────────┐  │
│     │  for each row in test:                                             │  │
│     │      TID(0,1): value="Alice"                                       │  │
│     │      TID(0,2): value="Bob"                                         │  │
│     │      TID(0,3): value="Charlie"                                     │  │
│     └────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  3. 对每一行，构建索引键值对:                                                │
│     ┌────────────────────────────────────────────────────────────────────┐  │
│     │  ikey   = { indexOid: 16385, key_data: "Alice" }                   │  │
│     │  ivalue = { heap_tid: (0,1) }                                      │  │
│     └────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  4. 调用 nrindex_rocks_put(ikey, ivalue)                                    │
│         │                                                                    │
│         ▼                                                                    │
│     RocksClientIndexPut(ikey, ivalue)                                       │
│         │                                                                    │
│         ├─ 序列化 ikey, ivalue → bytes                                      │
│         ├─ 构建消息: KVMsg { op: kv_index_put, entity: bytes }              │
│         ├─ 发送到共享内存通道: KVChannelPushMsg()                           │
│         │                                                                    │
└─────────┼────────────────────────────────────────────────────────────────────┘
          │
          │  消息写入共享内存的 KVChannel
          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  共享内存: KVChannel (环形缓冲区)                                            │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  [消息: kv_index_put, key="Alice", value=TID(0,1)]                    │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
          │
          │  Rocks Service 从通道读取消息
          ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Rocks Service Process (后台工作进程)                                        │
│                                                                              │
│  5. run_rocks() 主循环接收消息:                                             │
│     msg = KVChannelPopMsg(channel)                                          │
│                                                                              │
│  6. process_request(msg)                                                    │
│     switch(msg->op):                                                        │
│       case kv_index_put:                                                    │
│         handle_kv_index_put(msg)                                            │
│                                                                              │
│  7. handle_kv_index_put():                                                  │
│     ┌────────────────────────────────────────────────────────────────────┐  │
│     │  ikey   = deserialize(msg->entity)  // "Alice"                     │  │
│     │  ivalue = deserialize(...)          // TID(0,1)                    │  │
│     │                                                                     │  │
│     │  indexengine_put(index_engine, ikey, ivalue)                       │  │
│     └────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  8. indexengine_put() - 存入进程私有内存的 std::map:                        │
│     ┌────────────────────────────────────────────────────────────────────┐  │
│     │  std::map data_store:                                              │  │
│     │                                                                     │  │
│     │  data_store["Alice"]   = TID(0,1)   ← 新插入                       │  │
│     │  data_store["Bob"]     = TID(0,2)   ← 后续插入                     │  │
│     │  data_store["Charlie"] = TID(0,3)   ← 后续插入                     │  │
│     └────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 4.3 nrindex_build 函数详解

当执行 `CREATE INDEX test_idx_val ON test_idx USING nrindex (val);` 时，PostgreSQL 会调用 `nrindex_build` 函数。

### 函数入口

```c
static IndexBuildResult *
nrindex_build(Relation heap, Relation index, IndexInfo *indexInfo)
```

**参数说明**：
| 参数 | 类型 | 含义 |
|------|------|------|
| `heap` | Relation | 堆表（原始数据表）的描述符 |
| `index` | Relation | 索引的描述符 |
| `indexInfo` | IndexInfo* | 索引的元信息（包含键列信息等） |

### 执行步骤详解

#### 步骤1：获取索引键列数量

```c
nkeys = indexInfo->ii_NumIndexKeyAttrs;
```

`ii_NumIndexKeyAttrs` 表示索引包含的**键列数量**。

```sql
-- 单列索引
CREATE INDEX test_idx_val ON test_idx USING nrindex (val);
-- nkeys = 1

-- 多列索引
CREATE INDEX test_idx_multi ON test_idx USING nrindex (val, id);
-- nkeys = 2
```

#### 步骤2：获取键列与堆表列的映射

```c
for (int i = 0; i < nkeys; i++) {
    int attrNum = indexInfo->ii_IndexAttrNumbers[i];
    // attrNum 是堆表中的列号（从1开始）
}
```

**示例**：

```sql
CREATE TABLE test_idx (id int, val int);
--                      ^       ^
--                    列1      列2
--                  attr=1   attr=2

CREATE INDEX test_idx_val ON test_idx USING nrindex (val);
```

输出：
```
Number of index key columns: 1
  Key column 0: heap attribute number = 2
```

**含义**：
- `Key column 0` = 索引的第一个键（从 0 开始计数）
- `heap attribute number = 2` = 这个键对应堆表的第 2 列（即 `val`）

```
索引键列 (0-based)          堆表列 (1-based)
┌─────────────┐            ┌─────────────┐
│ Key col 0   │ ────────── │  id  (1)    │
└─────────────┘      ╲     ├─────────────┤
                      ╲────│  val (2)    │  ← 实际指向这里
                           └─────────────┘
```

#### 步骤3：开始堆表扫描（Heap Scan）

```c
scan = table_beginscan(heap, SnapshotAny, 0, NULL);
```

**Heap（堆表）**：PostgreSQL 存储实际数据行的地方。

创建索引时需要：
1. **读取堆表中的每一行数据**
2. **提取索引列的值**
3. **构建索引条目存入 RocksDB**

#### 步骤4：遍历每一行数据

```c
while ((heapTuple = heap_getnext(scan, ForwardScanDirection)) != NULL) {
    // 处理每一行
}
```

**流程图**：

```
                    Heap Table (test_idx)
                    ┌────────────────────┐
                    │ ctid  │ id │ val   │
                    ├───────┼────┼───────┤
  heap_getnext ───► │ (0,1) │ 1  │ 100   │ ──► 提取 val=100 ──► 存入索引
                    ├───────┼────┼───────┤
  heap_getnext ───► │ (0,2) │ 2  │ 200   │ ──► 提取 val=200 ──► 存入索引
                    ├───────┼────┼───────┤
  heap_getnext ───► │ (0,3) │ 3  │ 300   │ ──► 提取 val=300 ──► 存入索引
                    └───────┴────┴───────┘
                              │
                              ▼
                         Scan 结束
```

#### 步骤5：提取索引列的值

```c
for (int i = 0; i < nkeys; i++) {
    int heapAttrNum = indexInfo->ii_IndexAttrNumbers[i];
    if (heapAttrNum == 0) {
        /* 系统列（如 ctid, xmin 等） */
        values[i] = heap_getsysattr(heapTuple, heapAttrNum, heapTupDesc, &isnull[i]);
    } else {
        /* 普通列 */
        values[i] = heap_getattr(heapTuple, heapAttrNum, heapTupDesc, &isnull[i]);
    }
}
```

**说明**：
- `heap_getattr`: 从堆元组中提取指定列的值
- `heapAttrNum`: 堆表列号（从1开始，0表示系统列）
- `values[i]`: 提取出的 Datum 值
- `isnull[i]`: 标记该值是否为 NULL

#### 步骤6：构建索引键值对

```c
NRIndexKey ikey = nrindex_key_create(index->rd_id, values, isnull, nkeys, indexTupDesc);
NRIndexValue ivalue = nrindex_value_create(&heapTuple->t_self);
```

##### 6.1 nrindex_key_create - 创建索引 Key

**函数签名**：
```c
NRIndexKey nrindex_key_create(Oid indexOid, Datum *values, bool *isnull,
                               int nkeys, TupleDesc indexTupDesc);
```

**参数说明**：

| 参数 | 含义 | 示例值 |
|------|------|--------|
| `index->rd_id` | 索引的 OID | `16385` |
| `values` | 索引列的值数组 | `[100]` (val=100) |
| `isnull` | 每个值是否为 NULL | `[false]` |
| `nkeys` | 索引列数量 | `1` |
| `indexTupDesc` | 索引的元组描述符 | (列类型信息等) |

**作用**：把索引列的值序列化成一个 Key 结构

```
输入: val = 100

输出: NRIndexKey
┌──────────────┬────────────┬─────────────┐
│  indexOid    │  key_size  │  key_data   │
│   16385      │     4      │  [100]      │
└──────────────┴────────────┴─────────────┘
```

##### 6.2 nrindex_value_create - 创建索引 Value

**函数签名**：
```c
NRIndexValue nrindex_value_create(ItemPointer heap_tid);
```

**参数说明**：

| 参数 | 含义 | 示例值 |
|------|------|--------|
| `&heapTuple->t_self` | 当前行的物理位置 (ctid) | `(0, 1)` |

**作用**：把行的位置 (ctid) 封装成一个 Value 结构

```
输入: heapTuple->t_self = ctid(0, 1)

输出: NRIndexValue
┌─────────────────┬────────────┬─────────┐
│    heap_tid     │  xact_id   │  flags  │
│     (0, 1)      │  当前事务   │    0    │
└─────────────────┴────────────┴─────────┘
```

##### 6.3 heapTuple->t_self 是什么？

```c
typedef struct HeapTupleData {
    ...
    ItemPointerData t_self;  // ← 这就是 ctid，行的物理位置
    ...
} HeapTupleData;
```

`t_self` 包含：
- **BlockNumber**: 页号（第几个 8KB 页）
- **OffsetNumber**: 页内偏移（页内第几行）

```
ctid = (0, 1) 表示: 第 0 页，第 1 行
```

##### 6.4 完整流程图示

```
原始行数据: ctid=(0,1), id=1, val=100
                              ↓
        ┌─────────────────────┴─────────────────────┐
        │                                           │
        ▼                                           ▼
┌───────────────────────┐               ┌───────────────────────┐
│ values[0] = 100       │               │ heapTuple->t_self     │
│ (从 heap_getattr 提取) │               │ = ctid(0,1)           │
└───────────────────────┘               └───────────────────────┘
        │                                           │
        ▼                                           ▼
nrindex_key_create()                    nrindex_value_create()
        │                                           │
        ▼                                           ▼
┌───────────────────────┐               ┌───────────────────────┐
│ NRIndexKey            │               │ NRIndexValue          │
│ - indexOid: 16385     │               │ - heap_tid: (0,1)     │
│ - key_data: [100]     │               │ - xact_id: 当前事务    │
└───────────────────────┘               └───────────────────────┘
        │                                           │
        └─────────────────┬─────────────────────────┘
                          │
                          ▼
              nrindex_rocks_put(ikey, ivalue)
                          │
                          ▼
              存入 RocksDB: Key[100] → Value[ctid(0,1)]
```

##### 6.5 什么是 Oid indexOid？

`Oid` (Object Identifier) 是 PostgreSQL 用于**唯一标识数据库对象**的 ID，不是随机生成的，而是**顺序递增分配**的。

```
OID = Object Identifier (对象标识符)
- 32 位无符号整数
- PostgreSQL 内部用于标识：表、索引、函数、类型等所有对象
- 创建对象时自动分配，顺序递增
```

**查看索引的 OID**：

```sql
-- 创建表和索引
CREATE TABLE test_idx (id int, val int);
CREATE INDEX test_idx_val ON test_idx USING nrindex (val);

-- 查看索引的 OID
SELECT oid, relname FROM pg_class WHERE relname = 'test_idx_val';
```

输出：
```
  oid  |   relname
-------+--------------
 16385 | test_idx_val
```

**多个对象的 OID 分配示例**：

```sql
CREATE TABLE t1 (a int);           -- 表 t1 的 OID = 16384
CREATE INDEX idx1 ON t1 (a);       -- 索引 idx1 的 OID = 16385
CREATE TABLE t2 (b int);           -- 表 t2 的 OID = 16386
CREATE INDEX idx2 ON t2 (b);       -- 索引 idx2 的 OID = 16387
```

```
OID 分配顺序:
16384 → t1 (表)
16385 → idx1 (索引)
16386 → t2 (表)
16387 → idx2 (索引)
       ↓
     顺序递增
```

**为什么索引 Key 要包含 indexOid？**

因为**多个索引的数据都存在同一个 RocksDB 里**，需要用 `indexOid` 来区分：

```
RocksDB 存储:
┌────────────────────────────────────────────────────┐
│  Key: [indexOid=16385][val=100]  → Value: ctid(0,1) │  ← idx1 的数据
│  Key: [indexOid=16385][val=200]  → Value: ctid(0,2) │  ← idx1 的数据
│  Key: [indexOid=16387][val=100]  → Value: ctid(0,1) │  ← idx2 的数据
│  Key: [indexOid=16387][val=300]  → Value: ctid(0,3) │  ← idx2 的数据
└────────────────────────────────────────────────────┘
```

如果没有 `indexOid`，不同索引的数据会混在一起！

**代码中获取 indexOid**：

```c
// index->rd_id 就是索引的 OID
NRIndexKey ikey = nrindex_key_create(index->rd_id, values, ...);
                                     ^^^^^^^^^^^^
                                     索引的 OID (如 16385)
```

**OID 总结**：

| 问题 | 答案 |
|------|------|
| OID 是什么？ | PostgreSQL 对象的唯一标识符 |
| 怎么生成的？ | 顺序递增分配，不是随机的 |
| 为什么需要？ | 区分不同索引的数据（多个索引共用一个 RocksDB） |
| 怎么获取？ | `index->rd_id` 或 `SELECT oid FROM pg_class` |

##### 6.6 数据结构定义

**NRIndexKey 结构**：
```c
typedef struct NRIndexKeyData {
    Oid indexOid;      // 索引 OID（标识是哪个索引）
    uint32 key_size;   // 序列化后键数据的大小
    char key_data[];   // 序列化的索引列值
} NRIndexKeyData;
```

**NRIndexValue 结构**：
```c
typedef struct NRIndexValueData {
    ItemPointerData heap_tid;  // 指向堆表中行的位置 (Block, Offset)
    TransactionId xact_id;     // 创建该索引条目的事务ID
    uint16 flags;              // 标志位
} NRIndexValueData;
```

##### 6.7 具体示例

```
行数据: ctid=(0,1), id=1, val=100

构建的索引条目:
┌─────────────────────────────────────────────────────┐
│ NRIndexKey:                                         │
│   indexOid = 16385 (索引的OID)                      │
│   key_size = 4                                      │
│   key_data = [100的二进制表示]                       │
├─────────────────────────────────────────────────────┤
│ NRIndexValue:                                       │
│   heap_tid = (0, 1)  ← 指向堆表第0块第1行            │
│   xact_id  = 当前事务ID                             │
│   flags    = 0                                      │
└─────────────────────────────────────────────────────┘
```

##### 6.8 函数作用总结

| 函数 | 输入 | 输出 | 用途 |
|------|------|------|------|
| `nrindex_key_create()` | 索引列的值 (val=100) | NRIndexKey | 索引查找的 Key |
| `nrindex_value_create()` | 行的位置 (ctid) | NRIndexValue | 回表用的指针 |

**本质：把 `val=100 → ctid(0,1)` 这个映射关系存入索引。**

#### 步骤7：存入 RocksDB

```c
if (!nrindex_rocks_put(ikey, ivalue)) {
    elog(ERROR, "Failed to insert index entry during build");
}
```

调用链：
```
nrindex_rocks_put()
    └── RocksClientIndexPut()
            └── KVChannelPushMsg() ──► 共享内存 IPC
                                            │
                              Rocks Service ◄┘
                                    │
                              indexengine_put()
                                    │
                              std::map[key] = value
```

##### 7.1 RocksClientIndexPut 函数详解

**函数命名含义**：

```
RocksClientIndexPut
  │     │     │  │
  │     │     │  └── Put = 写入/存储操作
  │     │     └───── Index = 索引相关
  │     └─────────── Client = 客户端（发送请求的一方）
  └───────────────── Rocks = RocksDB（键值存储引擎）
```

**Rocks 是什么？**

```
┌─────────────────────────────────────────────────────────────────┐
│  RocksDB: Facebook 开发的高性能键值存储引擎                       │
│                                                                  │
│  原本设计: 使用 RocksDB 存储索引数据（持久化到磁盘）              │
│  当前实现: 使用 std::map 模拟（存储在内存中）                    │
│                                                                  │
│  名字保留 "Rocks" 是因为架构设计是为 RocksDB 准备的              │
└─────────────────────────────────────────────────────────────────┘
```

**函数源码** (`rocks_handler.c`):

```c
bool RocksClientIndexPut(NRIndexKey ikey, NRIndexValue ivalue) {
    // 1. 获取通信通道
    KVChannel *req_chan = GetServerChannel();   // 请求通道（发送给 Rocks Service）
    KVChannel *resp_chan = GetRespChannel();    // 响应通道（接收结果）

    // 2. 序列化 Key 和 Value
    char *serialized_key = nrindex_key_serialize(ikey, &key_len);
    char *serialized_val = nrindex_value_serialize(ivalue, &val_len);

    // 3. 构建消息
    KVMsg *msg = NewMsg(kv_index_put, ikey->indexOid, ...);
    // 把 key 和 value 打包到消息中

    // 4. 发送请求到共享内存通道
    KVChannelPushMsg(req_chan, msg, -1);

    // 5. 等待响应（阻塞）
    resp = KVChannelPopMsg(resp_chan, -1);

    // 6. 返回结果
    return success;
}
```

**数据流向图**：

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          Backend Process (后端进程)                          │
│                                                                              │
│   RocksClientIndexPut(ikey, ivalue)                                         │
│         │                                                                    │
│         ├── 1. 序列化 Key: [indexOid=16385][val=100]                        │
│         ├── 2. 序列化 Value: [ctid(0,1)][xact_id][flags]                    │
│         │                                                                    │
│         ├── 3. 构建消息:                                                     │
│         │      ┌─────────────────────────────────────────┐                  │
│         │      │ KVMsg                                   │                  │
│         │      │   op: kv_index_put                      │                  │
│         │      │   indexOid: 16385                       │                  │
│         │      │   entity: [key_len][key][val_len][val]  │                  │
│         │      └─────────────────────────────────────────┘                  │
│         │                                                                    │
│         └── 4. KVChannelPushMsg() ──────────────────────────────────────────┼──┐
│                                                                              │  │
│         ┌── 5. KVChannelPopMsg() 等待响应 ◄─────────────────────────────────┼──┼─┐
│         │                                                                    │  │ │
└─────────┼────────────────────────────────────────────────────────────────────┘  │ │
          │                                                                        │ │
          │    ════════════════ 共享内存 (KVChannel) ════════════════              │ │
          │                                                                        │ │
          │                                                                        ▼ │
┌─────────┼────────────────────────────────────────────────────────────────────────┼─┤
│         │               Rocks Service Process (后台进程)                         │ │
│         │                                                                        │ │
│         │    run_rocks() 主循环                                                  │ │
│         │         │                                                              │ │
│         │         ├── KVChannelPopMsg() 接收消息 ◄───────────────────────────────┘ │
│         │         │                                                                │
│         │         ├── process_request(msg)                                         │
│         │         │       └── handle_kv_index_put(msg)                             │
│         │         │               │                                                │
│         │         │               ├── 反序列化 Key, Value                          │
│         │         │               │                                                │
│         │         │               └── indexengine_put(engine, key, value)          │
│         │         │                       │                                        │
│         │         │                       ▼                                        │
│         │         │               ┌─────────────────────────────────┐              │
│         │         │               │   std::map (IndexEngine)        │              │
│         │         │               │                                 │              │
│         │         │               │   data_store[key] = value       │ ← 数据存这里 │
│         │         │               │                                 │              │
│         │         │               │   "idx_16385|100" → ctid(0,1)   │              │
│         │         │               └─────────────────────────────────┘              │
│         │         │                                                                │
│         │         └── 发送响应 ────────────────────────────────────────────────────┘
│         │
│         ▼
│    返回 success
│
└────────────────────────────────────────────────────────────────────────────────────┘
```

**数据最终存储位置**：

```
┌─────────────────────────────────────────────────────────────────┐
│                    Rocks Service 进程的私有内存                   │
│                                                                  │
│   indexengine.cpp:                                               │
│   ┌───────────────────────────────────────────────────────────┐  │
│   │  class IndexEngineImpl {                                  │  │
│   │      std::map<std::string, std::string> data_store;       │  │
│   │                     ↑                                     │  │
│   │                     │                                     │  │
│   │              索引数据存在这里！                             │  │
│   │                                                           │  │
│   │      data_store["idx_16385|10"]    = ctid(0,1)           │  │
│   │      data_store["idx_16385|20"]    = ctid(0,2)           │  │
│   │      data_store["idx_16385|30"]    = ctid(0,3)           │  │
│   │      ...                                                  │  │
│   │      data_store["idx_16385|100000"] = ctid(x,y)          │  │
│   │  };                                                       │  │
│   └───────────────────────────────────────────────────────────┘  │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

**为什么需要 IPC（进程间通信）？**

```
问题：PostgreSQL 是多进程架构

  psql 客户端1 ──→ Backend Process 1 (PID: 1001)
  psql 客户端2 ──→ Backend Process 2 (PID: 1002)
  psql 客户端3 ──→ Backend Process 3 (PID: 1003)

  每个后端进程都是独立的，不能共享内存中的 std::map

解决方案：

  启动一个专用的 Rocks Service 进程，管理 std::map
  所有后端进程通过 IPC (共享内存通道) 与它通信
```

**RocksClientIndexPut 总结**：

| 问题 | 答案 |
|------|------|
| `RocksClient` 是什么？ | 运行在后端进程中的**客户端**，负责发送请求 |
| `Rocks` 是什么？ | RocksDB 存储引擎（当前用 std::map 模拟） |
| `Put` 做什么？ | 将索引数据写入存储 |
| 数据存到哪里？ | **Rocks Service 进程**的 `std::map` 中 |
| 怎么通信？ | 通过**共享内存通道** (KVChannel) 进行 IPC |

**一句话总结**：`RocksClientIndexPut` 把索引数据通过 IPC 发送给 Rocks Service 进程，最终存入 `std::map`。

### 完整执行输出示例

```sql
CREATE TABLE test_idx (id int, val int);
INSERT INTO test_idx VALUES (1, 100), (2, 200), (3, 300);
CREATE INDEX test_idx_val ON test_idx USING nrindex (val);
```

```
NOTICE:  ========== NRINDEX BUILD START ==========
NOTICE:  Building index on table: test_idx (OID: 16384)
NOTICE:  Index name: test_idx_val (OID: 16385)
NOTICE:  Number of index key columns: 1
NOTICE:    Key column 0: heap attribute number = 2
NOTICE:  Starting heap scan...
NOTICE:  Processing tuple #1: ctid=(0,1), key_size=4, value_len=14
NOTICE:  Processing tuple #2: ctid=(0,2), key_size=4, value_len=14
NOTICE:  Processing tuple #3: ctid=(0,3), key_size=4, value_len=14
NOTICE:  ========== NRINDEX BUILD COMPLETE ==========
NOTICE:  Total tuples indexed: 3
```

### 输出字段解释

| 字段 | 含义 |
|------|------|
| `Building index on table: test_idx (OID: 16384)` | 正在为 test_idx 表构建索引 |
| `Index name: test_idx_val (OID: 16385)` | 索引名称和 OID |
| `Number of index key columns: 1` | 索引包含 1 个键列 |
| `Key column 0: heap attribute number = 2` | 索引键列 0 对应堆表的第 2 列 |
| `Starting heap scan...` | 开始扫描堆表所有行 |
| `ctid=(0,1)` | 当前处理行的位置：第 0 块第 1 行 |
| `key_size=4` | 索引键序列化后的大小（4字节=int） |
| `value_len=14` | 索引值的大小（ItemPointer + xact_id + flags） |
| `Total tuples indexed: 3` | 共索引了 3 行数据 |

### 关键概念总结

| 概念 | 说明 |
|------|------|
| **nkeys** | 索引键列数量 |
| **ii_IndexAttrNumbers** | 索引键列到堆表列的映射数组 |
| **Heap Scan** | 扫描堆表（原始数据表）的所有行 |
| **heap_getattr** | 从堆元组中提取指定列的值 |
| **ctid** | 行的物理位置 (BlockNumber, OffsetNumber) |
| **NRIndexKey** | 索引键：包含索引OID和序列化的列值 |
| **NRIndexValue** | 索引值：包含 heap_tid（指向原始行） |

---

## 五、SELECT 查询流程

### 5.1 场景

```sql
SELECT * FROM test WHERE value = 'Bob';
```

### 5.2 执行流程

```
┌─────────────────────────────────────────────────────────────────────────────┐
│  SELECT * FROM test WHERE value = 'Bob';                                     │
└─────────────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│  Backend Process (后端进程)                                                  │
│                                                                              │
│  1. PostgreSQL 优化器决定使用索引扫描                                        │
│                                                                              │
│  2. nrindex_beginscan() - 初始化扫描                                        │
│                                                                              │
│  3. nrindex_rescan(scankey="Bob") - 执行搜索                                │
│         │                                                                    │
│         ▼                                                                    │
│     nrindex_rocks_range_scan(min_key, max_key)                              │
│         │                                                                    │
│         ▼                                                                    │
│     RocksClientIndexRangeScan(...)                                          │
│         │                                                                    │
│         ├─ 发送: KVChannelPushMsg(kv_index_range_scan)                      │
│         ├─ 等待: KVChannelPopMsg(resp_chan)                                 │
│         └─ 结果: [{ key:"Bob", value:TID(0,2) }]                            │
│                                                                              │
│  4. nrindex_gettuple() - 返回结果                                           │
│     ┌────────────────────────────────────────────────────────────────────┐  │
│     │  // 获取结果                                                        │  │
│     │  NRIndexValue ivalue = results[cursor];  // TID(0,2)               │  │
│     │                                                                     │  │
│     │  // ⭐ 关键：把 heap_tid 传给 PostgreSQL                            │  │
│     │  scan->xs_heaptid = ivalue->heap_tid;  // (0, 2)                   │  │
│     │                                                                     │  │
│     │  return true;                                                       │  │
│     └────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  5. PostgreSQL 用 heap_tid 回表取数据                                       │
│     ┌────────────────────────────────────────────────────────────────────┐  │
│     │  HeapTuple tuple = heap_fetch(heapRelation, TID(0,2));             │  │
│     │  // 取到: { id: 2, value: "Bob" }                                  │  │
│     └────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  6. 返回结果给用户                                                          │
│     +----+-------+                                                          │
│     | id | value |                                                          │
│     +----+-------+                                                          │
│     |  2 | Bob   |                                                          │
│     +----+-------+                                                          │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 六、IPC 通信模型

```
┌───────────────────┐                    ┌───────────────────┐
│  Backend Process  │                    │  Rocks Service    │
│  (后端进程)       │                    │  (后台进程)       │
│                   │                    │                   │
│  RocksClient      │                    │  IndexEngine      │
│  ┌─────────────┐  │    KVChannel       │  ┌─────────────┐  │
│  │ IndexGet()  │──┼──► [消息队列] ───► │  │ std::map    │  │
│  │ IndexPut()  │  │    (共享内存)      │  │ get/put/    │  │
│  │ RangeScan() │◄─┼─── [响应队列] ◄─── │  │ range_scan  │  │
│  └─────────────┘  │                    │  └─────────────┘  │
│                   │                    │                   │
└───────────────────┘                    └───────────────────┘
```

---

## 七、关键理解

### 7.1 索引只存指针

```
┌─────────────────────────────────────────────────────────────────┐
│  外部索引不存储完整的行数据，只存储：                            │
│  - Key: 索引列的值（如 "Alice", "Bob"）                         │
│  - Value: 指向表中行的位置（heap_tid）                          │
│                                                                  │
│  索引:  "Bob" → heap_tid:(0,2)                                  │
│  表:    TID(0,2) → {id:2, value:"Bob"}  ← 完整数据在这里       │
│                                                                  │
│  索引只负责"查找位置"，PostgreSQL 负责"取数据"                  │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2 核心接口

```c
// nrindex_gettuple() - 最关键的函数
static bool nrindex_gettuple(IndexScanDesc scan, ScanDirection direction) {
    NRIndexScanDesc nrscan = (NRIndexScanDesc) scan;

    if (nrscan->cursor >= nrscan->result_count) {
        return false;
    }

    NRIndexValue ivalue = nrscan->results[nrscan->cursor];

    // ⭐⭐⭐ 核心：把 heap_tid 传给 PostgreSQL ⭐⭐⭐
    scan->xs_heaptid = ivalue->heap_tid;

    nrscan->cursor++;
    return true;
}
```

---

## 八、相关文件列表

| 文件 | 说明 |
|------|------|
| `src/nrindex.c` | Index Access Method 主实现 |
| `src/nrindex.h` | 公共接口声明 |
| `src/nrindex_access/nrindex_kv.c` | 索引键值操作封装 |
| `src/nrindex_access/nrindex_kv.h` | 索引键值结构定义 |
| `src/nram_storage/rocks_handler.c` | RocksClient 实现 |
| `src/nram_storage/rocks_handler.h` | RocksClient 接口 |
| `src/nram_storage/rocks_service.c` | Rocks Service 后台进程 |
| `src/nram_storage/indexengine.cpp` | C++ 索引存储引擎 |
| `src/nram_storage/indexengine.h` | C 接口封装 |
| `src/ipc/msg.c` | IPC 消息通道实现 |
| `src/ipc/msg.h` | IPC 接口定义 |

---

## 九、总结

| 问题 | 答案 |
|------|------|
| 索引数据存在哪里？ | Rocks Service 进程的私有内存（std::map） |
| 共享内存存什么？ | KVChannel（消息通道）和表数据（Buffer Pool） |
| IPC 的作用？ | 后端进程通过共享内存通道向 Rocks Service 发送请求 |
| 为什么需要 IPC？ | PostgreSQL 多进程架构，需要集中管理索引数据 |
| 索引存什么？ | 只存 Key → heap_tid（位置指针），不存完整行 |
| 如何回表取数据？ | 通过 `scan->xs_heaptid` 传递位置，PostgreSQL 用它取完整行 |

**一句话总结**：后端进程通过 IPC 向 Rocks Service 发送消息，Rocks Service 在自己的私有内存中用 std::map 管理索引数据，索引只存储位置指针，PostgreSQL 负责用指针回表取完整数据。

---

## 十、查询执行的完整函数调用链

### 10.1 场景

```sql
SELECT * FROM test WHERE value = 'Bob';
```

### 10.2 完整调用链（带代码位置）

```
┌─────────────────────────────────────────────────────────────────────────────────────┐
│                              PostgreSQL 执行器                                       │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  1. ExecInitIndexScan()          -- 初始化索引扫描节点                              │
│         │                                                                            │
│         ▼                                                                            │
│  2. index_beginscan()            -- PostgreSQL 通用接口                             │
│         │                                                                            │
│         ▼                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  nrindex_beginscan()          -- nrindex.c:200                               │   │
│  │      │                                                                        │   │
│  │      ├── palloc(NRIndexScanDescData)    -- 分配扫描描述符                    │   │
│  │      ├── scan->results = NULL                                                 │   │
│  │      ├── scan->result_count = 0                                               │   │
│  │      └── scan->cursor = 0                                                     │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│         │                                                                            │
│         ▼                                                                            │
│  3. index_rescan()               -- 设置搜索条件                                    │
│         │                                                                            │
│         ▼                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  nrindex_rescan()             -- nrindex.c:250                               │   │
│  │      │                                                                        │   │
│  │      ├── 解析 ScanKey，提取 "Bob"                                            │   │
│  │      │                                                                        │   │
│  │      ├── nrindex_key_create()         -- 构建 min_key, max_key               │   │
│  │      │       └── nrindex_kv.c:50                                              │   │
│  │      │                                                                        │   │
│  │      └── nrindex_rocks_range_scan()   -- 执行范围扫描                        │   │
│  │              │                                                                │   │
│  │              └── nrindex_kv.c:243                                             │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                   │                                                                  │
│                   ▼                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  RocksClientIndexRangeScan()  -- rocks_handler.c:310                         │   │
│  │      │                                                                        │   │
│  │      ├── nrindex_key_serialize(start_key)    -- 序列化                       │   │
│  │      ├── nrindex_key_serialize(end_key)                                       │   │
│  │      │                                                                        │   │
│  │      ├── NewMsg(kv_index_range_scan, ...)    -- 构建 IPC 消息                │   │
│  │      │       └── msg.c:236                                                    │   │
│  │      │                                                                        │   │
│  │      ├── KVChannelPushMsg(ServerChannel, msg)  -- 发送请求                   │   │
│  │      │       └── msg.c:408                                                    │   │
│  │      │                                                                        │   │
│  │      └── KVChannelPopMsg(RespChannel)        -- 等待响应（阻塞）             │   │
│  │              └── msg.c:432                                                    │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                   │                                                                  │
│                   │  ══════════════ 共享内存 IPC ══════════════                     │
│                   ▼                                                                  │
└─────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           Rocks Service 进程                                         │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  run_rocks()                  -- rocks_service.c:136                         │   │
│  │      │                                                                        │   │
│  │      └── while(running) {                                                     │   │
│  │              msg = KVChannelPopMsg(channel)   -- 接收消息                    │   │
│  │              process_request(msg)                                             │   │
│  │          }                                                                    │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│         │                                                                            │
│         ▼                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  process_request()            -- rocks_service.c:219                         │   │
│  │      │                                                                        │   │
│  │      └── switch(msg->op) {                                                    │   │
│  │              case kv_index_range_scan:                                        │   │
│  │                  handle_kv_index_range_scan(msg)                              │   │
│  │          }                                                                    │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│         │                                                                            │
│         ▼                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  handle_kv_index_range_scan() -- rocks_service.c:503                         │   │
│  │      │                                                                        │   │
│  │      ├── nrindex_key_deserialize(buf)        -- 反序列化 start_key          │   │
│  │      ├── nrindex_key_deserialize(buf)        -- 反序列化 end_key            │   │
│  │      │                                                                        │   │
│  │      └── indexengine_range_scan(index_engine, start, end, ...)              │   │
│  │              └── indexengine.cpp:181                                          │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│         │                                                                            │
│         ▼                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  indexengine_range_scan()     -- indexengine.cpp (C 接口)                    │   │
│  │      │                                                                        │   │
│  │      └── IndexEngineImpl::rangeScan()                                         │   │
│  │              │                                                                │   │
│  │              ├── auto it = data_store.lower_bound(start_key)                 │   │
│  │              │                                                                │   │
│  │              └── while (it->first < end_key) {                               │   │
│  │                      results.push_back(*it);   // 找到 "Bob" → TID(0,2)     │   │
│  │                      ++it;                                                    │   │
│  │                  }                                                            │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│         │                                                                            │
│         │  返回结果: [{ key:"Bob", value:TID(0,2) }]                                │
│         ▼                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  handle_kv_index_range_scan() 继续                                           │   │
│  │      │                                                                        │   │
│  │      ├── 序列化结果到 resp->entity                                           │   │
│  │      │                                                                        │   │
│  │      └── ResultQueuePush(&result_queue, resp)  -- 放入响应队列              │   │
│  │              └── KVChannelPushMsg(resp_chan, resp)                           │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│                   │                                                                  │
│                   │  ══════════════ 共享内存 IPC ══════════════                     │
│                   ▼                                                                  │
└─────────────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────────────┐
│                           Backend 进程（继续）                                       │
├─────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                      │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  RocksClientIndexRangeScan() 继续                                            │   │
│  │      │                                                                        │   │
│  │      ├── resp = KVChannelPopMsg(RespChannel)  -- 收到响应                    │   │
│  │      │                                                                        │   │
│  │      └── 反序列化结果到 out_keys[], out_values[]                             │   │
│  │              nrindex_key_deserialize()                                        │   │
│  │              nrindex_value_deserialize()                                      │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│         │                                                                            │
│         ▼                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  nrindex_rescan() 继续        -- nrindex.c                                   │   │
│  │      │                                                                        │   │
│  │      ├── scan->results = values      // 保存结果                             │   │
│  │      ├── scan->result_count = 1                                               │   │
│  │      └── scan->cursor = 0                                                     │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│         │                                                                            │
│         ▼                                                                            │
│  4. index_gettuple()             -- 循环获取每个结果                                │
│         │                                                                            │
│         ▼                                                                            │
│  ┌──────────────────────────────────────────────────────────────────────────────┐   │
│  │  nrindex_gettuple()           -- nrindex.c:320                               │   │
│  │      │                                                                        │   │
│  │      ├── if (cursor >= result_count) return false                            │   │
│  │      │                                                                        │   │
│  │      ├── ivalue = results[cursor]     // TID(0,2)                            │   │
│  │      │                                                                        │   │
│  │      ├── scan->xs_heaptid = ivalue->heap_tid  // ⭐ 关键！                   │   │
│  │      │                                                                        │   │
│  │      ├── cursor++                                                             │   │
│  │      │                                                                        │   │
│  │      └── return true                                                          │   │
│  └──────────────────────────────────────────────────────────────────────────────┘   │
│         │                                                                            │
│         ▼                                                                            │
│  5. ExecIndexScan()              -- PostgreSQL 执行器                               │
│         │                                                                            │
│         ├── tid = scan->xs_heaptid       // 获取 TID(0,2)                           │
│         │                                                                            │
│         └── heap_fetch(heapRelation, tid)  -- 回表取完整行                          │
│                 │                                                                    │
│                 └── 返回: { id:2, value:"Bob" }                                     │
│         │                                                                            │
│         ▼                                                                            │
│  6. 返回结果给客户端                                                                │
│         +----+-------+                                                              │
│         | id | value |                                                              │
│         +----+-------+                                                              │
│         |  2 | Bob   |                                                              │
│         +----+-------+                                                              │
│                                                                                      │
└─────────────────────────────────────────────────────────────────────────────────────┘
```

### 10.3 简化版调用链

```
PostgreSQL 执行器
    │
    ├── index_beginscan()
    │       └── nrindex_beginscan()                    [nrindex.c]
    │
    ├── index_rescan()
    │       └── nrindex_rescan()                       [nrindex.c]
    │               └── nrindex_rocks_range_scan()     [nrindex_kv.c]
    │                       └── RocksClientIndexRangeScan()  [rocks_handler.c]
    │                               ├── KVChannelPushMsg()   [msg.c] ──→ 共享内存
    │                               └── KVChannelPopMsg()    [msg.c] ←── 等待响应
    │                                           │
    │                           ════════════════╪════════════════
    │                                           ▼
    │                               Rocks Service 进程
    │                               run_rocks()              [rocks_service.c]
    │                                   └── process_request()
    │                                           └── handle_kv_index_range_scan()
    │                                                   └── indexengine_range_scan()  [indexengine.cpp]
    │                                                           └── std::map::lower_bound()
    │                                                                   │
    │                                                                   └── 返回 TID(0,2)
    │
    ├── index_gettuple()  (循环)
    │       └── nrindex_gettuple()                     [nrindex.c]
    │               └── scan->xs_heaptid = TID(0,2)    ⭐ 核心
    │
    └── heap_fetch(TID)  ──→ 返回完整行 {id:2, value:"Bob"}
```

### 10.4 函数调用时序表

| 序号 | 函数 | 文件 | 作用 |
|------|------|------|------|
| 1 | `nrindex_beginscan()` | nrindex.c | 分配扫描描述符 |
| 2 | `nrindex_rescan()` | nrindex.c | 设置搜索条件 |
| 3 | `nrindex_rocks_range_scan()` | nrindex_kv.c | 转发到 Client |
| 4 | `RocksClientIndexRangeScan()` | rocks_handler.c | 构建 IPC 消息 |
| 5 | `KVChannelPushMsg()` | msg.c | 发送到共享内存 |
| 6 | `KVChannelPopMsg()` | msg.c | Rocks Service 接收 |
| 7 | `handle_kv_index_range_scan()` | rocks_service.c | 处理请求 |
| 8 | `indexengine_range_scan()` | indexengine.cpp | 查询 std::map |
| 9 | `KVChannelPushMsg()` | msg.c | 返回响应 |
| 10 | `nrindex_gettuple()` | nrindex.c | 返回 heap_tid |
| 11 | `heap_fetch()` | PostgreSQL | 回表取数据 |

### 10.5 关键步骤说明

| 阶段 | 说明 |
|------|------|
| **初始化** | `nrindex_beginscan()` 分配扫描状态结构 |
| **搜索** | `nrindex_rescan()` 构建搜索键，通过 IPC 发送到 Rocks Service |
| **IPC 请求** | `RocksClientIndexRangeScan()` 序列化数据，写入共享内存通道 |
| **处理请求** | Rocks Service 的 `handle_kv_index_range_scan()` 调用 `indexengine_range_scan()` |
| **std::map 查询** | `IndexEngineImpl::rangeScan()` 使用 `lower_bound()` 进行范围查找 |
| **IPC 响应** | 结果序列化后通过响应通道返回 |
| **获取结果** | `nrindex_gettuple()` 从结果数组中取出 heap_tid |
| **回表** | PostgreSQL 用 heap_tid 调用 `heap_fetch()` 获取完整行数据 |

---

## 十一、IndexEngine 详解

### 11.1 IndexEngine 是什么？

`indexengine.cpp` 是索引的核心存储引擎，使用 C++ 的 `std::map`（红黑树）实现。

```cpp
class IndexEngineImpl {
private:
    std::map<std::string, std::string> data_store;  // ← 这就是索引！
};
```

**std::map 本质上是一个红黑树（类似 B-tree），这就是一个索引结构。**

### 11.2 存储的内容

```
┌─────────────────────────────────────────────────────────────────┐
│                      std::map (索引)                            │
├─────────────────────────────────────────────────────────────────┤
│   Key (std::string)          │   Value (std::string)           │
│   序列化后的索引键            │   序列化后的 heap_tid           │
├─────────────────────────────────────────────────────────────────┤
│   "idx_123|100"              │   "(Block=5, Offset=3)"         │
│   "idx_123|200"              │   "(Block=8, Offset=1)"         │
│   "idx_123|300"              │   "(Block=12, Offset=7)"        │
└─────────────────────────────────────────────────────────────────┘
         ↑                                ↑
    索引列的值                      表中行的物理位置
```

### 11.3 查询流程示例

```sql
SELECT * FROM test WHERE value = 100;
```

```
1. PostgreSQL 调用 indexengine_get()

2. 输入: NRIndexKey
   ┌──────────┬────────────┐
   │ indexOid │ value=100  │
   └──────────┴────────────┘

3. std::map 查找: data_store.find("idx_123|100")

4. 输出: NRIndexValue
   ┌───────────────────────────┐
   │ heap_tid = (Block=5, Off=3) │  ← 返回给 PostgreSQL
   └───────────────────────────┘

5. PostgreSQL 用 heap_tid 去表中读取完整行:
   Block 5, Offset 3 → (id=1, value=100, name="Alice")
```

### 11.4 关键函数：indexengine_get()

```cpp
NRIndexValue indexengine_get(IndexEngine* engine, NRIndexKey ikey) {
    // 1. 序列化 key
    std::string key = serialize_index_key(ikey);

    // 2. 在 map 中查找
    if (impl->get(key, &value)) {
        // 3. 反序列化并返回 NRIndexValue (包含 heap_tid)
        return deserialize_index_value(value);
    }
    return nullptr;  // 没找到
}
```

### 11.5 返回的数据结构

返回的 `NRIndexValue` 结构：

```c
typedef struct NRIndexValueData {
    ItemPointerData heap_tid;   // ← 关键！6字节，指向表中行位置
    TransactionId   xact_id;    // 事务ID
    uint16          flags;      // 标志位
} NRIndexValueData;
```

### 11.6 IndexEngine 接口汇总

| 接口函数 | 对应 std::map 操作 | 用途 |
|----------|-------------------|------|
| `indexengine_put()` | `map[key] = value` | 插入索引条目 |
| `indexengine_get()` | `map.find(key)` | 查找索引条目 |
| `indexengine_delete()` | `map.erase(key)` | 删除索引条目 |
| `indexengine_range_scan()` | `map.lower_bound()` 遍历 | 范围扫描 |
| `indexengine_exists()` | `map.find() != end()` | 检查是否存在 |

### 11.7 总结

| 问题 | 答案 |
|------|------|
| indexengine.cpp 是什么？ | **是索引的存储引擎**，用 std::map (红黑树) 实现 |
| 获得什么？ | 给定索引键，获得对应的 **heap_tid** |
| 返回什么给 PG？ | **NRIndexValue**，其中最重要的是 `heap_tid` |
| PG 用 heap_tid 做什么？ | 直接去表中读取完整的行数据 |

**简单来说：索引就是一个映射表，输入列值，输出行位置。**

---

## 十二、实现学习索引指南

如果要实现一个学习索引（Learned Index），以下是需要理解和修改的内容。

### 12.1 架构层次分析

```
┌─────────────────────────────────────────────────────────────┐
│  PostgreSQL Executor                                    ✓保留 │
├─────────────────────────────────────────────────────────────┤
│  Index AM Layer (nrindex.c)                            ✓保留 │
│  - nrindex_beginscan, nrindex_gettuple, etc.                │
├─────────────────────────────────────────────────────────────┤
│  KV Layer (nrindex_kv.c)                               ✓保留 │
│  - Key/Value 序列化                                         │
├─────────────────────────────────────────────────────────────┤
│  IPC Layer (rocks_handler.c + msg.c)                   ✓保留 │
│  - RocksClient 消息发送/接收                                │
├─────────────────────────────────────────────────────────────┤
│  Service Layer (rocks_service.c)                       ✓保留 │
│  - handle_kv_index_xxx() 消息路由                           │
├─────────────────────────────────────────────────────────────┤
│  IndexEngine (indexengine.cpp)                      ★需修改 │
│  - 当前用 std::map，需替换为学习索引                         │
└─────────────────────────────────────────────────────────────┘
```

### 12.2 核心修改点

当前的 `indexengine.cpp` 使用 std::map：

```cpp
class IndexEngineImpl {
private:
    std::map<std::string, std::string> data_store;  // ← 用学习索引替换
};
```

### 12.3 学习索引需要实现的接口

```cpp
class LearnedIndex {
public:
    // 必须实现的接口
    void put(const std::string& key, const std::string& value);
    bool get(const std::string& key, std::string* value);
    bool remove(const std::string& key);
    void rangeScan(const std::string& start_key,
                   const std::string& end_key,
                   std::vector<std::pair<std::string, std::string>>* results);
};
```

### 12.4 每个接口的具体要求

| 接口 | 输入 | 输出 | 用途 |
|------|------|------|------|
| `put(key, value)` | 索引键(序列化后), heap_tid(序列化后) | void | CREATE INDEX, INSERT |
| `get(key)` | 索引键 | heap_tid | 等值查询 WHERE col = x |
| `remove(key)` | 索引键 | bool | DELETE, UPDATE |
| `rangeScan(start, end)` | 范围边界 | list<key,value> | 范围查询 WHERE col BETWEEN |

### 12.5 Key 和 Value 的含义

```
Key (索引键):
┌──────────┬──────────┬────────────────┐
│ indexOid │ key_size │    key_data    │
│  (Oid)   │ (uint32) │ (序列化的列值) │
└──────────┴──────────┴────────────────┘

Value (索引值):
┌───────────────┬──────────┬───────┐
│   heap_tid    │ xact_id  │ flags │
│ (ItemPointer) │ (xid)    │       │
└───────────────┴──────────┴───────┘
         ↓
   6字节: (BlockNumber, OffsetNumber)
   指向表中行的物理位置
```

### 12.6 学习索引的核心任务

学习索引只需要做一件事：

```
输入: 索引键 (如 value = 100)
     ↓
  学习索引（用模型预测位置）
     ↓
输出: heap_tid (如 Block=5, Offset=3)
```

PostgreSQL 会用这个 heap_tid 去表中获取完整行数据。

### 12.7 实现示例框架

```cpp
// learned_index.h
class LearnedIndexImpl : public IndexEngine {
private:
    // 你的学习索引结构
    // 例如: RMI模型, PGM-Index, ALEX 等

public:
    void put(const std::string& key, const std::string& value) override {
        // 1. 训练/更新模型（如果是在线学习）
        // 2. 存储 key -> value 映射
    }

    bool get(const std::string& key, std::string* value) override {
        // 1. 用模型预测 key 的位置
        // 2. 在预测位置附近搜索（处理预测误差）
        // 3. 返回对应的 heap_tid
    }

    void rangeScan(const std::string& start, const std::string& end,
                   std::vector<std::pair<std::string, std::string>>* results) override {
        // 1. 用模型预测 start 的位置
        // 2. 从该位置开始扫描到 end
        // 3. 收集所有匹配的 (key, heap_tid) 对
    }

    void remove(const std::string& key) override {
        // 1. 找到并删除条目
        // 2. 可能需要更新模型
    }
};
```

### 12.8 最简单的实现路径

```
步骤1: 保持现有架构不变（复用 IPC、消息路由等）
步骤2: 只修改 indexengine.cpp
步骤3: 将 std::map 替换为你的学习索引
步骤4: 实现 put/get/remove/rangeScan 四个接口
```

### 12.9 需要提供 vs 可复用

| 需要你提供的 | 已有的(可复用) |
|-------------|---------------|
| 学习索引数据结构 | PostgreSQL接口 (Index AM) |
| put() 实现 | Key/Value序列化 |
| get() 实现 | IPC通信机制 |
| rangeScan() 实现 | 消息路由 (Rocks Service) |
| remove() 实现 | heap_tid处理 |

### 12.10 学习索引实现要点

1. **模型选择**：RMI、PGM-Index、ALEX、LIPP 等
2. **处理预测误差**：学习索引预测位置可能不精确，需要在预测位置附近搜索
3. **更新策略**：如何处理 INSERT/DELETE/UPDATE 对模型的影响
4. **内存管理**：确保在 PostgreSQL 环境下正确管理内存

### 12.11 核心要点

**你只需要实现一个能够存储 `(索引键 → heap_tid)` 映射并支持范围查询的学习索引结构。**

其他所有组件（PostgreSQL 接口、IPC 通信、消息序列化等）都可以直接复用现有代码。

---

## 十三、SELECT 查询实际执行示例

### 13.1 测试场景

```sql
-- 创建表并插入数据
CREATE TABLE test_idx (id INT, val INT) USING nram;
INSERT INTO test_idx SELECT i, i * 10 FROM generate_series(1, 100) AS i;

-- 创建索引
CREATE INDEX test_idx_val ON test_idx USING nrindex (val);

-- 强制使用索引扫描
SET enable_seqscan = off;

-- 执行查询
SELECT * FROM test_idx WHERE val = 500;
```

### 13.2 完整调试输出

```
NOTICE:  ========== NRINDEX BEGINSCAN ==========
NOTICE:  Index: test_idx_val (OID: 32914)
NOTICE:  Number of scan keys: 1
NOTICE:  Number of order by keys: 0
NOTICE:  Scan descriptor initialized
NOTICE:  ========== NRINDEX RESCAN ==========
NOTICE:  Number of scan keys: 1
NOTICE:    ScanKey[0]:
NOTICE:      sk_attno = 1 (which column)
NOTICE:      sk_strategy = 3 (1:<, 2:<=, 3:=, 4:>=, 5:>)
NOTICE:      sk_flags = 0
NOTICE:      sk_argument = 500 (search value)
NOTICE:  Building search key: indexOid=32914, nscankeys=1
NOTICE:  Strategy: EQUAL (=)
NOTICE:  Calling nrindex_rocks_range_scan: min_key=SET, max_key=SET
NOTICE:  Range scan result_count = 1
NOTICE:  ========== NRINDEX RESCAN END ==========
NOTICE:  ========== NRINDEX ENDSCAN ==========
NOTICE:  Ending index scan, cleaning up resources
NOTICE:    result_count = 1
NOTICE:    Freeing 1 result key-value pairs
NOTICE:    Freeing min_key
NOTICE:    Freeing max_key
NOTICE:  ========== NRINDEX ENDSCAN DONE ==========
 id | val
----+-----
 50 | 500
(1 row)
```

### 13.3 执行流程详解

```
SQL: SELECT * FROM test_idx WHERE val = 500;
                    ↓
┌─────────────────────────────────────────────────────────────────┐
│  1. NRINDEX BEGINSCAN - 初始化扫描                               │
├─────────────────────────────────────────────────────────────────┤
│  Index: test_idx_val (OID: 32914)                               │
│  - 确定使用哪个索引                                              │
│  - 分配扫描描述符 (NRIndexScanDesc)                             │
│  - 记录扫描键数量: 1 (WHERE val = 500 是一个条件)                │
└─────────────────────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────────────────────┐
│  2. NRINDEX RESCAN - 设置扫描条件并执行查询                      │
├─────────────────────────────────────────────────────────────────┤
│  ScanKey[0]:                                                    │
│    sk_attno = 1      → 索引的第1列 (val)                        │
│    sk_strategy = 3   → 等于操作符 (=)                           │
│    sk_argument = 500 → 查询值                                   │
│                                                                 │
│  构建搜索 key:                                                   │
│    indexOid = 32914                                             │
│    key_data = serialize(500)                                    │
│                                                                 │
│  Strategy: EQUAL (=)                                            │
│    → min_key = max_key = {32914, serialize(500)}                │
│                                                                 │
│  调用 RocksDB 范围扫描:                                          │
│    nrindex_rocks_range_scan(min_key, max_key)                   │
│         ↓ IPC                                                   │
│    Rocks Service: indexengine_range_scan()                      │
│         ↓                                                       │
│    std::map.find(key) → 找到匹配项!                             │
│         ↓                                                       │
│  result_count = 1  ← 找到 1 条匹配记录                          │
└─────────────────────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────────────────────┐
│  3. PostgreSQL Executor - 获取堆表数据                          │
├─────────────────────────────────────────────────────────────────┤
│  从索引结果获取 heap_tid (ctid)                                  │
│         ↓                                                       │
│  根据 ctid 从堆表读取完整行数据                                  │
│         ↓                                                       │
│  返回: id=50, val=500                                           │
└─────────────────────────────────────────────────────────────────┘
                    ↓
┌─────────────────────────────────────────────────────────────────┐
│  4. NRINDEX ENDSCAN - 清理资源                                   │
├─────────────────────────────────────────────────────────────────┤
│  result_count = 1                                               │
│  - 释放 1 个 key-value 对                                       │
│  - 释放 min_key                                                 │
│  - 释放 max_key                                                 │
└─────────────────────────────────────────────────────────────────┘
                    ↓
            输出: id=50, val=500
```

### 13.4 关键数据流

```
WHERE val = 500
       ↓
┌──────────────────┐
│    ScanKey       │
│  sk_argument=500 │
└────────┬─────────┘
         ↓ nrindex_key_create()
┌──────────────────┐
│   NRIndexKey     │
│  indexOid=32914  │
│  key_data=[500]  │
└────────┬─────────┘
         ↓ IPC to Rocks Service
┌──────────────────┐
│   std::map       │
│  key → value     │
│  [500] → ctid    │
└────────┬─────────┘
         ↓ 找到匹配
┌──────────────────┐
│  NRIndexValue    │
│  heap_tid=(0,50) │
└────────┬─────────┘
         ↓ 访问堆表
┌──────────────────┐
│   Heap Table     │
│  ctid=(0,50)     │
│  → id=50,val=500 │
└──────────────────┘
```

### 13.5 为什么返回 id=50, val=500？

```sql
INSERT INTO test_idx SELECT i, i * 10 FROM generate_series(1, 100) AS i;
```

| i (id) | i * 10 (val) |
|--------|--------------|
| 1      | 10           |
| 2      | 20           |
| ...    | ...          |
| **50** | **500**      |
| ...    | ...          |
| 100    | 1000         |

所以 `val = 500` 对应 `id = 50`。

### 13.6 索引查询 vs 顺序扫描

| 方式 | 操作 | 复杂度 |
|------|------|--------|
| 顺序扫描 | 遍历所有 100 行，逐一比较 | O(n) |
| **索引扫描** | 直接在 std::map 中查找 key | **O(log n)** |

### 13.7 ScanKey 字段详解

`ScanKey` 是 PostgreSQL 传给索引的查询条件结构：

```c
typedef struct ScanKeyData {
    AttrNumber  sk_attno;      // 索引的第几列（从1开始）
    StrategyNumber sk_strategy; // 操作符策略号
    Oid         sk_subtype;    // 操作数类型
    Datum       sk_argument;   // 查询值
    int         sk_flags;      // 标志位（如 SK_ISNULL）
} ScanKeyData;
```

**策略号对应关系**：

| sk_strategy | 操作符 | 含义 |
|-------------|--------|------|
| 1 | < | 小于 |
| 2 | <= | 小于等于 |
| 3 | = | 等于 |
| 4 | >= | 大于等于 |
| 5 | > | 大于 |

### 13.8 nrindex_rescan 核心逻辑

```c
static void nrindex_rescan(IndexScanDesc scan, ScanKey scankey, int nscankeys, ...) {
    // 1. 从 scankey 提取查询值
    Datum *values = palloc(sizeof(Datum) * nscankeys);
    for (int i = 0; i < nscankeys; i++) {
        values[i] = scankey[i].sk_argument;  // 如 500
    }

    // 2. 根据操作符类型构建 key
    switch (scankey[0].sk_strategy) {
        case BTEqualStrategyNumber:  // = 等值查询
            min_key = max_key = nrindex_key_create(..., values, ...);
            break;
        case BTLessStrategyNumber:      // <
        case BTLessEqualStrategyNumber: // <=
            min_key = NULL;
            max_key = nrindex_key_create(..., values, ...);
            break;
        case BTGreaterStrategyNumber:      // >
        case BTGreaterEqualStrategyNumber: // >=
            min_key = nrindex_key_create(..., values, ...);
            max_key = NULL;
            break;
    }

    // 3. 调用 RocksDB 范围扫描
    nrindex_rocks_range_scan(min_key, max_key, &results, &result_count);
}
```

### 13.9 等值查询的特殊处理

对于 `WHERE val = 500`：
- `sk_strategy = 3` (BTEqualStrategyNumber)
- `min_key = max_key = 构建的key`

这样在 `indexengine_range_scan` 中：
```cpp
while (it != data_store.end() && it->first <= end_key) {
    // 因为 start_key == end_key == "500"
    // 只会匹配到精确等于 "500" 的键
    results.push_back(*it);
    ++it;
}
```

### 13.10 完整函数调用链

```
SELECT * FROM test_idx WHERE val = 500;
    │
    ├─► PostgreSQL Parser & Planner
    │       └── 决定使用 Index Scan on test_idx_val
    │
    ├─► index_beginscan()
    │       └── nrindex_beginscan()          [nrindex.c]
    │               └── 分配 NRIndexScanDesc
    │
    ├─► index_rescan()
    │       └── nrindex_rescan()             [nrindex.c]
    │               ├── 解析 ScanKey: val = 500
    │               ├── nrindex_key_create() [nrindex_kv.c]
    │               │       └── 创建 NRIndexKey{indexOid=32914, key_data=[500]}
    │               │
    │               └── nrindex_rocks_range_scan() [nrindex_kv.c]
    │                       └── RocksClientIndexRangeScan() [rocks_handler.c]
    │                               ├── 序列化 key
    │                               ├── KVChannelPushMsg() → 共享内存
    │                               └── KVChannelPopMsg() ← 等待响应
    │                                           │
    │               ════════════════════════════╪════════════════════════════
    │                                           ▼
    │                               Rocks Service Process
    │                               handle_kv_index_range_scan() [rocks_service.c]
    │                                   └── indexengine_range_scan() [indexengine.cpp]
    │                                           └── std::map.lower_bound()
    │                                                   │
    │                                                   └── 找到: key=[500] → heap_tid=(0,50)
    │                                                           │
    │               ════════════════════════════════════════════╪═════════════
    │                                                           │
    │               result_count = 1, results[0] = {heap_tid=(0,50)}
    │
    ├─► index_gettuple() (循环)
    │       └── nrindex_gettuple()           [nrindex.c]
    │               ├── ivalue = results[cursor]
    │               ├── scan->xs_heaptid = ivalue->heap_tid  // (0,50)
    │               └── return true
    │
    ├─► ExecIndexScan()
    │       └── heap_fetch(heap, xs_heaptid)
    │               └── 读取 Block=0, Offset=50 的行
    │                       └── 返回: {id=50, val=500}
    │
    └─► 返回结果
            +----+-----+
            | id | val |
            +----+-----+
            | 50 | 500 |
            +----+-----+
```

### 13.11 总结

| 阶段 | 函数 | 作用 |
|------|------|------|
| 初始化 | `nrindex_beginscan` | 分配扫描状态 |
| 设置条件 | `nrindex_rescan` | 解析 WHERE 条件，构建搜索 key |
| IPC 请求 | `RocksClientIndexRangeScan` | 发送请求到 Rocks Service |
| 执行查询 | `indexengine_range_scan` | 在 std::map 中查找 |
| 返回结果 | `nrindex_gettuple` | 返回 heap_tid 给 PostgreSQL |
| 回表取数 | `heap_fetch` | 用 heap_tid 获取完整行 |
| 清理资源 | `nrindex_endscan` | 释放内存 |

**一句话总结**：`nrindex_rescan` 把 `WHERE val = 500` 转换成索引 key，通过 IPC 发送给 Rocks Service，在 `std::map` 中找到对应的 `heap_tid`，PostgreSQL 用这个 `heap_tid` 回表取出完整的行数据 `{id=50, val=500}`。

---

## 十四、大端字节序编码（Big-Endian Encoding）

### 14.1 为什么需要大端编码？

`std::map` 使用 **字典序（lexicographic order）** 比较字符串 key。这意味着它逐字节比较，从第一个字节开始。

**问题**：x86 架构使用**小端字节序（Little-Endian）**，这会导致整数比较结果错误。

```
示例：比较 140 和 900

小端存储（错误）：
  140 = 0x0000008C → 存储为: 8C 00 00 00
  900 = 0x00000384 → 存储为: 84 03 00 00

字典序比较：8C > 84
结论：140 > 900  ✗ 错误！

大端存储（正确）：
  140 = 0x0000008C → 存储为: 00 00 00 8C
  900 = 0x00000384 → 存储为: 00 00 03 84

字典序比较：00 00 00 8C < 00 00 03 84
结论：140 < 900  ✓ 正确！
```

### 14.2 有符号整数的特殊处理

对于有符号整数，还需要处理负数问题：

```
问题：负数的最高位是 1，正数是 0

原始大端存储：
  -1 = 0xFFFFFFFF → 存储为: FF FF FF FF
   1 = 0x00000001 → 存储为: 00 00 00 01

字典序比较：FF > 00
结论：-1 > 1  ✗ 错误！

解决方案：翻转符号位（XOR 0x80000000）

翻转后：
  -1 = 0xFFFFFFFF ^ 0x80000000 = 0x7FFFFFFF → 存储为: 7F FF FF FF
   1 = 0x00000001 ^ 0x80000000 = 0x80000001 → 存储为: 80 00 00 01

字典序比较：7F < 80
结论：-1 < 1  ✓ 正确！
```

### 14.3 编码函数实现

位于 `src/nrindex_access/nrindex_kv.c`：

```c
/* 无符号 32 位整数 - 大端编码 */
static inline void encode_uint32_be(char *buf, uint32 val)
{
    buf[0] = (val >> 24) & 0xFF;  // 最高字节
    buf[1] = (val >> 16) & 0xFF;
    buf[2] = (val >> 8) & 0xFF;
    buf[3] = val & 0xFF;          // 最低字节
}

/* 有符号 32 位整数 - 大端编码 + 符号位翻转 */
static inline void encode_int32_be(char *buf, int32 val)
{
    uint32 uval = (uint32)val ^ 0x80000000;  // 翻转符号位
    encode_uint32_be(buf, uval);
}

/* 有符号 64 位整数 - 大端编码 + 符号位翻转 */
static inline void encode_int64_be(char *buf, int64 val)
{
    uint64 uval = (uint64)val ^ 0x8000000000000000ULL;
    buf[0] = (uval >> 56) & 0xFF;
    buf[1] = (uval >> 48) & 0xFF;
    buf[2] = (uval >> 40) & 0xFF;
    buf[3] = (uval >> 32) & 0xFF;
    buf[4] = (uval >> 24) & 0xFF;
    buf[5] = (uval >> 16) & 0xFF;
    buf[6] = (uval >> 8) & 0xFF;
    buf[7] = uval & 0xFF;
}
```

### 14.4 解码函数实现

```c
/* 无符号 32 位整数 - 大端解码 */
static inline uint32 decode_uint32_be(const char *buf)
{
    return ((uint32)(unsigned char)buf[0] << 24) |
           ((uint32)(unsigned char)buf[1] << 16) |
           ((uint32)(unsigned char)buf[2] << 8) |
           ((uint32)(unsigned char)buf[3]);
}

/* 有符号 32 位整数 - 大端解码 + 符号位翻转 */
static inline int32 decode_int32_be(const char *buf)
{
    uint32 uval = decode_uint32_be(buf);
    return (int32)(uval ^ 0x80000000);  // 翻转符号位恢复原值
}

/* 有符号 64 位整数 - 大端解码 + 符号位翻转 */
static inline int64 decode_int64_be(const char *buf)
{
    uint64 uval = ((uint64)(unsigned char)buf[0] << 56) |
                  ((uint64)(unsigned char)buf[1] << 48) |
                  ((uint64)(unsigned char)buf[2] << 40) |
                  ((uint64)(unsigned char)buf[3] << 32) |
                  ((uint64)(unsigned char)buf[4] << 24) |
                  ((uint64)(unsigned char)buf[5] << 16) |
                  ((uint64)(unsigned char)buf[6] << 8) |
                  ((uint64)(unsigned char)buf[7]);
    return (int64)(uval ^ 0x8000000000000000ULL);
}
```

### 14.5 Key 序列化格式

索引 Key 的完整序列化格式如下：

```
┌─────────────────────────────────────────────────────────────────┐
│                     NRIndexKey 序列化格式                        │
├─────────────┬─────────────┬────────────────────────────────────┤
│  indexOid   │  key_size   │            key_data                │
│  (4 bytes)  │  (4 bytes)  │         (variable)                 │
│  大端编码   │   大端编码   │          大端编码                  │
└─────────────┴─────────────┴────────────────────────────────────┘

示例：索引 OID=16385，键值 val=900

indexOid = 16385 = 0x00004001
  大端编码: 00 00 40 01

key_size = 4
  大端编码: 00 00 00 04

key_data (INT4, val=900):
  900 = 0x00000384
  翻转符号位: 0x00000384 ^ 0x80000000 = 0x80000384
  大端编码: 80 00 03 84

完整序列化结果（12 字节）:
  00 00 40 01  00 00 00 04  80 00 03 84
  └─ OID ──┘  └─ size ──┘  └─ key ───┘
```

### 14.6 Key 创建流程

```c
NRIndexKey nrindex_key_create(Oid indexOid, Datum *values, bool *isnull,
                               int nkeys, TupleDesc indexTupDesc)
{
    // 1. 计算总大小
    for (i = 0; i < nkeys; i++) {
        switch (typid) {
            case INT2OID: lens[i] = 4; break;  // 扩展为 int32
            case INT4OID: lens[i] = 4; break;
            case INT8OID: lens[i] = 8; break;
            default: lens[i] = datumEstimateSpace(...);
        }
    }

    // 2. 分配内存
    ikey = palloc0(total_size);
    ikey->indexOid = indexOid;
    ikey->key_size = ...;

    // 3. 序列化各列值（大端编码）
    for (i = 0; i < nkeys; i++) {
        switch (typid) {
            case INT2OID:
                encode_int32_be(pos, (int32)DatumGetInt16(values[i]));
                pos += 4;
                break;
            case INT4OID:
                encode_int32_be(pos, DatumGetInt32(values[i]));
                pos += 4;
                break;
            case INT8OID:
                encode_int64_be(pos, DatumGetInt64(values[i]));
                pos += 8;
                break;
            default:
                datumSerialize(values[i], ...);  // PostgreSQL 默认序列化
        }
    }

    return ikey;
}
```

### 14.7 范围查询如何利用大端编码

```
查询：SELECT * FROM test_idx WHERE val > 900

步骤：
1. 构建 min_key（val=901，包含起始点）
2. 构建 max_key（最大值，或索引边界）
3. 发送到 Rocks Service

在 std::map 中：
  所有 key 都是大端编码
  map.lower_bound(min_key) 返回第一个 >= min_key 的迭代器

  由于大端编码保证了字典序 = 数值序：
    key(901) < key(902) < key(1000) < ...

  所以范围查询结果是正确排序的！
```

### 14.8 支持的数据类型

| PostgreSQL 类型 | OID | 编码方式 | 大小 |
|----------------|-----|----------|------|
| `smallint` (INT2) | INT2OID | 扩展为 int32，大端编码 | 4 字节 |
| `integer` (INT4) | INT4OID | 大端编码 + 符号位翻转 | 4 字节 |
| `bigint` (INT8) | INT8OID | 大端编码 + 符号位翻转 | 8 字节 |
| 其他类型 | - | PostgreSQL 默认 `datumSerialize` | 变长 |

### 14.9 总结

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| 整数比较错误 | x86 小端存储，字典序比较错误 | 使用大端编码 |
| 负数排序错误 | 负数最高位为 1，字典序大于正数 | 翻转符号位 (XOR 0x80000000) |
| 范围查询错误 | 上述两个原因导致 | 大端编码 + 符号位翻转 |

**核心原理**：通过大端编码和符号位翻转，使得 `std::map` 的字典序比较结果与数值比较结果一致，从而支持正确的范围查询。

---

## 十五、LIPP 索引测试流程

本节介绍如何使用 SOSD 数据集测试 LIPP（Learned Index with Precise Positions）索引的性能。

### 15.1 LIPP 索引概述

LIPP 是一种学习索引，使用线性模型预测 key 的位置，相比传统 B-tree 具有更好的空间效率和查询性能。

**LIPP 特点：**
- 支持 `insert(key, value)` 插入
- 支持 `at(key)` 点查询
- 支持 `exists(key)` 存在性检查
- **不支持** 删除操作
- **不支持** 原生范围查询

**当前实现：**
- 每个索引（indexOid）对应一个独立的 LIPP 实例
- Key 类型：`int64_t`（通过符号位翻转编码）
- Value 类型：`uint64_t`（压缩的 heap_tid）

### 15.2 测试数据准备

#### 15.2.1 下载 SOSD 数据集

```bash
# 创建目录
mkdir -p /hdd9/benjamin/SOSD/scripts/data
cd /hdd9/benjamin/SOSD/scripts/data

## 转换为 CSV 格式

使用 `/hdd9/benjamin/SOSD/scripts/data/sosd_to_pg.py` 脚本：

```bash
cd /hdd9/benjamin/SOSD/scripts/data

# 转换为 CSV（100 万条）
python sosd_to_pg.py books_200M_uint32 -o books.csv -l 1000000

# 或转换全部数据（2 亿条）
python3 sosd_to_pg.py books_200M_uint32 -o books_full.csv -l 200000000
```

#### 15.2.3 将数据复制到 Docker 容器

```bash
# 复制 100 万条测试数据
head -n 1000001 /hdd9/benjamin/SOSD/scripts/data/books.csv > /tmp/books_1m.csv

# 复制到 Docker 容器
docker cp /tmp/books_1m.csv <container_id>:/tmp/books_1m.csv
```

### 15.3 创建表和导入数据

连接到 PostgreSQL：

```bash
/code/neurdb-dev/psql/bin/psql -h localhost -U neurdb
```

在 psql 中执行：

```sql
-- 1. 创建表
DROP TABLE IF EXISTS books;
CREATE TABLE books (
    id INT PRIMARY KEY,
    val INT
);

-- 2. 导入数据
\copy books FROM '/tmp/books_1m.csv' CSV HEADER;

-- 3. 确认数据量
SELECT COUNT(*) FROM books;
```

### 15.4 创建 LIPP 索引

```sql
-- 开启计时
\timing on

-- 创建 LIPP 索引
CREATE INDEX idx_books_val ON books USING nrindex(val);
```

### 15.5 测试查询

#### 15.5.1 单次查询测试

```sql
\timing on

-- 查看前几行数据
SELECT * FROM books LIMIT 5;

-- 点查询（使用实际存在的值）
SELECT * FROM books WHERE val = (SELECT val FROM books LIMIT 1);

-- 多次查询测试
SELECT * FROM books WHERE val = (SELECT val FROM books OFFSET 1000 LIMIT 1);
SELECT * FROM books WHERE val = (SELECT val FROM books OFFSET 2000 LIMIT 1);
SELECT * FROM books WHERE val = (SELECT val FROM books OFFSET 3000 LIMIT 1);
```

#### 15.5.2 批量查询测试（1 万次）

**方法 1：SQL 循环**

```sql
\timing on

DO $$
DECLARE
    i INT;
    v INT;
    result RECORD;
BEGIN
    FOR i IN 1..10000 LOOP
        SELECT val INTO v FROM books OFFSET floor(random() * 100000)::int LIMIT 1;
        SELECT * INTO result FROM books WHERE val = v;
    END LOOP;
END $$;
```

**方法 2：使用 pgbench**

```bash
# 1. 创建查询脚本
cat > /tmp/test_query.sql << 'EOF'
\set val random(1, 1000000)
SELECT * FROM books WHERE val = :val;
EOF

# 2. 运行 1 万次查询
/code/neurdb-dev/psql/bin/pgbench -h localhost -U neurdb \
  -f /tmp/test_query.sql \
  -c 1 -t 10000 -r neurdb
```

### 15.6 性能测试结果解读

**pgbench 输出示例：**

```
transaction type: /tmp/test_query.sql
scaling factor: 1
number of clients: 1
number of transactions per client: 10000
latency average = 0.5 ms
tps = 2000.123456 (without initial connection time)
```

**关键指标：**

| 指标 | 含义 |
|------|------|
| `latency average` | 平均查询延迟 |
| `tps` | 每秒事务数（吞吐量） |
| `Time` (SQL 循环) | 总执行时间 |

### 15.7 对比测试：LIPP vs B-tree

```sql
-- 创建 B-tree 索引进行对比
DROP INDEX IF EXISTS idx_books_val;
CREATE INDEX idx_books_val_btree ON books USING btree(val);

-- 运行相同的测试
\timing on
DO $$
DECLARE
    i INT;
    v INT;
    result RECORD;
BEGIN
    FOR i IN 1..10000 LOOP
        SELECT val INTO v FROM books OFFSET floor(random() * 100000)::int LIMIT 1;
        SELECT * INTO result FROM books WHERE val = v;
    END LOOP;
END $$;

-- 切换回 LIPP 索引
DROP INDEX IF EXISTS idx_books_val_btree;
CREATE INDEX idx_books_val ON books USING nrindex(val);
```

### 15.8 不同数据量测试

| 数据量 | 用途 | CSV 文件 |
|--------|------|----------|
| 100 万 | 功能测试 | `books_1m.csv` |
| 1000 万 | 性能测试 | `books_10m.csv` |
| 1 亿 | 完整测试 | `books_100m.csv` |

```bash
# 生成不同大小的测试文件
head -n 1000001 /hdd9/benjamin/SOSD/scripts/data/books.csv > /tmp/books_1m.csv
head -n 10000001 /hdd9/benjamin/SOSD/scripts/data/books.csv > /tmp/books_10m.csv
head -n 100000001 /hdd9/benjamin/SOSD/scripts/data/books.csv > /tmp/books_100m.csv
```

### 15.9 调试与日志

LIPP 索引操作会输出日志，查看方式：

```bash
# 查看 PostgreSQL 日志
docker logs <container_id> 2>&1 | grep -i lipp

# 或查看 rocks_service 日志
tail -f /path/to/postgresql/log/*.log | grep -i lipp
```

**日志示例：**

```
[LIPP] insert called: key=2147583647, value=4294967296
[LIPP] insert done
[LIPP] exists called: key=2147583647
[LIPP] FOUND
```

### 15.10 常见问题

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| 查询返回 0 行 | val 值不存在 | 使用 `SELECT val FROM books LIMIT 1` 获取实际存在的值 |
| 创建索引崩溃 | LIPP 内存预热 | 确保 `lipp.h` 中内存预热已禁用 |
| 范围查询不支持 | LIPP 限制 | 仅支持等值查询 (`val = X`) |
| 删除操作忽略 | LIPP 限制 | 当前实现不支持删除 |

### 15.11 构造测试 SQL：查询表中实际存在的数据

为了保证测试的准确性，查询的值必须是表中实际存在的数据。以下是几种构造测试 SQL 的方法。

#### 15.11.1 关闭 NOTICE 消息

测试前建议关闭提示消息，避免干扰输出：

```sql
-- 关闭 NOTICE 消息，只显示 WARNING 和 ERROR
SET client_min_messages = WARNING;
```

#### 15.11.2 方法 1：预先导出存在的值（pgbench）

```bash
# 1. 导出表中实际存在的 val 值到文件
#    -t: 只输出数据（无表头）
#    -A: 无对齐格式（纯数值，每行一个）
/code/neurdb-dev/psql/bin/psql -h localhost -U neurdb -t -A -c \
  "SELECT val FROM test_lipp ORDER BY random() LIMIT 10000;" > /tmp/existing_vals.txt

# 2. 检查导出结果（应该是纯数字，每行一个）
head -5 /tmp/existing_vals.txt
# 输出示例：
# 123456
# 789012
# 345678
# ...

# 3. 生成 pgbench 脚本（每行一个查询）
while read val; do
  echo "SELECT * FROM test_lipp WHERE val = $val;"
done < /tmp/existing_vals.txt > /tmp/test_query.sql

# 4. 检查生成的 SQL 文件（确保格式正确）
head -5 /tmp/test_query.sql
# 输出示例：
# SELECT * FROM test_lipp WHERE val = 123456;
# SELECT * FROM test_lipp WHERE val = 789012;
# SELECT * FROM test_lipp WHERE val = 345678;
# ...

# 5. 用 pgbench 执行
#    -n: 跳过 vacuum（重要！使用自定义表时必须加此参数）
#    -t 1: 执行 1 次（文件里已有 10000 条查询）
#    -r: 显示每条语句的延迟报告
/code/neurdb-dev/psql/bin/pgbench -h localhost -U neurdb \
  -n -f /tmp/test_query.sql \
  -c 1 -t 1 -r neurdb
```

**注意事项：**

1. **必须加 `-n` 参数**：pgbench 默认会 vacuum `pgbench_*` 表，使用自定义表时需要 `-n` 跳过
2. **检查生成的文件**：如果文件内容包含 shell 提示符或其他非 SQL 内容，会导致语法错误
3. **`-t 1` 含义**：由于 SQL 文件里已经有 10000 条查询，`-t 1` 表示执行整个文件 1 次

**常见问题：终端转义字符导致语法错误**

使用 `while read` 生成 SQL 文件时，可能会遇到以下错误：

```
pgbench: error: client 0 script 0 aborted in command 0 query 0: ERROR: syntax error at or near "
```

**问题原因：**

VSCode 或其他现代终端会注入转义序列（用于终端集成功能）。使用 `cat -A` 检查文件可以看到：

```bash
$ cat -A /tmp/test_query.sql | head -3
^[]633;E;read val;xxx^G^[]633;C^GSELECT * FROM test_lipp WHERE val = 123;$
SELECT * FROM test_lipp WHERE val = 456;$
```

第一行包含 `^[]633;...^G` 这些不可见的转义字符，导致 SQL 语法错误。

**解决方案：直接用 PostgreSQL 生成 SQL 文件（推荐）**

```bash
# 在 PostgreSQL 内部拼接 SQL 语句，避免 shell 处理
/code/neurdb-dev/psql/bin/psql -h localhost -U neurdb -t -A -c \
  "SELECT 'SELECT * FROM test_lipp WHERE val = ' || val || ';' FROM test_lipp ORDER BY random() LIMIT 10000;" \
  > /tmp/test_query.sql

# 检查文件（应该没有转义字符）
cat -A /tmp/test_query.sql | head -3
# 正确输出：
# SELECT * FROM test_lipp WHERE val = 123456;$
# SELECT * FROM test_lipp WHERE val = 789012;$
# SELECT * FROM test_lipp WHERE val = 345678;$

# 运行测试
/code/neurdb-dev/psql/bin/pgbench -h localhost -U neurdb \
  -n -f /tmp/test_query.sql -c 1 -t 1 -r neurdb
```

这个方法的优点：
- 完全在 PostgreSQL 内部生成 SQL 语句
- 不经过 shell 的 `while read` 循环
- 避免终端转义字符污染文件

**一条命令完成所有步骤（推荐）：**

```bash
/code/neurdb-dev/psql/bin/psql -h localhost -U neurdb -t -A -c \
  "SELECT 'SELECT * FROM test_lipp WHERE val = ' || val || ';' FROM test_lipp ORDER BY random() LIMIT 10000;" \
  > /tmp/test_query.sql && \
/code/neurdb-dev/psql/bin/pgbench -h localhost -U neurdb \
  -n -f /tmp/test_query.sql -c 1 -t 1 -r neurdb
```

#### 15.11.3 方法 2：SQL 循环（每次随机取值）

```sql
SET client_min_messages = WARNING;
\timing on

DO $$
DECLARE
    i INT;
    v INT;
    result RECORD;
BEGIN
    FOR i IN 1..10000 LOOP
        -- 从表中随机取一个实际存在的 val
        SELECT val INTO v FROM books OFFSET floor(random() * (SELECT COUNT(*) FROM books))::int LIMIT 1;
        -- 查询
        SELECT * INTO result FROM books WHERE val = v;
    END LOOP;
END $$;
```

#### 15.11.4 方法 3：优化的 SQL 循环（预先获取总行数）

```sql
SET client_min_messages = WARNING;
\timing on

DO $$
DECLARE
    i INT;
    v INT;
    result RECORD;
    total_rows INT;
BEGIN
    -- 先获取总行数（只查一次，避免重复计算）
    SELECT COUNT(*) INTO total_rows FROM books;

    FOR i IN 1..10000 LOOP
        -- 随机取一个存在的 val
        SELECT val INTO v FROM books OFFSET floor(random() * total_rows)::int LIMIT 1;
        -- 查询
        SELECT * INTO result FROM books WHERE val = v;
    END LOOP;
END $$;
```

#### 15.11.5 方法 4：预加载到数组（推荐，最高效）

```sql
SET client_min_messages = WARNING;
\timing on

DO $$
DECLARE
    vals INT[];
    v INT;
    result RECORD;
    i INT;
BEGIN
    -- 预先随机取 10000 个存在的值，存入数组
    SELECT array_agg(val) INTO vals
    FROM (SELECT val FROM books ORDER BY random() LIMIT 10000) t;

    -- 循环查询（直接从数组取值，无需每次访问表）
    FOR i IN 1..10000 LOOP
        v := vals[i];
        SELECT * INTO result FROM books WHERE val = v;
    END LOOP;
END $$;
```

#### 15.11.6 方法对比

| 方法 | 优点 | 缺点 | 推荐场景 |
|------|------|------|----------|
| 方法 1 (pgbench) | 标准工具，输出详细 | 需要预处理文件 | 正式性能测试 |
| 方法 2 (基础循环) | 简单直接 | 每次循环都计算 COUNT | 快速验证 |
| 方法 3 (优化循环) | 减少 COUNT 开销 | 仍有 OFFSET 开销 | 中等规模测试 |
| 方法 4 (数组预加载) | 最高效，开销最小 | 内存占用稍高 | **推荐** |

#### 15.11.7 完整测试示例

```sql
-- 1. 关闭提示消息
SET client_min_messages = WARNING;

-- 2. 开启计时
\timing on

-- 3. 执行 10000 次查询（使用方法 4）
DO $$
DECLARE
    vals INT[];
    v INT;
    result RECORD;
    i INT;
BEGIN
    SELECT array_agg(val) INTO vals
    FROM (SELECT val FROM books ORDER BY random() LIMIT 10000) t;

    FOR i IN 1..10000 LOOP
        v := vals[i];
        SELECT * INTO result FROM books WHERE val = v;
    END LOOP;
END $$;

-- 输出示例：
-- DO
-- Time: 3500.123 ms (00:03.500)
--
-- 表示 10000 次查询总耗时 3.5 秒，平均每次 0.35 ms
```

#### 15.11.8 调整查询次数

修改循环次数和数组大小即可：

```sql
-- 1000 次查询
SELECT array_agg(val) INTO vals
FROM (SELECT val FROM books ORDER BY random() LIMIT 1000) t;

FOR i IN 1..1000 LOOP
    ...
END LOOP;

-- 100000 次查询
SELECT array_agg(val) INTO vals
FROM (SELECT val FROM books ORDER BY random() LIMIT 100000) t;

FOR i IN 1..100000 LOOP
    ...
END LOOP;
```

## 16. pgbench 索引性能测试

### 16.1 pgbench 测试命令

```bash
/code/neurdb-dev/psql/bin/pgbench -h localhost -U neurdb -n -f /tmp/test_query.sql -c 64 -t 1 neurdb
```

| 参数 | 含义 |
|------|------|
| `-h localhost` | 连接本地数据库 |
| `-U neurdb` | 使用 neurdb 用户 |
| `-n` | 不执行初始化 |
| `-f /tmp/test_query.sql` | 执行自定义 SQL 文件 |
| `-c 64` | 64 个并发客户端 |
| `-t 1` | 每个客户端执行 1 次事务 |
| `neurdb` | 数据库名 |

### 16.2 确认查询是否使用了索引

#### 方法一：EXPLAIN ANALYZE

```sql
EXPLAIN ANALYZE SELECT * FROM test_lipp WHERE val = 97810;
```

如果使用了索引，会显示 `Index Scan using 索引名`。

#### 方法二：查看索引使用统计

```sql
-- 测试前后对比
SELECT indexrelname, idx_scan, idx_tup_read
FROM pg_stat_user_indexes
WHERE relname = 'test_lipp';
```

### 16.3 强制不使用索引（对比测试）

**重要：SET 命令只在当前 session 生效，不影响 pgbench 创建的新连接！**

#### 错误做法（无效）

```sql
-- 在 psql 中执行，只对当前连接有效
SET enable_indexscan = off;
SET enable_bitmapscan = off;
```

然后运行 pgbench —— pgbench 的连接不受影响，仍然使用索引。

#### 正确做法

把 SET 命令加到测试文件中：

```bash
# 创建不使用索引的测试文件
echo "SET enable_indexscan = off;
SET enable_bitmapscan = off;" > /tmp/test_query_no_index.sql
cat /tmp/test_query.sql >> /tmp/test_query_no_index.sql
```

然后分别测试：

```bash
# 不使用索引
/code/neurdb-dev/psql/bin/pgbench -h localhost -U neurdb -n -f /tmp/test_query_no_index.sql -c 64 -t 1 neurdb

# 使用索引
/code/neurdb-dev/psql/bin/pgbench -h localhost -U neurdb -n -f /tmp/test_query.sql -c 64 -t 1 neurdb
```

### 16.4 恢复默认设置

```sql
SET enable_indexscan = on;
SET enable_bitmapscan = on;
SET enable_seqscan = on;
```

## 17. btree 索引调用流程

### 17.1 索引创建调用链

```
CREATE INDEX ... USING btree
        │
        ▼
┌─────────────────────────────────────────┐
│ DefineIndex()                           │
│ src/backend/commands/indexcmds.c        │
│ - 解析 CREATE INDEX 语句                │
│ - 确定索引类型和参数                    │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ index_create()                          │
│ src/backend/catalog/index.c             │
│ - 在系统表中创建索引条目                │
│ - 分配索引文件                          │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ index_build()                           │
│ src/backend/catalog/index.c             │
│ - 调用: amroutine->ambuild()            │
│ - 通过函数指针调用具体 AM 的 build      │
└──────────────┬──────────────────────────┘
               │
               ▼
┌─────────────────────────────────────────┐
│ btbuild()                               │
│ src/backend/access/nbtree/nbtsort.c     │
│ - 扫描表数据                            │
│ - 排序并构建 B-tree 结构                │
└─────────────────────────────────────────┘
```

### 17.2 btree AM 函数注册

在 `src/backend/access/nbtree/nbtree.c` 中，`bthandler` 函数注册了所有 btree 的操作函数：

```c
// nbtree.c 第 122 行
amroutine->ambuild = btbuild;           // 构建索引
amroutine->ambuildempty = btbuildempty; // 构建空索引
amroutine->aminsert = btinsert;         // 插入
amroutine->ambulkdelete = btbulkdelete; // 批量删除
amroutine->amvacuumcleanup = btvacuumcleanup;  // VACUUM 清理
amroutine->amcostestimate = btcostestimate;   // 成本估算
amroutine->ambeginscan = btbeginscan;   // 开始扫描
amroutine->amrescan = btrescan;         // 重新扫描
amroutine->amgettuple = btgettuple;     // 获取元组
amroutine->amendscan = btendscan;       // 结束扫描
```

### 17.3 btree 关键源码文件

| 文件 | 作用 |
|------|------|
| `src/backend/access/nbtree/nbtree.c` | AM 入口，注册 bthandler |
| `src/backend/access/nbtree/nbtsort.c` | btbuild() 批量构建索引 |
| `src/backend/access/nbtree/nbtinsert.c` | _bt_doinsert() 插入操作 |
| `src/backend/access/nbtree/nbtsearch.c` | _bt_search() 查找操作 |
| `src/backend/access/nbtree/nbtpage.c` | 页面操作 |
| `src/backend/access/nbtree/nbtutils.c` | 工具函数 |

### 17.4 btree 与 nrindex 架构对比

**btree（原生索引）：**
```
┌─────────────────────────────────────┐
│          PostgreSQL 进程            │
│  ┌─────────────────────────────┐   │
│  │     btree 索引代码          │   │
│  │  (src/backend/access/nbtree)│   │
│  └──────────────┬──────────────┘   │
│                 │ 直接内存访问      │
│                 ▼                   │
│  ┌─────────────────────────────┐   │
│  │  共享缓冲区 (shared_buffers) │  │
│  └──────────────┬──────────────┘   │
│                 │                   │
└─────────────────┼───────────────────┘
                  ▼
         ┌───────────────┐
         │   磁盘文件     │
         └───────────────┘
```

**nrindex（学习索引）：**
```
┌─────────────────────────────────────┐
│          PostgreSQL 进程            │
│  ┌─────────────────────────────┐   │
│  │     nrindex 客户端代码      │   │
│  └──────────────┬──────────────┘   │
│                 │ IPC (共享内存)    │
└─────────────────┼───────────────────┘
                  ▼
┌─────────────────────────────────────┐
│        indexengine 进程             │
│  ┌─────────────────────────────┐   │
│  │   LIPP 学习索引实现         │   │
│  └──────────────┬──────────────┘   │
│                 ▼                   │
│  ┌─────────────────────────────┐   │
│  │      RocksDB                │   │
│  └─────────────────────────────┘   │
└─────────────────────────────────────┘
```

### 17.5 性能差异原因

| 操作 | btree | nrindex |
|------|-------|---------|
| 索引查找 | 直接内存访问 | IPC 消息传递 |
| 数据读取 | 共享缓冲区缓存 | RocksDB 读取 |
| 进程切换 | 无 | 有 |
| 通信开销 | 0 | ~1-2ms/次 |
