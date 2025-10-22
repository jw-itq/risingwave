# StarRocks vs RisingWave: Iceberg Position Delete处理对比

## 核心区别

### StarRocks的实现方式 ✅

**架构**: **Native Filtering（SDK自动应用）**

```cpp
// 1. 读取position delete文件，使用Iceberg标准列名
static const IcebergColumnMeta k_delete_file_path{
    .col_name = "file_path",  // ← Iceberg标准列名
    .type = TPrimitiveType::VARCHAR
};

static const IcebergColumnMeta k_delete_file_pos{
    .col_name = "pos",  // ← Iceberg标准列名
    .type = TPrimitiveType::BIGINT
};

// 2. 构建deletion bitmap
Status IcebergDeleteBuilder::fill_skip_rowids(const ChunkPtr& chunk) const {
    const ColumnPtr& file_path = chunk->get_column_by_slot_id(k_delete_file_path.id);
    const ColumnPtr& pos = chunk->get_column_by_slot_id(k_delete_file_pos.id);
    
    for (int i = 0; i < chunk->num_rows(); i++) {
        if (file_path->get(i).get_slice() == _params.path) {
            // 直接将pos加入deletion_bitmap
            _deletion_bitmap->add_value(pos->get(i).get_int64());
        }
    }
    return Status::OK();
}

// 3. 读取数据时直接应用bitmap过滤
// 在 group_reader.cpp 中：
_skip_rows_ctx->deletion_bitmap->fill_filter(r.begin(), r.end(), chunk_filter);
// chunk_filter标记哪些行需要跳过
```

**关键特点**:
1. ✅ **使用Iceberg标准列名** (`file_path`, `pos`)
2. ✅ **SDK自动读取这些列** - 不需要手动映射
3. ✅ **使用bitmap直接过滤** - 在读取数据时立即应用，高效
4. ✅ **没有file_pos计算问题** - 直接从delete文件读取pos值

**工作流程**:
```
1. 读取position delete文件 → 获取(file_path, pos)对
                              ↓
2. 构建deletion_bitmap      → 存储所有被删除的pos
                              ↓
3. 读取data文件时           → bitmap.fill_filter()过滤被删除的行
                              ↓
4. 返回过滤后的数据          → 正确！
```

---

### RisingWave的实现方式 ❌ (修复前)

**架构**: **SQL-Level Filtering（使用LEFT ANTI JOIN）**

```rust
// 1. RisingWave使用内部列名
const ICEBERG_FILE_PATH_COLUMN_NAME: &str = "_iceberg_file_path";
const ICEBERG_FILE_POS_COLUMN_NAME: &str = "_iceberg_file_pos";

// 2. Data Scan - 计算file_pos（Bug所在）
if need_file_path_and_pos {
    // Bug: 没有加上start_position
    let index_start = (index * chunk_size) as i64;  // ❌ 错误！
    
    columns.push(file_path);
    columns.push(file_pos);  // 值全是0！
}

// 3. Position Delete Scan - 读取delete文件
// 期望读取标准的file_path和pos列
// 但是...这里有个问题

// 4. LEFT ANTI JOIN过滤
BatchHashJoin { 
    type: LeftAnti, 
    predicate: _iceberg_file_path = _iceberg_file_path 
           AND _iceberg_file_pos = _iceberg_file_pos 
}
├─ DataScan          → 返回 (file_path, pos=0)     ← Bug!
└─ PositionDeleteScan → 返回 (file_path, pos=12345)

// 匹配失败！(file_path, 0) ≠ (file_path, 12345)
```

**问题点**:
1. ❌ **file_pos计算错误** - 缺少start_position偏移
2. ⚠️ **列名可能不匹配** - 内部用`_iceberg_file_pos`，SDK返回`pos`
3. ⚠️ **project_field_ids清空** - 可能导致不读取必要的列
4. ❌ **JOIN性能开销** - 相比bitmap过滤效率低

**为什么会出现主键重复**:
```
DataScan计算:
  file: data_v1.parquet, pos: 0      ← 应该是12345
  file: data_v2.parquet, pos: 0      ← 应该是23456

PositionDeleteScan读取:
  file: data_v1.parquet, pos: 12345
  file: data_v2.parquet, pos: 23456

LEFT ANTI JOIN:
  (data_v1.parquet, 0) ≠ (data_v1.parquet, 12345)  → 不匹配，保留旧数据
  (data_v2.parquet, 0) ≠ (data_v2.parquet, 23456)  → 不匹配，保留旧数据
  
结果: 所有旧数据都被返回 → 主键重复！
```

---

### RisingWave的实现方式 ✅ (修复后)

```rust
// 修复：正确计算file_pos
let start_position = data_file_scan_task.start;
let index_start = start_position as i64 + (index * chunk_size) as i64;

// 现在file_pos是正确的：
DataScan计算:
  file: data_v1.parquet, pos: 12345   ✅ 正确！
  file: data_v2.parquet, pos: 23456   ✅ 正确！

PositionDeleteScan读取:
  file: data_v1.parquet, pos: 12345
  file: data_v2.parquet, pos: 23456

LEFT ANTI JOIN:
  (data_v1.parquet, 12345) = (data_v1.parquet, 12345)  ✅ 匹配，过滤旧数据
  (data_v2.parquet, 23456) = (data_v2.parquet, 23456)  ✅ 匹配，过滤旧数据
  
结果: 旧数据被正确过滤 → 只返回最新数据！
```

---

## 设计哲学对比

| 方面 | StarRocks | RisingWave |
|------|-----------|-----------|
| **过滤方式** | Bitmap (Native) | LEFT ANTI JOIN (SQL) |
| **依赖SDK** | 更多依赖 | 更少依赖 |
| **性能** | 高（直接过滤） | 中（JOIN开销） |
| **可扩展性** | 受限于单机 | 好（分布式JOIN） |
| **复杂度** | 低 | 高 |
| **列名处理** | 直接使用标准名 | 内部列名映射 |

**RisingWave的设计考量** (来自PMC回复):
> "RisingWave uses join to apply the delete files, our intention is to make it more scalable"

RisingWave选择了**可扩展性优先**，使用分布式JOIN而不是依赖SDK的单机过滤。这在大规模数据处理时更有优势，但需要**正确实现file_pos计算**。

---

## 为什么StarRocks没有这个Bug？

### 原因1: 不需要计算file_pos

StarRocks **直接从position delete文件读取pos值**：
```cpp
// Position delete文件的schema:
// Column 0: file_path (string)
// Column 1: pos (long)

const ColumnPtr& pos = chunk->get_column_by_slot_id(k_delete_file_pos.id);
// pos的值直接来自delete文件，不需要计算！
```

RisingWave需要**在DataScan时自己计算file_pos**：
```rust
// 读取数据文件时，需要为每行计算其在文件中的位置
let index_start = start_position + (index * chunk_size);  // 必须正确！
```

### 原因2: Bitmap过滤更简单

StarRocks的逻辑：
```
1. 读取delete文件: pos ∈ {12345, 23456, ...}
2. 构建bitmap: set.add(12345), set.add(23456), ...
3. 过滤数据: if (!bitmap.contains(current_pos)) return row;
```

RisingWave的逻辑（更复杂）：
```
1. 读取delete文件: (file_path, pos)
2. 读取数据文件: (file_path, computed_pos)  ← 计算可能出错
3. JOIN匹配: WHERE data.pos = delete.pos      ← 依赖计算正确
```

### 原因3: SDK处理差异

StarRocks可能更多地依赖Iceberg SDK的默认行为：
- SDK自动解析position delete文件的标准schema
- 列名直接使用Iceberg规范 (`file_path`, `pos`)
- 不需要额外的列名映射

RisingWave实现了更多自定义逻辑：
- 使用内部列名 (`_iceberg_file_path`, `_iceberg_file_pos`)
- 手动计算file_pos
- 需要确保计算逻辑正确

---

## 结论

### StarRocks为什么正确？

✅ **使用Iceberg标准列名** - SDK自动处理
✅ **直接读取pos值** - 不需要计算
✅ **Bitmap过滤** - 简单高效
✅ **不依赖file_pos计算** - 避免了RisingWave的bug

### RisingWave的Bug根因

❌ **file_pos计算错误** - `start_position`被遗漏
⚠️ **更复杂的架构** - SQL层JOIN增加了出错机会
⚠️ **列名映射问题** - 可能存在额外风险

### 我的修复为什么有效？

✅ **修复了核心计算错误** - 加上`start_position`
✅ **使JOIN能正确匹配** - file_pos值现在正确了
✅ **不改变架构** - 保持RisingWave的分布式JOIN优势
✅ **添加了详细日志** - 便于验证和调试

---

## 给RisingWave团队的建议

### 短期（已实现）:
1. ✅ 修复file_pos计算
2. ✅ 添加详细日志
3. ⏳ 增强测试用例

### 长期考虑:
1. **考虑混合方案**: 小文件用bitmap，大文件用JOIN
2. **优化列名映射**: 统一使用Iceberg标准列名
3. **Profile对比**: 测量JOIN vs Bitmap的性能差异
4. **文档化权衡**: 说明为什么选择JOIN而不是SDK过滤

### 测试增强:
- 测试`FileScanTask.start != 0`的情况
- 测试Amoro优化后的文件
- 测试大文件分片扫描
- 对比StarRocks的性能和正确性
