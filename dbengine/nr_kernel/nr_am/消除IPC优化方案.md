# 消除 IPC 优化方案：让 LIPP 在 Backend 进程内运行

## 问题背景

当前 nrindex 的点查询性能比 B-tree 慢约 150 倍：

| 索引 | 执行时间 |
|------|----------|
| B-tree | 0.065 ms |
| nrindex (LIPP) | ~8 ms |

**根本原因不是 LIPP 算法慢，而是 IPC 跨进程通信开销。**

---

## 当前架构

```
┌─────────────────────────────────────────────────────────────────┐
│                         PostgreSQL                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌─────────────┐          ┌─────────────────────────────────┐  │
│  │  Backend 1  │          │  CustomStorageWorker (BGW)      │  │
│  │  (C 语言)    │   IPC    │  (C++ 进程)                      │  │
│  │             │ ◄──────► │                                 │  │
│  │  nrindex.c  │  共享内存  │  rocks_service.c               │  │
│  │             │  通道     │       ↓                         │  │
│  └─────────────┘          │  indexengine.cpp                │  │
│                           │       ↓                         │  │
│  ┌─────────────┐          │  LIPP<int64_t, uint64_t>        │  │
│  │  Backend 2  │   IPC    │                                 │  │
│  │             │ ◄──────► │                                 │  │
│  └─────────────┘          └─────────────────────────────────┘  │
│                                                                 │
│  问题: 每次查询都要跨进程通信，延迟 ~8ms                           │
└─────────────────────────────────────────────────────────────────┘
```

### 时间分解

| 操作 | nrindex | B-tree |
|------|---------|--------|
| 序列化请求 | ~0.5 ms | 0 |
| IPC 发送 | ~2 ms | 0 |
| 等待 + 上下文切换 | ~3 ms | 0 |
| **LIPP 查询本身** | **~0.001 ms** | - |
| B-tree 查询本身 | - | **~0.05 ms** |
| IPC 接收 | ~2 ms | 0 |
| 反序列化响应 | ~0.5 ms | 0 |
| **总计** | **~8 ms** | **~0.05 ms** |

**LIPP 本身只要 0.001ms，但 IPC 开销加了 8ms！**

---

## 目标架构

```
┌─────────────────────────────────────────────────────────────────┐
│                         PostgreSQL                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Backend 1 (加载 nram.so)                                  │  │
│  │                                                           │  │
│  │  nrindex.c  ──直接调用──►  indexengine.cpp                 │  │
│  │      ↓                          ↓                         │  │
│  │  nrindex_gettuple()        LIPP<int64_t, uint64_t>        │  │
│  │      ↓                          ↓                         │  │
│  │    Result  ◄───────────────  lipp->at(key)                │  │
│  │                                                           │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Backend 2 (加载 nram.so)                                  │  │
│  │    同样直接调用                                             │  │
│  └───────────────────────────────────────────────────────────┘  │
│                                                                 │
│  优势: 直接函数调用，延迟 ~0.001ms                                │
└─────────────────────────────────────────────────────────────────┘
```

---

## 具体改动

### 1. 修改调用链

```
当前:
nrindex.c → rocks_handler.c → [IPC] → rocks_service.c → indexengine.cpp

目标:
nrindex.c → indexengine.cpp (直接调用)
```

### 2. 文件改动

| 文件 | 改动 |
|------|------|
| `nrindex.c` | 直接调用 `indexengine_*` 函数，不再通过 IPC |
| `indexengine.cpp` | 保持不变，已经是 C 接口 |
| `rocks_handler.c` | 索引相关函数可删除 |
| `rocks_service.c` | 索引相关 handler 可删除 |
| `msg.h` | 索引相关消息类型可删除 |

### 3. 代码对比

```c
/* ============ 当前实现 (IPC) ============ */
// nrindex.c
static void nrindex_rocks_put(NRIndexKey ikey, NRIndexValue ivalue) {
    // 通过 IPC 发送到另一个进程
    RocksClientIndexPut(ikey, ivalue);  // 需要序列化 → IPC → 反序列化
}

/* ============ 目标实现 (直接调用) ============ */
// nrindex.c
#include "indexengine.h"

static IndexEngine *local_engine = NULL;

static void nrindex_rocks_put(NRIndexKey ikey, NRIndexValue ivalue) {
    if (local_engine == NULL) {
        local_engine = indexengine_open();
    }
    // 直接调用，无 IPC
    indexengine_put(local_engine, ikey, ivalue);
}
```

---

## 关键挑战与解决方案

### 挑战 1：多 Backend 共享同一个索引

```
问题:
  Backend 1 插入数据 → 它的 local LIPP
  Backend 2 查询数据 → 它的 local LIPP (看不到 Backend 1 的数据!)
```

#### 解决方案 A: 共享内存中的 LIPP

```
┌─────────────────────────────────────────┐
│           PostgreSQL 共享内存            │
│  ┌─────────────────────────────────┐    │
│  │  LIPP 实例 (所有 Backend 共享)    │    │
│  └─────────────────────────────────┘    │
│       ↑           ↑           ↑         │
│   Backend 1   Backend 2   Backend 3     │
└─────────────────────────────────────────┘

难点: LIPP 使用 std::vector 等 STL，需要自定义 allocator
      使其分配在共享内存中
```

#### 解决方案 B: 每个 Backend 独立 LIPP + 持久化

```
┌──────────┐  ┌──────────┐  ┌──────────┐
│ Backend 1│  │ Backend 2│  │ Backend 3│
│  LIPP    │  │  LIPP    │  │  LIPP    │
└────┬─────┘  └────┬─────┘  └────┬─────┘
     │             │             │
     └─────────────┼─────────────┘
                   ↓
            ┌──────────────┐
            │  持久化存储   │
            │  (RocksDB)   │
            └──────────────┘

启动时从 RocksDB 加载数据到各自的 LIPP
```

### 挑战 2：C 调用 C++

```
当前已解决:
  indexengine.h   -- C 接口声明
  indexengine.cpp -- C++ 实现，extern "C" 导出

PostgreSQL (C) 可以直接链接 indexengine.o
```

### 挑战 3：内存管理

```
当前 (IPC 架构):
  IndexEngine 进程管理自己的内存
  生命周期: PostgreSQL 运行期间

目标 (进程内):
  选项 A: 每个 Backend 启动时 new，退出时 delete
  选项 B: 放在 PostgreSQL 共享内存，Postmaster 启动时初始化
```

---

## 性能预期

| 操作 | 当前 (IPC) | 目标 (直接调用) | 提升 |
|------|-----------|----------------|------|
| 点查询 | ~8 ms | ~0.001 ms | **8000x** |
| 插入 | ~10 ms | ~0.01 ms | **1000x** |
| 批量加载 1M | ~2s | ~0.1s | **20x** |

---

## 实现步骤

### 第一步: 选择共享策略

```
├── 方案 A: 共享内存 LIPP (复杂，需要自定义 allocator)
└── 方案 B: 每 Backend 独立 LIPP + RocksDB 持久化 (简单，推荐)
```

### 第二步: 修改 nrindex.c

- 移除 `RocksClientIndex*` 调用
- 直接调用 `indexengine_*` 函数
- 管理 local IndexEngine 实例生命周期

### 第三步: 处理并发

- 多 Backend 同时写入: 需要锁或其他同步机制
- LIPP 本身不是线程安全的，需要加锁

### 第四步: 处理持久化

- 当前 LIPP 是纯内存的，重启后数据丢失
- 需要结合 RocksDB 持久化或实现 checkpoint

---

## 总结

| 方面 | 当前架构 | 目标架构 |
|------|---------|---------|
| 调用方式 | IPC 跨进程 | 直接函数调用 |
| 点查询延迟 | ~8 ms | ~0.001 ms |
| 复杂度 | 高 (序列化/反序列化) | 低 (直接调用) |
| 数据共享 | 天然共享 (单一进程) | 需要处理 |
| 持久化 | 已有 | 需要保持 |

**核心结论：瓶颈是 IPC，不是 LIPP 算法。消除 IPC 后，nrindex 性能可超越 B-tree。**
