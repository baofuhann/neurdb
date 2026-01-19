#!/bin/bash
# ============================================================================
# switch_nrindex_mode.sh
# 切换 nrindex 的运行模式（直接调用 vs IPC）
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NRINDEX_KV_FILE="$SCRIPT_DIR/src/nrindex_access/nrindex_kv.c"

usage() {
    echo "Usage: $0 [direct|ipc|status]"
    echo ""
    echo "Commands:"
    echo "  direct  - 切换到直接调用模式（高性能，单连接）"
    echo "  ipc     - 切换到 IPC 模式（支持多连接，有 IPC 开销）"
    echo "  status  - 显示当前模式"
    echo ""
    echo "模式对比:"
    echo "  ┌──────────────┬───────────────┬───────────────┐"
    echo "  │     模式     │   查询延迟    │   多连接支持  │"
    echo "  ├──────────────┼───────────────┼───────────────┤"
    echo "  │ direct       │   ~0.5 ms     │      ❌       │"
    echo "  │ ipc          │   ~8 ms       │      ✅       │"
    echo "  └──────────────┴───────────────┴───────────────┘"
    echo ""
    echo "切换后需要重新编译："
    echo "  cd $SCRIPT_DIR && make clean && make && sudo make install"
    exit 1
}

check_current_mode() {
    if grep -q "^#define NRINDEX_DIRECT_MODE" "$NRINDEX_KV_FILE"; then
        echo "direct"
    elif grep -q "^/\* #define NRINDEX_DIRECT_MODE \*/" "$NRINDEX_KV_FILE"; then
        echo "ipc"
    else
        echo "unknown"
    fi
}

switch_to_direct() {
    echo "切换到直接调用模式..."
    sed -i 's|^/\* #define NRINDEX_DIRECT_MODE \*/|#define NRINDEX_DIRECT_MODE|' "$NRINDEX_KV_FILE"
    echo "✅ 已切换到直接调用模式"
    echo ""
    echo "⚠️  注意：直接调用模式仅支持单连接测试"
    echo "    多个 psql 连接将看不到彼此的索引数据"
}

switch_to_ipc() {
    echo "切换到 IPC 模式..."
    sed -i 's|^#define NRINDEX_DIRECT_MODE|/* #define NRINDEX_DIRECT_MODE */|' "$NRINDEX_KV_FILE"
    echo "✅ 已切换到 IPC 模式"
    echo ""
    echo "✅ IPC 模式支持多连接"
    echo "   所有 psql 连接共享同一个索引实例"
}

show_status() {
    local mode=$(check_current_mode)
    echo "当前模式: $mode"
    echo ""
    if [ "$mode" = "direct" ]; then
        echo "┌─────────────────────────────────────────────┐"
        echo "│  直接调用模式 (DIRECT MODE)                 │"
        echo "├─────────────────────────────────────────────┤"
        echo "│  ✅ 查询延迟: ~0.5 ms                       │"
        echo "│  ✅ 无 IPC 开销                             │"
        echo "│  ❌ 仅支持单连接                            │"
        echo "│  ❌ 多连接数据不共享                        │"
        echo "└─────────────────────────────────────────────┘"
    elif [ "$mode" = "ipc" ]; then
        echo "┌─────────────────────────────────────────────┐"
        echo "│  IPC 模式 (IPC MODE)                        │"
        echo "├─────────────────────────────────────────────┤"
        echo "│  ✅ 支持多连接                              │"
        echo "│  ✅ 数据全局共享                            │"
        echo "│  ⚠️  查询延迟: ~8 ms                        │"
        echo "│  ⚠️  有 IPC 序列化开销                      │"
        echo "└─────────────────────────────────────────────┘"
    else
        echo "⚠️  无法识别当前模式，请检查 nrindex_kv.c"
    fi
}

# Main
case "${1:-}" in
    direct)
        switch_to_direct
        echo ""
        echo "请重新编译："
        echo "  cd $SCRIPT_DIR && make clean && make && sudo make install"
        ;;
    ipc)
        switch_to_ipc
        echo ""
        echo "请重新编译："
        echo "  cd $SCRIPT_DIR && make clean && make && sudo make install"
        ;;
    status)
        show_status
        ;;
    *)
        usage
        ;;
esac
