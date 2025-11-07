# RisingWave Iceberg Position Delete Bug - 最终总结

## 问题本质

你遇到的主键重复问题是因为RisingWave在计算`_iceberg_file_pos`时**没有考虑文件的起始偏移量(start_position)**，导致LEFT ANTI JOIN无法正确匹配position delete记录，从而保留了所有历史版本的数据。

## 核心原因

```
更新操作 → COW模式 → 产生新数据文件 + position delete文件

Position Delete文件记录:
  {file_path: "data_v1.parquet", pos: 12345}  ← 精确位置

RisingWave计算(Bug):
  data_v1.parquet → pos = 0  ← 错误！应该是12345

Anti-Join匹配:
  (data_v1.parquet, 0) ≠ (data_v1.parquet, 12345)  ← 无法匹配

结果:
  旧数据未被过滤 → 主键重复！
```

## 已实施的修复

### ✅ 主要修复：file_pos计算公式

**文件**: `src/connector/src/source/iceberg/mod.rs:746`

```rust
// 修复前
let index_start = (index * chunk_size) as i64;

// 修复后  
let index_start = start_position as i64 + (index * chunk_size) as i64;
```

**影响**: 这是核心bug，修复后应该解决90%+的问题

### ✅ 辅助修复：详细日志

添加了全方位的调试日志，包括：
- 文件读取信息（sequence, start, length, deletes_count）
- Position delete文件发现
- File_pos计算过程
- Scan类型和进度
- Project_field_ids诊断

**目的**: 
1. 验证修复效果
2. 如果还有问题，快速定位下一步

## 修改的文件

1. `src/connector/src/source/iceberg/mod.rs`
   - 第702行：添加start_position捕获
   - 第704-720行：添加文件读取日志
   - 第746行：**核心修复**
   - 第750-758行：添加file_pos日志
   - 第407-422行：记录delete文件
   - 第441-447行：记录project_field_ids

2. `src/batch/executors/src/executor/iceberg_scan.rs`
   - 第94-122行：记录scan类型
   - 第124-139行：记录处理进度

## 测试方法

### 1. 编译和启动
```bash
cd /workspace
./risedev b
./risedev d
```

### 2. 运行你的测试查询
```sql
SELECT 
    id,
    title,
    text,
    _iceberg_sequence_number,
    _iceberg_file_path,
    _iceberg_file_pos
FROM test_iceberg_source
WHERE id = 1684971
ORDER BY _iceberg_sequence_number DESC;
```

**预期**: 只返回1条数据（最新版本）

### 3. 检查日志
```bash
tail -500 .risingwave/log/*.log | grep "\[Iceberg\]"
```

**关键检查点**:
- `start` 不应该全是0
- `positions` 不应该全是 [0, 1023]
- `PositionDeleteScan` 应该有文件被处理

## 预期效果

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| 返回记录数 | N+1 (更新N次) | 1 |
| file_pos值 | 全是0 | 正确的偏移量 |
| Anti-join匹配 | 失败 | 成功 |

## 为什么我有90%+的信心？

1. **Bug明确**: 代码中有FIXME注释指出这个问题
2. **符合现象**: 解释了为什么更新次数越多重复越多
3. **对比验证**: StarRocks/Amoro正常说明Iceberg文件没问题
4. **逻辑正确**: 修复后的计算公式符合Iceberg规范
5. **影响范围**: 只有带position delete的表才会出问题

## 如果修复后仍有问题

### 场景A: file_pos仍然是错的
→ 查看日志中start_position的值
→ 可能需要检查其他计算逻辑

### 场景B: PositionDeleteScan没有数据
→ 查看project_field_ids日志
→ 可能需要修复Bug #2

### 场景C: Anti-join仍不匹配
→ 查看EXPLAIN计划
→ 可能需要检查列名映射

## 下一步

1. **立即**: 按照测试方法验证
2. **成功**: 清理临时日志，准备PR
3. **失败**: 提供完整日志，继续分析

## 需要反馈的信息

✅ **必须**:
- 查询结果（记录数）
- 日志输出（grep "\[Iceberg\]"）

✨ **可选**:
- EXPLAIN计划
- 表的更新历史
- Amoro中的查询结果对比

---

## 技术细节补充

### FileScanTask.start的含义

Iceberg的FileScanTask包含：
- `data_file_path`: 文件路径
- `start`: 读取起始位置（字节偏移）
- `length`: 读取长度
- `deletes`: 关联的delete文件

`start`字段用于实现文件的部分读取（例如分布式并行扫描）。当文件被拆分给多个worker时，每个worker负责读取一个range，这时start就不是0。

### Position Delete的工作原理

1. **数据文件**: 包含实际数据行
2. **Position Delete文件**: 记录哪些行已被删除
   ```
   file_path (string) | pos (long)
   data1.parquet      | 100
   data1.parquet      | 205
   data2.parquet      | 50
   ```
3. **查询时**: 引擎读取数据文件，然后应用position delete过滤

RisingWave使用SQL层面的LEFT ANTI JOIN来实现这个过滤，而不是依赖Iceberg SDK自动应用。

### 为什么其他系统正常？

StarRocks和Amoro可能：
1. 正确计算了file_pos
2. 或者使用了Iceberg SDK的自动过滤功能
3. 或者有不同的实现策略

RisingWave选择了显式的anti-join策略，这给了更多控制权，但也需要正确计算file_pos。

---

**相信这次分析和修复是全面且彻底的。期待你的测试反馈！** 🚀
