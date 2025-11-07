# 🚀 超简单的日志收集方法

## 方法1：使用诊断脚本（最简单，推荐）

```bash
# 在RisingWave workspace目录下运行
cd /workspace
./diagnose_iceberg.sh
```

这个脚本会自动检查所有关键信息并给出建议。

---

## 方法2：三条命令快速收集（如果脚本不工作）

```bash
# 1. 查看是否有Iceberg日志
grep "\[Iceberg\]" .risingwave/log/*.log | wc -l

# 2. 查看最近的Iceberg日志
grep "\[Iceberg\]" .risingwave/log/*.log | tail -50

# 3. 保存到文件
grep "\[Iceberg\]" .risingwave/log/*.log > /tmp/iceberg_logs.txt
cat /tmp/iceberg_logs.txt
```

---

## 方法3：一行命令（最快）

```bash
grep "\[Iceberg\]" .risingwave/log/*.log | tail -100
```

复制输出结果发给我。

---

## 如果完全没有日志

说明修复可能没有编译进去，请执行：

```bash
# 1. 重新编译
./risedev b

# 2. 重启RisingWave
./risedev k
./risedev d

# 3. 等待启动
sleep 10

# 4. 重新执行查询
./risedev psql -c "SELECT id, _iceberg_sequence_number FROM test_iceberg_source WHERE id = 1684971;"

# 5. 查看日志
grep "\[Iceberg\]" .risingwave/log/*.log | tail -50
```

---

## 我最需要看到的信息

### 关键信息1：start_position的值
```
查找内容: "start:"
示例: scan_task_to_chunk - Reading file: xxx.parquet, start: 8192
            这个数字是关键 ↑
```

### 关键信息2：file_pos的值  
```
查找内容: "positions="
示例: Adding file_path and file_pos: ..., positions=[8192, 9215]
                                      这个数组是关键 ↑
```

### 关键信息3：PositionDeleteScan是否执行
```
查找内容: "PositionDeleteScan"
示例: Executing PositionDeleteScan with 2 files
                               这个数字 ↑ 应该 > 0
```

---

## 快速检查清单

- [ ] 编译完成了吗？（./risedev b）
- [ ] RisingWave重启了吗？（./risedev k && ./risedev d）
- [ ] 查询执行了吗？
- [ ] 能看到 `[Iceberg]` 日志吗？
- [ ] 如果能，请把日志发给我

---

## 示例：正常的日志应该是什么样

```log
[INFO risingwave_batch_executors] [Iceberg] Executing DataScan with 2 files
[INFO risingwave_batch_executors] [Iceberg] Executing PositionDeleteScan with 1 files
[INFO risingwave_connector::source::iceberg] [Iceberg] scan_task_to_chunk - Reading file: s3://bucket/data.parquet, sequence: 31413, start: 0, length: 12345, deletes_count: 0
[DEBUG risingwave_connector::source::iceberg] [Iceberg] Adding file_path and file_pos: file=s3://bucket/data.parquet, batch_index=0, positions=[0, 1023]
```

如果你看到类似的日志，请全部发给我！

---

## 现在请执行：

**选择下面任一方法：**

### 最简单的方法：
```bash
cd /workspace
./diagnose_iceberg.sh
```

### 或者手动收集：
```bash
grep "\[Iceberg\]" .risingwave/log/*.log | tail -100
```

**把输出的所有内容复制发给我！** 📋
