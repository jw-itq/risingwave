#!/bin/bash
# ============================================================
# Iceberg Position Delete Bug 验证脚本
# ============================================================

set -e

echo "=========================================="
echo "1. 启动RisingWave (如果还没启动)"
echo "=========================================="
# ./risedev d

echo ""
echo "=========================================="
echo "2. 创建测试表和Sink"
echo "=========================================="
./risedev psql -c "
DROP SINK IF EXISTS test_iceberg_sink CASCADE;
DROP SOURCE IF EXISTS test_iceberg_source;
DROP MATERIALIZED VIEW IF EXISTS test_mv CASCADE;
DROP TABLE IF EXISTS test_updates CASCADE;

CREATE TABLE test_updates (
    id INT,
    field1 VARCHAR,
    field2 VARCHAR,
    field3 VARCHAR,
    updated_at TIMESTAMP
);

CREATE MATERIALIZED VIEW test_mv AS SELECT * FROM test_updates;

-- 根据你的实际Iceberg配置调整连接参数
CREATE SINK test_iceberg_sink AS 
SELECT * FROM test_mv 
WITH (
    connector = 'iceberg',
    type = 'upsert',
    database.name = 'demo_db',
    table.name = 'test_position_delete_bug',
    catalog.name = 'demo',
    catalog.type = 'storage',
    warehouse.path = 's3a://your-bucket/iceberg',
    s3.endpoint = 'http://your-endpoint:9000',
    s3.region = 'us-east-1',
    s3.access.key = 'your-access-key',
    s3.secret.key = 'your-secret-key',
    create_table_if_not_exists = 'true',
    commit_checkpoint_interval = 1,
    primary_key = 'id'
);
"

echo ""
echo "=========================================="
echo "3. 插入初始数据"
echo "=========================================="
./risedev psql -c "
INSERT INTO test_updates VALUES 
    (1001, '初始值1', '初始值2', '初始值3', NOW());
FLUSH;
"
sleep 3

echo ""
echo "=========================================="
echo "4. 执行多次更新操作"
echo "=========================================="
echo "第1次更新..."
./risedev psql -c "
UPDATE test_updates 
SET field1 = '更新1次', updated_at = NOW() 
WHERE id = 1001;
FLUSH;
"
sleep 3

echo "第2次更新..."
./risedev psql -c "
UPDATE test_updates 
SET field2 = '更新2次', updated_at = NOW() 
WHERE id = 1001;
FLUSH;
"
sleep 3

echo "第3次更新..."
./risedev psql -c "
UPDATE test_updates 
SET field1 = '更新3次-字段1', field3 = '更新3次-字段3', updated_at = NOW() 
WHERE id = 1001;
FLUSH;
"
sleep 3

echo "第4次更新..."
./risedev psql -c "
UPDATE test_updates 
SET field1 = '更新4次-字段1', field2 = '更新4次-字段2', updated_at = NOW() 
WHERE id = 1001;
FLUSH;
"
sleep 3

echo "第5次更新..."
./risedev psql -c "
UPDATE test_updates 
SET field3 = '最终版本-字段3', updated_at = NOW() 
WHERE id = 1001;
FLUSH;
"

echo ""
echo "等待数据写入和可能的Amoro优化..."
sleep 10

echo ""
echo "=========================================="
echo "5. 创建Iceberg Source并查询"
echo "=========================================="
./risedev psql -c "
CREATE SOURCE test_iceberg_source
WITH (
    connector = 'iceberg',
    s3.endpoint = 'http://your-endpoint:9000',
    s3.region = 'us-east-1',
    s3.access.key = 'your-access-key',
    s3.secret.key = 'your-secret-key',
    catalog.type = 'storage',
    warehouse.path = 's3a://your-bucket/iceberg',
    database.name = 'demo_db',
    table.name = 'test_position_delete_bug'
);
"

echo ""
echo "=========================================="
echo "6. 查询结果"
echo "=========================================="
echo ""
echo "--- 查询所有版本（预期Bug修复前：6条，Bug修复后：1条）---"
./risedev psql -c "
SELECT 
    id,
    field1,
    field2,
    field3,
    _iceberg_sequence_number,
    _iceberg_file_path
FROM test_iceberg_source
WHERE id = 1001
ORDER BY _iceberg_sequence_number DESC;
"

echo ""
echo "--- 统计重复数量 ---"
./risedev psql -c "
SELECT 
    id,
    COUNT(*) as record_count,
    MIN(_iceberg_sequence_number) as min_seq,
    MAX(_iceberg_sequence_number) as max_seq
FROM test_iceberg_source
WHERE id = 1001
GROUP BY id;
"

echo ""
echo "=========================================="
echo "7. 检查日志"
echo "=========================================="
echo ""
echo "查看最近的Iceberg日志（查找file_pos计算）："
echo "tail -100 .risingwave/log/*.log | grep -E '\[Iceberg\].*file_pos'"
echo ""
echo "如果看到类似这样的日志，说明修复生效："
echo "[Iceberg] Adding file_path and file_pos: file=xxx.parquet, batch_index=0, positions=[12345, 12346]"
echo ""
echo "=========================================="
echo "测试完成！"
echo "=========================================="
echo ""
echo "预期结果："
echo "- Bug修复前: record_count = 6 (或更多)"
echo "- Bug修复后: record_count = 1"
echo ""
