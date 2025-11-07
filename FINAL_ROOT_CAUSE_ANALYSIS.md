# RisingWave Iceberg Position Delete Bug - 最终根因分析

## 问题总结

用户报告：查询Iceberg表时返回多条主键重复的记录，数量等于更新次数+1。

## 已确认的Bug

### Bug #1: file_pos计算错误（高优先级）✅

**位置**: `src/connector/src/source/iceberg/mod.rs:734`

**问题代码**:
```rust
let index_start = (index * chunk_size) as i64;
```

**修复**:
```rust
let index_start = start_position as i64 + (index * chunk_size) as i64;
```

**影响**: 当FileScanTask.start != 0时，计算出的file_pos会偏移错误，导致anti-join无法匹配position delete记录。

**证据**: 
1. 代码中有FIXME注释明确指出这个问题
2. StarRocks和Amoro都能正确处理，说明问题在RisingWave的实现中
3. 只有包含position delete文件的表才出现问题

---

### Bug #2: Position Delete文件的列投影错误（疑似，需验证）⚠️

**位置**: `src/connector/src/source/iceberg/mod.rs:435`

**问题代码**:
```rust
delete_file.project_field_ids = Vec::default();
```

**疑问**:
1. **空的project_field_ids是什么含义？**
   - 如果表示"读取所有列"，那应该没问题
   - 如果表示"不读取任何列"或"列投影为空"，那就会导致position delete文件读不到数据

2. **Position delete文件的标准schema**:
   ```
   - file_path: string (field_id = 2147483546)
   - pos: long (field_id = 2147483545)
   ```

3. **可能的问题**:
   - 如果project_field_ids为空导致不读取任何列
   - PositionDeleteScan返回的DataChunk可能是空的或者列数不对
   - Anti-join就无法正确匹配

**需要验证**:
- 通过日志查看PositionDeleteScan返回的chunk内容
- 确认返回的列名和数据是否正确

---

### Bug #3: 列名映射问题（疑似）⚠️

**问题描述**:

Position delete文件使用Iceberg标准列名：
- `file_path` (标准名称)
- `pos` (标准名称)

但RisingWave期望的列名是：
- `_iceberg_file_path` (内部名称)
- `_iceberg_file_pos` (内部名称)

**可能的情况**:
1. **如果Iceberg SDK按列顺序返回**（不管列名）：没问题
2. **如果Iceberg SDK按列名匹配**：会导致列名不匹配，anti-join失败

**需要验证**:
- 查看PositionDeleteScan返回的列名
- 确认anti-join的列匹配逻辑

---

## 修复优先级

### 必须修复（100%确定）

✅ **Bug #1: file_pos计算错误**
- 这是明确的bug，必须修复
- 已添加修复代码和详细日志

### 需要验证后决定（50%怀疑）

⚠️ **Bug #2: project_field_ids = Vec::default()**

建议的修复方案（如果确认是bug）:
```rust
// 获取position delete文件schema的field IDs
// Position delete标准field IDs: file_path=2147483546, pos=2147483545
delete_file.project_field_ids = vec![2147483546, 2147483545];
```

或者更保守的做法，不清空project_field_ids：
```rust
// 注释掉这行，保持原有的project_field_ids
// delete_file.project_field_ids = Vec::default();
```

⚠️ **Bug #3: 列名映射**

如果确认是问题，需要在scan_task_to_chunk或其他地方添加列名映射逻辑。

---

## 验证方法

### 1. 通过日志验证

添加了详细的日志，运行后检查：

```log
[Iceberg] Executing DataScan with N files
[Iceberg] Executing PositionDeleteScan with M files
[Iceberg] scan_task_to_chunk - Reading file: xxx, sequence: X, start: Y, ...
[Iceberg] Adding file_path and file_pos: file=xxx, positions=[A, B, C]
```

关键检查点：
1. DataScan的positions是否正确（不应该全是0）
2. PositionDeleteScan是否返回了数据
3. PositionDeleteScan返回的chunk行数和列是否正确

### 2. 通过查询验证

```sql
-- 查看explain plan，确认有LEFT ANTI JOIN
EXPLAIN SELECT * FROM iceberg_source WHERE id = 1684971;

-- 查看重复数量
SELECT id, COUNT(*) FROM iceberg_source WHERE id = 1684971 GROUP BY id;

-- 查看详细数据
SELECT 
    id, 
    _iceberg_sequence_number,
    _iceberg_file_path,
    _iceberg_file_pos
FROM iceberg_source 
WHERE id = 1684971
ORDER BY _iceberg_sequence_number DESC;
```

### 3. 对比测试

在StarRocks或Amoro中执行相同的查询，对比：
- 返回的行数
- file_pos的值
- file_path的值

---

## 建议的测试步骤

1. **第一步：只应用Bug #1的修复**
   - 编译运行
   - 查看日志中的file_pos值
   - 测试是否解决问题
   - **如果解决了，说明Bug #1是唯一的问题**
   - **如果没解决，继续下一步**

2. **第二步：验证PositionDeleteScan的输出**
   - 查看日志：`grep "PositionDeleteScan" .risingwave/log/*.log`
   - 确认是否有数据返回
   - 确认列名和列数是否正确
   - **如果PositionDeleteScan没返回数据或列不对，需要修复Bug #2**

3. **第三步：验证anti-join的匹配**
   - 如果两边都有数据但join不匹配
   - 可能是Bug #3（列名问题）
   - 需要添加列名映射或调整列的读取方式

---

## 最可能的情况

基于代码分析，我认为**Bug #1是主要问题**，修复后应该能解决90%的情况。

理由：
1. 这是明确的计算错误
2. 有FIXME注释证明这是已知问题
3. 其他系统（StarRocks/Amoro）都能正确处理，说明问题不在Iceberg文件本身

Bug #2和#3可能不是问题，因为：
1. RisingWave的测试用例（iceberg_source_position_delete.slt）能通过
2. 说明基本的position delete处理逻辑是正确的
3. 但测试用例可能没有覆盖FileScanTask.start != 0的情况

---

## 下一步行动

1. ✅ 已添加Bug #1的修复和详细日志
2. ⏳ 等待用户测试反馈
3. ⏳ 根据日志输出判断是否需要修复Bug #2和#3
4. ⏳ 如果Bug #1解决了问题，清理临时日志，提交PR

EOF
cat /workspace/FINAL_ROOT_CAUSE_ANALYSIS.md
