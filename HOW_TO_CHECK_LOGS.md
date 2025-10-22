# 如何查看和收集RisingWave Iceberg日志

## 1. 快速查看最近的Iceberg日志

```bash
# 查看最近500行包含[Iceberg]的日志
tail -500 .risingwave/log/*.log | grep "\[Iceberg\]"

# 或者查看所有Iceberg日志（可能很多）
grep "\[Iceberg\]" .risingwave/log/*.log

# 实时监控新的Iceberg日志
tail -f .risingwave/log/*.log | grep "\[Iceberg\]"
```

## 2. 查看特定类型的日志

### 2.1 查看文件扫描日志（最重要）
```bash
# 查看DataScan和PositionDeleteScan的执行情况
grep "Executing.*Scan" .risingwave/log/*.log | grep Iceberg

# 查看文件读取日志（start_position是关键）
grep "scan_task_to_chunk - Reading file" .risingwave/log/*.log

# 查看file_pos计算日志
grep "Adding file_path and file_pos" .risingwave/log/*.log
```

### 2.2 查看delete文件处理日志
```bash
# 查看发现的delete文件
grep "Delete file:" .risingwave/log/*.log

# 查看position delete文件处理
grep "Position delete file" .risingwave/log/*.log

# 查看project_field_ids警告
grep "project_field_ids before clear" .risingwave/log/*.log
```

## 3. 收集完整日志信息

### 方式1：保存到文件（推荐）
```bash
# 收集所有Iceberg相关日志到文件
grep "\[Iceberg\]" .risingwave/log/*.log > iceberg_debug.log

# 查看文件
cat iceberg_debug.log

# 复制内容发给我
```

### 方式2：按时间顺序查看
```bash
# 查看最近的日志（带时间戳）
grep "\[Iceberg\]" .risingwave/log/*.log | tail -100
```

## 4. 关键信息检查清单

在查看日志时，请重点关注以下信息：

### ✅ 必须检查的信息

1. **DataScan执行了吗？**
   ```
   查找: "[Iceberg] Executing DataScan with X files"
   预期: 应该看到这一行，X > 0
   ```

2. **PositionDeleteScan执行了吗？**
   ```
   查找: "[Iceberg] Executing PositionDeleteScan with X files"
   预期: 应该看到这一行，X > 0（如果有position delete文件）
   ```

3. **start_position的值是什么？**
   ```
   查找: "scan_task_to_chunk - Reading file: ..., start: XXX"
   预期: start值不应该全是0
   关键: 如果start都是0，说明不是Bug #1的问题
   ```

4. **file_pos的值是什么？**
   ```
   查找: "Adding file_path and file_pos: ..., positions=[X, Y]"
   预期: positions不应该全是[0, 1023]
   关键: 如果是[0, 1023]说明修复没生效
   ```

5. **发现了delete文件吗？**
   ```
   查找: "Delete file: path=..., content_type=PositionDeletes"
   预期: 应该看到delete文件被发现
   ```

## 5. 针对你的查询的具体日志收集

```bash
# 1. 确保RisingWave正在运行
./risedev d

# 2. 清空旧日志（可选，但推荐）
rm .risingwave/log/*.log

# 3. 重启RisingWave以获得干净的日志
./risedev k
./risedev d

# 等待启动完成
sleep 10

# 4. 执行你的查询
./risedev psql -c "
SELECT 
    id,
    title,
    _iceberg_sequence_number,
    _iceberg_file_path,
    _iceberg_file_pos
FROM test_iceberg_source
WHERE id = 1684971
ORDER BY _iceberg_sequence_number DESC;
"

# 5. 立即收集日志
grep "\[Iceberg\]" .risingwave/log/*.log > iceberg_full_debug.log

# 6. 查看日志
cat iceberg_full_debug.log
```

## 6. 如果日志文件很大

```bash
# 只看最重要的部分
grep "\[Iceberg\]" .risingwave/log/*.log | grep -E "Executing|Reading file|Adding file_path|Delete file" > iceberg_key_info.log

cat iceberg_key_info.log
```

## 7. 发给我的日志格式

请提供以下三部分：

### Part 1: Scan执行情况
```bash
grep "Executing.*Scan" .risingwave/log/*.log | grep Iceberg
```

### Part 2: 文件读取详情
```bash
grep -E "scan_task_to_chunk|Adding file_path" .risingwave/log/*.log | head -50
```

### Part 3: Delete文件信息
```bash
grep "Delete file\|position_delete" .risingwave/log/*.log -i | head -30
```

## 8. 如果看不到\[Iceberg\]日志

可能是日志级别不够，尝试：

```bash
# 设置日志级别为info
export RUST_LOG=info

# 或者更详细
export RUST_LOG=risingwave_connector::source::iceberg=debug,risingwave_batch_executors=debug

# 重启RisingWave
./risedev k
./risedev d
```

## 9. 检查EXPLAIN计划

```bash
# 查看查询执行计划
./risedev psql -c "
EXPLAIN SELECT * FROM test_iceberg_source WHERE id = 1684971;
"
```

预期应该看到类似：
```
BatchHashJoin { type: LeftAnti, ... }
├─ BatchIcebergScan { iceberg_scan_type: DataScan }
└─ BatchIcebergScan { iceberg_scan_type: PositionDeleteScan }
```

## 10. 快速诊断脚本

创建并运行这个脚本：

```bash
cat > /tmp/diagnose_iceberg.sh << 'EOF'
#!/bin/bash
echo "=========================================="
echo "RisingWave Iceberg 诊断脚本"
echo "=========================================="

echo ""
echo "1. 检查Scan执行情况..."
grep "Executing.*Scan" .risingwave/log/*.log | grep Iceberg | tail -10

echo ""
echo "2. 检查文件读取（start_position）..."
grep "scan_task_to_chunk - Reading file" .risingwave/log/*.log | tail -5

echo ""
echo "3. 检查file_pos计算..."
grep "Adding file_path and file_pos" .risingwave/log/*.log | tail -5

echo ""
echo "4. 检查delete文件..."
grep "Delete file:" .risingwave/log/*.log | tail -10

echo ""
echo "5. 检查position delete..."
grep -i "position.*delete" .risingwave/log/*.log | tail -10

echo ""
echo "=========================================="
echo "诊断完成"
echo "=========================================="
EOF

chmod +x /tmp/diagnose_iceberg.sh
/tmp/diagnose_iceberg.sh
```

---

## 现在请执行：

```bash
# 执行诊断脚本
bash /tmp/diagnose_iceberg.sh

# 或者手动收集关键日志
grep "\[Iceberg\]" .risingwave/log/*.log | tail -100
```

**请把输出结果完整地发给我！**
