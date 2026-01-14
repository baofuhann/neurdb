# pgbench 测试pg的性能的全流程

## 准备初始数据集

cd /hdd9/benjamin/SOSD/scripts/data

  # 转换全部 800M 数据（注意：数据类型是 uint64）
  python sosd_to_pg.py osm_cellids_800M_uint64 --output osm_800M.csv -t uint64 -l 800000000

  # 或者只转换部分数据（如 1000 万条）
  python sosd_to_pg.py osm_cellids_800M_uint64 --output osm_10M.csv -t uint64 -l 10000000
  
## 