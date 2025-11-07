# 快速验证清单

## 修改的文件

✅ `src/connector/src/source/iceberg/mod.rs`
✅ `src/batch/executors/src/executor/iceberg_scan.rs`

## 核心修复

### Bug #1: file_pos计算错误
```rust
// 修复前
let index_start = (index * chunk_size) as i64;

// 修复后
let index_start = start_position as i64 + (index * chunk_size) as i64;
```

## 验证命令

### 1. 编译测试
```bash
cd /workspace
./risedev b
```

### 2. 启动RisingWave
```bash
./risedev d
```

### 3. 运行查询测试
```bash
./risedev psql -c "
SELECT 
    id,
    COUNT(*) as count,
    MIN(_iceberg_sequence_number) as min_seq,
    MAX(_iceberg_sequence_number) as max_seq,
    STRING_AGG(_iceberg_file_pos::text, ',' ORDER BY _iceberg_sequence_number) as all_positions
FROM test_iceberg_source
WHERE id = 1684971
GROUP BY id;
"
```

### 4. 查看日志
```bash
# 查看最近的Iceberg日志
tail -500 .risingwave/log/*.log | grep "\[Iceberg\]"

# 重点查找这些关键字：
# - "scan_task_to_chunk - Reading file" - 应该看到start和positions
# - "Adding file_path and file_pos" - 应该看到positions不全是0
# - "Executing PositionDeleteScan" - 应该看到delete文件被处理
```

## 预期结果

### 修复前
- `count` = 多条（等于更新次数+1）
- `all_positions` = "0,0,0,..." （全是0）

### 修复后
- `count` = 1
- `all_positions` = "12345" 或其他非零值

## 如果出现问题

### 问题1：编译失败
- 检查Rust版本
- 检查依赖是否完整
- 提供完整的错误信息

### 问题2：仍然有重复数据
- 查看日志中start_position的值
- 查看positions的值
- 确认PositionDeleteScan是否执行
- 提供完整的日志输出

### 问题3：日志中看不到\[Iceberg\]
- 确认日志级别设置
- 尝试：`export RUST_LOG=info`
- 重启RisingWave

## 需要提供的信息（如果修复不work）

1. **查询结果截图**
2. **完整的日志输出**（grep "\[Iceberg\]" 的结果）
3. **EXPLAIN计划**
   ```sql
   EXPLAIN SELECT * FROM test_iceberg_source WHERE id = 1684971;
   ```
4. **表的更新历史**（更新了几次，每次更新了什么字段）

---

## 关键日志标记

✅ **好的日志**:
```
[Iceberg] scan_task_to_chunk - Reading file: xxx, start: 8192, ...
[Iceberg] Adding file_path and file_pos: positions=[8192, 9215]
[Iceberg] Executing PositionDeleteScan with 2 files
```

❌ **坏的日志**:
```
[Iceberg] scan_task_to_chunk - Reading file: xxx, start: 0, ...
[Iceberg] Adding file_path and file_pos: positions=[0, 1023]
[Iceberg] Executing PositionDeleteScan with 0 files
```

如果看到"坏的日志"，说明：
- start都是0：可能不是Bug #1的问题
- PositionDeleteScan返回0文件：可能是Bug #2的问题
