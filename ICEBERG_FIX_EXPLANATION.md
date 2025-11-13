# Iceberg Position Delete 主键重复问题修复说明

## 问题根源

在 `src/connector/src/source/iceberg/mod.rs` 第406行，RisingWave 使用 `task.deletes.drain(..)` 将 FileScanTask 中的所有 delete files 信息移除。这导致：

1. iceberg-rust reader 收到的 FileScanTask 没有 delete 信息
2. reader 无法知道哪些记录应该被 position delete 过滤
3. 返回所有数据，包括已删除的旧记录

虽然 RisingWave 尝试通过 LEFT ANTI JOIN 来过滤（在 source_to_iceberg_scan_rule.rs 中），但由于以下原因这个方案不可靠：

1. Position delete files 和 data files 被分散到不同的 splits 中
2. 并行处理时可能无法正确匹配所有应该删除的记录
3. Iceberg 规范要求 reader 在读取时就应用 deletes，而不是事后过滤

## 修复方案

### 方案 1：让 iceberg-rust reader 自动处理 position deletes（推荐）

修改 `src/connector/src/source/iceberg/mod.rs` 第403-436行，将 `task.deletes.drain(..)` 改为迭代引用 `&task.deletes`，这样 delete 信息会保留在 data file task 中。

**优点：**
- 符合 Iceberg 规范
- 性能更好（reader 可以在解码时就跳过被删除的记录）
- 更可靠（不依赖复杂的 JOIN 逻辑）

**缺点：**
- 当前的 position delete JOIN 逻辑变成冗余（但不会影响正确性）

### 方案 2：修复 position delete JOIN 的分片逻辑（复杂）

如果不使用 iceberg-rust 的自动过滤，需要确保每个 data file split 都能访问到相关的 position delete files。这需要重新设计分片算法，使得：

1. Position delete files 根据它们引用的 data files 进行分组
2. 每个 split 包含完整的 data file 及其对应的 position delete files

**优点：**
- 保持当前的架构

**缺点：**
- 实现复杂
- 性能较差（需要扫描 position delete files 并执行 JOIN）
- 不符合 Iceberg 最佳实践

## 推荐的修复代码

已在主代码中应用，关键改动是将 `drain()` 改为引用迭代，保留 FileScanTask 中的 delete 信息。

## 验证方法

1. 构建修复后的 RisingWave
2. 使用 MySQL -> Iceberg -> RisingWave source 的场景
3. 在 MySQL 中更新记录，等待 Amoro 优化（生成 position delete files）
4. 在 RisingWave 中查询，确认只返回最新记录，没有重复

## 补充说明

如果后续需要清理冗余的 position delete JOIN 逻辑，可以修改 `src/frontend/src/optimizer/rule/source_to_iceberg_scan_rule.rs`：

1. 移除 `build_position_delete_hashjoin_scan` 的调用（第80-83行）
2. 保留 equality delete 的 JOIN 逻辑（如果 iceberg-rust 不支持 equality delete 的自动处理）

但这不是必需的，因为：
- iceberg-rust reader 会先过滤掉被删除的记录
- JOIN 不会找到匹配项（因为记录已经被过滤）
- 只是浪费一些计算资源，但不影响正确性
