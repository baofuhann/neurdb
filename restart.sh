#!/bin/bash

# 重启 NeurDB 容器脚本

set -e

echo "=== 停止并删除旧容器 ==="
docker rm -f neurdb_dev 2>/dev/null || true

# echo "=== 用 root 清理并修复权限 ==="
# docker run --rm -u root \
#     -v /home/benjamin/neurdb:/code/neurdb-dev \
#     -v /tmp/neurdb-build/psql:/code/neurdb-dev/psql \
#     neurdbimg bash -c "\
#         chown -R neurdb:neurdb /code/neurdb-dev/psql && \
#         chown -R neurdb:neurdb /code/neurdb-dev/dbengine 2>/dev/null || true && \
#         chmod -R 777 /code/neurdb-dev/psql"

echo "=== 启动新容器（neurdb 用户）==="
docker run -d --name neurdb_dev \
    -v /home/benjamin/neurdb:/code/neurdb-dev \
    -v /tmp/neurdb-build/psql:/code/neurdb-dev/psql \
    -p 5432:5432 \
    -p 1234:1234 \
    --cap-add=SYS_PTRACE \
    neurdbimg \
    bash -c "sleep 2 && bash /code/neurdb-dev/docker-init.sh"

echo "=== 查看日志 (Ctrl+C 退出) ==="
docker logs -f neurdb_dev
