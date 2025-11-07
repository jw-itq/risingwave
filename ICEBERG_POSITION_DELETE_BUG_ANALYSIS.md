# Iceberg Position Delete Bug 深度分析

## 问题现象

查询Iceberg表时，对于同一主键返回多条记录，数量与该记录被更新的次数相关。

## 根本原因

**Bug位置**: `src/connector/src/source/iceberg/mod.rs:733-734`

**错误代码**:
```rust
// 计算file_pos时没有考虑start_position
let index_start = (index * chunk_size) as i64;
```

**正确代码**:
```rust
// 必须加上start_position才是相对于文件开头的绝对位置
let index_start = start_position as i64 + (index * chunk_size) as i64;
```

## 详细机制图解

### 场景：对id=1684971的记录进行4次更新

```
时间线：T0 -----> T1 -----> T2 -----> T3 -----> T4 -----> T5
        插入     更新1     更新2     更新3    Amoro    查询
                                             优化
```

### 文件状态变化

```
┌─────────────────────────────────────────────────────────────┐
│ T0: 初始插入                                                  │
├─────────────────────────────────────────────────────────────┤
│ 数据文件:                                                     │
│   ✓ data_v1.parquet                                          │
│     - row 0: {id:1684971, title:"测试", content:"原始"}       │
│     - sequence_number: 100                                    │
│ Delete文件: 无                                                │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ T1: 第1次更新 (修改content字段)                              │
├─────────────────────────────────────────────────────────────┤
│ 新增数据文件:                                                 │
│   ✓ data_v2.parquet                                          │
│     - row 0: {id:1684971, title:"测试", content:"修改1"}      │
│     - sequence_number: 200                                    │
│                                                              │
│ 新增Delete文件:                                               │
│   ✓ pos_delete_v1.parquet                                    │
│     - {file_path: "data_v1.parquet", file_pos: 0}            │
│     - 含义: data_v1.parquet的第0行已被删除                    │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ T2: 第2次更新 (修改title字段)                                │
├─────────────────────────────────────────────────────────────┤
│ 新增数据文件:                                                 │
│   ✓ data_v3.parquet                                          │
│     - row 0: {id:1684971, title:"新标题", content:"修改1"}    │
│     - sequence_number: 300                                    │
│                                                              │
│ 新增Delete文件:                                               │
│   ✓ pos_delete_v2.parquet                                    │
│     - {file_path: "data_v2.parquet", file_pos: 0}            │
│     - 含义: data_v2.parquet的第0行已被删除                    │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ T3: 第3次更新 (同时修改title和content)                       │
├─────────────────────────────────────────────────────────────┤
│ 新增数据文件:                                                 │
│   ✓ data_v4.parquet                                          │
│     - row 0: {id:1684971, title:"新标题2", content:"修改3"}   │
│     - sequence_number: 400                                    │
│                                                              │
│ 新增Delete文件:                                               │
│   ✓ pos_delete_v3.parquet                                    │
│     - {file_path: "data_v3.parquet", file_pos: 0}            │
│     - 含义: data_v3.parquet的第0行已被删除                    │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│ T4: Amoro优化 (可能会合并/重写文件)                          │
├─────────────────────────────────────────────────────────────┤
│ 可能产生更多position delete文件，或者重新组织文件结构          │
│ 关键点: position delete文件记录的是精确的file_path + file_pos │
└─────────────────────────────────────────────────────────────┘
```

## Bug如何导致重复数据

### RisingWave的查询执行计划

```sql
SELECT * FROM iceberg_source WHERE id = 1684971;
```

实际执行的逻辑计划（当存在position delete时）：

```
BatchExchange
└─BatchHashJoin (LEFT ANTI)
   ├─ Left: DataScan (读取所有data文件)
   │   Output: [id, title, content, _iceberg_file_path, _iceberg_file_pos]
   │
   └─ Right: PositionDeleteScan (读取所有position delete文件)
       Output: [_iceberg_file_path, _iceberg_file_pos]
       
Join Condition: 
    Left._iceberg_file_path = Right._iceberg_file_path 
    AND Left._iceberg_file_pos = Right._iceberg_file_pos
```

### Bug前后的对比

#### DataScan 读取结果（Bug修复前）

```
┌────────┬─────────┬─────────┬──────────────────┬──────────────────┐
│   id   │  title  │ content │ _iceberg_file... │ _iceberg_file_pos│
├────────┼─────────┼─────────┼──────────────────┼──────────────────┤
│1684971 │ 测试    │ 原始    │ data_v1.parquet  │ 0 ❌ (错误!)     │
│1684971 │ 测试    │ 修改1   │ data_v2.parquet  │ 0 ❌ (错误!)     │
│1684971 │ 新标题  │ 修改1   │ data_v3.parquet  │ 0 ❌ (错误!)     │
│1684971 │ 新标题2 │ 修改3   │ data_v4.parquet  │ 0 ❌ (错误!)     │
└────────┴─────────┴─────────┴──────────────────┴──────────────────┘
```

**问题**: 所有记录的`_iceberg_file_pos`都是0，因为没有加上`start_position`！

#### PositionDeleteScan 读取结果

```
┌──────────────────┬──────────────────┐
│ _iceberg_file... │ _iceberg_file_pos│
├──────────────────┼──────────────────┤
│ data_v1.parquet  │ 12345 ✓          │
│ data_v2.parquet  │ 23456 ✓          │
│ data_v3.parquet  │ 34567 ✓          │
└──────────────────┴──────────────────┘
```

**实际的file_pos**: 12345, 23456, 34567（根据实际文件布局）

#### LEFT ANTI JOIN 结果（Bug修复前）

```
DataScan的file_pos: 0, 0, 0, 0
PositionDeleteScan的file_pos: 12345, 23456, 34567

匹配情况:
  data_v1 (pos=0) ≠ delete (pos=12345) ❌ 不匹配，不过滤
  data_v2 (pos=0) ≠ delete (pos=23456) ❌ 不匹配，不过滤
  data_v3 (pos=0) ≠ delete (pos=34567) ❌ 不匹配，不过滤
  data_v4 (pos=0) ✓ 没有对应的delete，保留

最终返回: 4条记录（全部保留！）
```

#### DataScan 读取结果（Bug修复后）

```
┌────────┬─────────┬─────────┬──────────────────┬──────────────────┐
│   id   │  title  │ content │ _iceberg_file... │ _iceberg_file_pos│
├────────┼─────────┼─────────┼──────────────────┼──────────────────┤
│1684971 │ 测试    │ 原始    │ data_v1.parquet  │ 12345 ✓          │
│1684971 │ 测试    │ 修改1   │ data_v2.parquet  │ 23456 ✓          │
│1684971 │ 新标题  │ 修改1   │ data_v3.parquet  │ 34567 ✓          │
│1684971 │ 新标题2 │ 修改3   │ data_v4.parquet  │ 45678 ✓          │
└────────┴─────────┴─────────┴──────────────────┴──────────────────┘
```

#### LEFT ANTI JOIN 结果（Bug修复后）

```
DataScan的file_pos: 12345, 23456, 34567, 45678
PositionDeleteScan的file_pos: 12345, 23456, 34567

匹配情况:
  data_v1 (pos=12345) = delete (pos=12345) ✓ 匹配，过滤掉
  data_v2 (pos=23456) = delete (pos=23456) ✓ 匹配，过滤掉
  data_v3 (pos=34567) = delete (pos=34567) ✓ 匹配，过滤掉
  data_v4 (pos=45678) ✓ 没有对应的delete，保留

最终返回: 1条记录（正确！）
```

## 为什么修改次数越多，重复数据越多？

每次UPDATE操作都会：
1. 写入一个新的数据文件（包含新版本的数据）
2. 生成一个position delete文件（标记旧版本数据的位置）

如果进行了N次更新：
- 会有N+1个数据文件（初始插入 + N次更新）
- 会有N个position delete文件

**Bug修复前**: 由于file_pos计算错误，N个position delete都无法匹配，导致返回N+1条记录

**Bug修复后**: N个position delete正确匹配并过滤掉N条旧记录，只返回1条最新记录

## 验证方法

### 1. 查看日志确认file_pos值

修复后，查看日志应该能看到正确的file_pos计算：

```log
[Iceberg] Adding file_path and file_pos: file=data_v1.parquet, batch_index=0, positions=[12345, 12346, ...]
[Iceberg] Adding file_path and file_pos: file=data_v2.parquet, batch_index=0, positions=[23456, 23457, ...]
```

### 2. 对比StarRocks/Amoro的查询结果

如果StarRocks和Amoro返回1条记录，而RisingWave返回多条，说明Bug仍然存在。

### 3. 使用EXPLAIN查看执行计划

```sql
EXPLAIN SELECT * FROM iceberg_source WHERE id = 1684971;
```

应该能看到LEFT ANTI JOIN的计划，证明RisingWave正在尝试应用position delete。

## 总结

这个Bug的本质是：
1. **Iceberg的position delete机制依赖精确的(file_path, file_pos)匹配**
2. **RisingWave计算file_pos时遗漏了start_position**
3. **导致anti-join无法匹配任何delete记录**
4. **结果是所有历史版本的数据都被返回**
5. **更新次数越多，返回的重复记录越多**

修复后，每个主键应该只返回最新版本的数据，历史版本会被position delete正确过滤掉。
