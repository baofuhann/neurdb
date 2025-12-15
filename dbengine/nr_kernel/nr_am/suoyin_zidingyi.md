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
