# RisingWave Iceberg Position Delete 主键重复问题 - 深度分析报告

## 问题描述

当使用 RisingWave 查询 Iceberg source（来自 MySQL 主键表通过 CDC 同步），在 Amoro 优化后出现主键重复问题：
- 优化前：查询正常，返回一条数据
- 优化后：查询返回两条数据（一条新数据，一条旧数据）
- 在 StarRocks 和 Amoro 控制台中查询正常（只有最新数据）
- 只有包含 position delete files 的表会出现此问题

## 根本原因分析

### 1. Position Delete Files 的作用

Amoro PMC 的解释：对于较大的 insert file，会维护一个 position delete file，记录已被删除的数据行位置。

Position delete file 包含：
- `file_path`: 数据文件路径
- `pos`: 被删除的行号

### 2. RisingWave 的处理缺陷

**问题代码位置**: `src/connector/src/source/iceberg/mod.rs` 第 406 行

```rust
for delete_file in task.deletes.drain(..) {
    // ... 处理 delete files
}
```

**问题**：
1. `drain()` 方法会**移除** `FileScanTask` 中的所有 delete files 信息
2. 移除后的 `task` 在第 427 行被添加到 `data_files`
3. 当这些 task 传递给 `scan_task_to_chunk` 函数时，iceberg-rust reader 收到的是**没有 delete 信息的 FileScanTask**
4. reader 无法知道哪些记录应该被过滤，返回所有数据（包括已删除的旧数据）

### 3. 失败的补偿方案

RisingWave 尝试通过 LEFT ANTI JOIN 来过滤被删除的数据：

**代码位置**: `src/frontend/src/optimizer/rule/source_to_iceberg_scan_rule.rs` 第 80-83 行

```rust
if have_position_delete {
    data_iceberg_scan = 
        build_position_delete_hashjoin_scan(source, data_iceberg_scan)?;
}
```

**为什么失败**：
1. Position delete files 和 data files 被分散到不同的 splits 中（第 438-440 行）
2. 分片算法基于文件大小的负载均衡，不保证相关的 data file 和 position delete file 在同一个 split
3. 并行处理时，LEFT ANTI JOIN 可能无法正确匹配所有应该删除的记录
4. 违反了 Iceberg 规范：delete 应该在 reader 层面就应用，而不是事后过滤

## 修复方案

### 核心修改

**文件**: `src/connector/src/source/iceberg/mod.rs`  
**行号**: 403-436

**修改前**：
```rust
for delete_file in task.deletes.drain(..) {
    // 移除 delete files，导致 task.deletes 变空
}
```

**修改后**：
```rust
for delete_file in &task.deletes {
    // 使用引用迭代，保留 delete files 在 task 中
    let delete_file = delete_file.as_ref().clone();
    // ... 为 JOIN 方案收集 delete files
}
```

### 修改原理

1. **保留 delete 信息**: 使用 `&task.deletes` 而不是 `task.deletes.drain(..)`
2. **iceberg-rust 自动处理**: reader 收到完整的 FileScanTask（包含 deletes），会自动过滤被删除的记录
3. **向后兼容**: 仍然收集 delete files 用于 JOIN，虽然现在是冗余的，但不影响正确性

### 为什么这样修复有效

1. **符合 Iceberg 规范**: Reader 在读取数据时就应用 position deletes
2. **性能更好**: Reader 可以在解码 Parquet 时跳过被删除的记录，而不需要先全部读取再过滤
3. **更可靠**: 不依赖复杂的分布式 JOIN 逻辑
4. **与其他引擎一致**: StarRocks 等引擎也是在 reader 层面处理 deletes

## 技术细节

### Iceberg 的 Delete Files 机制

Iceberg v2 支持两种 delete files：

1. **Equality Deletes**: 基于列值删除（如 `id = 123`）
2. **Position Deletes**: 基于文件路径和行号删除（如 `file_path=xxx, pos=42`）

Position deletes 更高效，因为：
- 不需要读取数据列进行比较
- 可以直接跳过指定位置的记录
- 适合 Update 操作（写入新记录 + position delete 旧记录）

### RisingWave 的处理流程

**批量查询**（用户的场景）：
1. `SourceToIcebergScanRule` 检测是否有 position deletes
2. 创建三种扫描：DataScan, EqualityDeleteScan, PositionDeleteScan
3. 通过 LEFT ANTI JOIN 过滤（**这里有问题**）

**修复后的流程**：
1. FileScanTask 保留 delete 信息
2. iceberg-rust reader 自动应用 position deletes
3. JOIN 逻辑变成冗余（但不影响正确性）

## 验证方法

### 测试场景

1. 准备 MySQL 主键表
2. 通过 CDC 同步到 Iceberg
3. 在 RisingWave 中创建 Iceberg source
4. 更新 MySQL 中的记录
5. 等待 Amoro 优化（会生成 position delete files）
6. 在 RisingWave 中查询：

```sql
SELECT 
    id, title, text,
    _iceberg_sequence_number,
    _iceberg_file_path
FROM test_iceberg_source
WHERE id = 1684971
ORDER BY _iceberg_sequence_number DESC;
```

### 预期结果

- **修复前**: 返回 2 条记录（sequence_number=153 的旧数据 + sequence_number=31413 的新数据）
- **修复后**: 返回 1 条记录（只有 sequence_number=31413 的新数据）

## 后续优化建议

### 可选：移除冗余的 Position Delete JOIN

**文件**: `src/frontend/src/optimizer/rule/source_to_iceberg_scan_rule.rs`  
**修改**: 移除第 80-83 行的 `build_position_delete_hashjoin_scan` 调用

**原因**:
- iceberg-rust reader 已经处理了 position deletes
- JOIN 逻辑是冗余的，浪费计算资源
- 简化代码，减少维护负担

**注意**: 这不是必需的，因为：
- Reader 已经过滤了被删除的记录
- JOIN 不会找到匹配项（因为记录已不存在）
- 只是性能优化，不影响正确性

### 可能需要保留的部分

Equality Delete 的 JOIN 逻辑可能仍需保留，需要确认 iceberg-rust reader 是否完全支持 equality deletes 的自动处理。

## 影响范围

### 受影响的场景

1. **Iceberg source 批量查询**: 直接受益，position deletes 正确应用
2. **Iceberg source 流式查询**: 也会受益（使用相同的 `scan_task_to_chunk` 函数）
3. **COW vs MOR 表**: 两种模式都会受益（都可能产生 position deletes）

### 不受影响的场景

1. **没有 position deletes 的表**: 行为不变
2. **Equality deletes**: 仍使用 JOIN 方案（如果 iceberg-rust 不支持自动处理）
3. **其他 connector**: 不影响

## 相关代码文件

1. **核心修复**:
   - `src/connector/src/source/iceberg/mod.rs` (第 406 行)

2. **相关逻辑**:
   - `src/frontend/src/optimizer/rule/source_to_iceberg_scan_rule.rs` (position delete JOIN)
   - `src/batch/executors/src/executor/iceberg_scan.rs` (批量查询执行器)
   - `src/stream/src/executor/source/iceberg_fetch_executor.rs` (流式查询执行器)

## 总结

这是一个**设计缺陷**，而不是简单的 bug：

1. **初始设计**: 使用 JOIN 方案处理 deletes
2. **实现问题**: 移除了 FileScanTask 的 delete 信息，导致 iceberg-rust reader 无法工作
3. **JOIN 方案缺陷**: 分片逻辑不能保证正确匹配 data files 和 delete files
4. **正确方案**: 让 iceberg-rust reader 自动处理 deletes（符合 Iceberg 规范）

修复后，RisingWave 的 Iceberg position delete 处理与 StarRocks、Amoro 等主流引擎一致。
