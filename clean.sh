#!/bin/bash

# 清理所有 root 创建的文件

set -e

echo "=== 彻底清理 root 创建的文件 ==="

docker run --rm -u root \
    -v /home/benjamin/neurdb:/code/neurdb-dev \
    -v /tmp/neurdb-build/psql:/code/neurdb-dev/psql \
    neurdbimg bash -c "\
        echo '=== 修复权限 ===' && \
        chown -R neurdb:neurdb /code/neurdb-dev && \
        chmod -R 755 /code/neurdb-dev && \
        echo '=== 清理编译产物 ===' && \
        cd /code/neurdb-dev/dbengine && \
        rm -rf config.log config.cache config.status GNUmakefile && \
        find . -name '*.o' -delete 2>/dev/null || true && \
        find . -name '*.so' -delete 2>/dev/null || true && \
        find . -name '*.a' -delete 2>/dev/null || true && \
        rm -rf /code/neurdb-dev/psql/* && \
        rm -f /code/neurdb-dev/logfile && \
        rm -f /code/neurdb-dev/dbengine/logfile && \
        echo '=== 清理完成 ==='"

echo "=== 清理完成，可以运行 ./build.sh --cpu ==="
