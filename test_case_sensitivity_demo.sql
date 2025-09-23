-- RisingWave字段名大小写处理测试

-- 方案1: 使用双引号创建包含大写字母的字段
CREATE TABLE test_table_quoted (
    id INT,
    "Name" VARCHAR(50),
    "AGE" INT,
    "MixedCase" VARCHAR(50)
);

-- 插入测试数据
INSERT INTO test_table_quoted VALUES (1, 'Alice', 25, 'test1');
INSERT INTO test_table_quoted VALUES (2, 'Bob', 30, 'test2');

-- 查询时必须使用双引号
SELECT id, "Name", "AGE", "MixedCase" FROM test_table_quoted;

-- 不使用双引号会报错
-- SELECT id, Name, AGE, MixedCase FROM test_table_quoted; -- 这会报错

-- 方案2: 使用小写字段名（推荐）
CREATE TABLE test_table_lower (
    id INT,
    name VARCHAR(50),
    age INT,
    mixed_case VARCHAR(50)
);

-- 插入测试数据
INSERT INTO test_table_lower VALUES (1, 'Alice', 25, 'test1');
INSERT INTO test_table_lower VALUES (2, 'Bob', 30, 'test2');

-- 查询时可以使用任意大小写
SELECT id, name, age, mixed_case FROM test_table_lower;
SELECT ID, NAME, AGE, MIXED_CASE FROM test_table_lower; -- 这个也会工作
SELECT Id, Name, Age, Mixed_Case FROM test_table_lower; -- 这个也会工作

-- 清理
DROP TABLE test_table_quoted;
DROP TABLE test_table_lower;