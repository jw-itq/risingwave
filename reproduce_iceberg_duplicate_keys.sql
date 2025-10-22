-- ============================================================
-- RisingWave Iceberg Position Delete Bug 复现脚本
-- 问题：多次更新同一主键记录后，查询返回多条重复数据
-- ============================================================

-- 1. 准备工作
SET streaming_parallelism=4;

-- 2. 创建源表
CREATE TABLE test_source (
    id INT,
    title VARCHAR,
    content TEXT,
    updated_at TIMESTAMP
);

CREATE MATERIALIZED VIEW test_mv AS SELECT * FROM test_source;

-- 3. 创建Iceberg Sink（假设使用MinIO/S3存储）
CREATE SINK test_iceberg_sink AS 
SELECT * FROM test_mv 
WITH (
    connector = 'iceberg',
    type = 'upsert',
    database.name = 'test_db',
    table.name = 'test_duplicate_keys',
    catalog.name = 'demo',
    catalog.type = 'storage',
    warehouse.path = 's3a://iceberg-warehouse/test',
    s3.endpoint = 'http://minio:9000',
    s3.region = 'us-east-1',
    s3.access.key = 'minioadmin',
    s3.secret.key = 'minioadmin',
    create_table_if_not_exists = 'true',
    commit_checkpoint_interval = 1,
    primary_key = 'id'
);

-- 4. 插入初始数据
INSERT INTO test_source VALUES 
    (1684971, '测试标题', '这是原始内容', NOW());

-- 等待数据写入Iceberg
SELECT pg_sleep(3);
FLUSH;

-- 5. 第1次更新 - 修改content字段
UPDATE test_source 
SET content = '第1次修改：更新了内容字段', 
    updated_at = NOW() 
WHERE id = 1684971;

-- 等待数据写入
SELECT pg_sleep(3);
FLUSH;

-- 6. 第2次更新 - 修改title字段
UPDATE test_source 
SET title = '第2次修改：更新了标题', 
    updated_at = NOW() 
WHERE id = 1684971;

-- 等待数据写入
SELECT pg_sleep(3);
FLUSH;

-- 7. 第3次更新 - 同时修改title和content
UPDATE test_source 
SET title = '第3次修改：标题和内容都更新',
    content = '第3次修改：这是完全不同的内容',
    updated_at = NOW() 
WHERE id = 1684971;

-- 等待数据写入
SELECT pg_sleep(3);
FLUSH;

-- 8. 第4次更新 - 再次修改
UPDATE test_source 
SET content = '第4次修改：最终版本的内容',
    updated_at = NOW() 
WHERE id = 1684971;

-- 等待数据写入和可能的Amoro优化
SELECT pg_sleep(10);
FLUSH;

-- 9. 创建Iceberg Source读取数据
CREATE SOURCE test_iceberg_source
WITH (
    connector = 'iceberg',
    s3.endpoint = 'http://minio:9000',
    s3.region = 'us-east-1',
    s3.access.key = 'minioadmin',
    s3.secret.key = 'minioadmin',
    catalog.type = 'storage',
    warehouse.path = 's3a://iceberg-warehouse/test',
    database.name = 'test_db',
    table.name = 'test_duplicate_keys'
);

-- 10. 查询验证 - 期望：只返回1条数据，实际：可能返回多条
SELECT 
    id,
    title,
    content,
    _iceberg_sequence_number,
    _iceberg_file_path
FROM test_iceberg_source
WHERE id = 1684971
ORDER BY _iceberg_sequence_number DESC;

-- 11. 统计重复记录数量
SELECT 
    id,
    COUNT(*) as duplicate_count,
    ARRAY_AGG(title ORDER BY _iceberg_sequence_number) as all_titles,
    ARRAY_AGG(_iceberg_sequence_number ORDER BY _iceberg_sequence_number) as all_sequences
FROM test_iceberg_source
WHERE id = 1684971
GROUP BY id;

-- ============================================================
-- 预期结果（Bug修复前）：
-- duplicate_count = 4 或 5（取决于更新次数和Amoro优化）
-- all_sequences = {153, 1234, 5678, 31413, ...}
--
-- 预期结果（Bug修复后）：
-- duplicate_count = 1
-- all_sequences = {31413}（最新的sequence number）
-- ============================================================

-- 清理
-- DROP SINK test_iceberg_sink;
-- DROP SOURCE test_iceberg_source;
-- DROP MATERIALIZED VIEW test_mv CASCADE;
-- DROP TABLE test_source;
