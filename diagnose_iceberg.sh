#!/bin/bash
# RisingWave Iceberg 问题诊断脚本

echo "=========================================="
echo "RisingWave Iceberg 诊断工具"
echo "=========================================="
echo ""

# 检查日志目录
if [ ! -d ".risingwave/log" ]; then
    echo "错误: 找不到日志目录 .risingwave/log"
    echo "请确保在RisingWave workspace目录运行此脚本"
    exit 1
fi

echo "1️⃣  检查Scan类型执行情况..."
echo "-------------------------------------------"
SCAN_LOGS=$(grep "Executing.*Scan" .risingwave/log/*.log 2>/dev/null | grep Iceberg | tail -10)
if [ -z "$SCAN_LOGS" ]; then
    echo "⚠️  警告: 没有找到Scan执行日志"
    echo "   可能原因: 1) 没有执行查询 2) 日志级别不够 3) 修复未编译"
else
    echo "$SCAN_LOGS"
fi
echo ""

echo "2️⃣  检查文件读取情况（关键：start值）..."
echo "-------------------------------------------"
READ_LOGS=$(grep "scan_task_to_chunk - Reading file" .risingwave/log/*.log 2>/dev/null | tail -5)
if [ -z "$READ_LOGS" ]; then
    echo "⚠️  警告: 没有找到文件读取日志"
    echo "   说明: 修复可能没有生效，或者没有执行查询"
else
    echo "$READ_LOGS"
    echo ""
    echo "👉 重点查看: 'start:' 后面的数字"
    echo "   - 如果全是0，说明可能不是start_position的问题"
    echo "   - 如果有非0值，说明修复已生效"
fi
echo ""

echo "3️⃣  检查file_pos计算情况..."
echo "-------------------------------------------"
POS_LOGS=$(grep "Adding file_path and file_pos" .risingwave/log/*.log 2>/dev/null | tail -5)
if [ -z "$POS_LOGS" ]; then
    echo "⚠️  警告: 没有找到file_pos计算日志"
else
    echo "$POS_LOGS"
    echo ""
    echo "👉 重点查看: 'positions=' 后面的数组"
    echo "   - 如果是 [0, 1023]，说明修复未生效"
    echo "   - 如果是其他值（如 [8192, 9215]），说明修复生效"
fi
echo ""

echo "4️⃣  检查Position Delete文件..."
echo "-------------------------------------------"
DELETE_LOGS=$(grep -i "position.*delete\|Delete file.*Position" .risingwave/log/*.log 2>/dev/null | tail -10)
if [ -z "$DELETE_LOGS" ]; then
    echo "⚠️  警告: 没有找到Position Delete相关日志"
    echo "   可能原因: 1) 表没有position delete文件 2) delete文件未被识别"
else
    echo "$DELETE_LOGS"
fi
echo ""

echo "5️⃣  统计日志中的关键信息..."
echo "-------------------------------------------"
TOTAL_ICEBERG=$(grep -c "\[Iceberg\]" .risingwave/log/*.log 2>/dev/null || echo "0")
echo "总共 [Iceberg] 日志条数: $TOTAL_ICEBERG"

if [ "$TOTAL_ICEBERG" -eq 0 ]; then
    echo ""
    echo "❌ 严重问题: 完全没有 [Iceberg] 日志！"
    echo ""
    echo "可能原因："
    echo "  1. 修复的代码没有被编译"
    echo "  2. 日志级别设置太高"
    echo "  3. 查询没有实际执行"
    echo ""
    echo "解决方法："
    echo "  1. 重新编译: ./risedev b"
    echo "  2. 设置日志级别: export RUST_LOG=info"
    echo "  3. 重启RisingWave: ./risedev k && ./risedev d"
    echo "  4. 重新执行查询"
fi
echo ""

echo "6️⃣  检查编译状态..."
echo "-------------------------------------------"
if [ -f "target/debug/risingwave" ]; then
    COMPILE_TIME=$(stat -c %y target/debug/risingwave 2>/dev/null || stat -f "%Sm" target/debug/risingwave 2>/dev/null || echo "未知")
    echo "编译时间: $COMPILE_TIME"
    
    # 检查修复的代码是否在二进制中
    if strings target/debug/risingwave 2>/dev/null | grep -q "scan_task_to_chunk - Reading file"; then
        echo "✅ 修复的日志代码已编译进二进制文件"
    else
        echo "⚠️  警告: 无法确认修复是否编译进去"
    fi
else
    echo "⚠️  未找到编译的二进制文件"
    echo "   请运行: ./risedev b"
fi
echo ""

echo "=========================================="
echo "诊断完成"
echo "=========================================="
echo ""
echo "📋 下一步建议："
echo ""

if [ "$TOTAL_ICEBERG" -eq 0 ]; then
    echo "  ❗ 优先级1: 修复编译或日志问题"
    echo "     1. export RUST_LOG=info"
    echo "     2. ./risedev b"
    echo "     3. ./risedev k && ./risedev d"
    echo "     4. 重新执行查询"
    echo "     5. 再次运行此诊断脚本"
else
    echo "  ✅ 已有日志，请将以下内容发给我："
    echo ""
    echo "     grep \"\\[Iceberg\\]\" .risingwave/log/*.log | tail -100 > iceberg_debug.log"
    echo "     cat iceberg_debug.log"
    echo ""
    echo "  同时提供你的查询结果，以便深入分析"
fi
echo ""
