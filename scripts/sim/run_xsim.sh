#!/usr/bin/env bash
#=============================================================================
# run_xsim.sh - xsim 仿真流程（Vivado 自带仿真器，命令行版）
#-----------------------------------------------------------------------------
# 什么时候用它：
#   iverilog 不认识 Xilinx 原语（IBUFDS / MMCME2_BASE / BUFG / IDELAYE2 ...），
#   凡是例化了原语的模块，都必须用 xsim（或 Vivado GUI）。
#
# 用法：
#   bash scripts/sim/run_xsim.sh                # 跑默认 testbench 列表
#   bash scripts/sim/run_xsim.sh tb_clk_gen     # 只跑指定 testbench
#
# 说明：
#   本脚本用 xvlog / xelab / xsim 三个命令行工具，和 Vivado GUI 里的
#   "Run Behavioral Simulation" 是同一套引擎，只是没有界面。
#   比启动 Vivado 快很多。
#
# 【三个必须注意的点（踩过坑）】
#   1. xelab 要显式链接 UNISIM 库：-L unisims_ver -L secureip
#      （GUI 里是自动的，命令行不会自动）
#   2. MMCM/PLL 等原语依赖 glbl 模块，必须一起 elaborate：
#      xelab <tb> glbl ...
#   3. xsim 的 %t 按仿真精度(ps)打印，别用 $time 直接显示"ns"
#=============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

OUT="$ROOT/sim/build/xsim"
mkdir -p "$OUT"

#-----------------------------------------------------------------------------
# 定位 Vivado 的 bin 目录（可能不在 PATH 里）
#-----------------------------------------------------------------------------
XVIVADO=""
for d in "$HOME/Xilinx/Vivado/2020.2/bin" /tools/Xilinx/Vivado/*/bin; do
    [ -x "$d/xvlog" ] && { XVIVADO="$d"; break; }
done
if [ -z "$XVIVADO" ]; then
    echo "错误：找不到 xvlog/xelab/xsim。请确认 Vivado 安装路径，" >&2
    echo "      或把 \$HOME/Xilinx/Vivado/<版本>/bin 加进 PATH。" >&2
    exit 2
fi
XVLOG="$XVIVADO/xvlog"; XELAB="$XVIVADO/xelab"; XSIM="$XVIVADO/xsim"
GLBL="$XVIVADO/../data/verilog/src/glbl.v"

#-----------------------------------------------------------------------------
# 源文件清单
#-----------------------------------------------------------------------------
RTL="rtl/common/clk_gen.v \
     rtl/common/cdc_sync.v \
     rtl/common/rst_sync.v"

# 默认只跑需要原语的 TB
ALL_TB="tb_clk_gen"
WANT="${1:-all}"

pass=0; fail=0

for tb in $ALL_TB; do
    if [ "$WANT" != "all" ] && [ "$WANT" != "$tb" ]; then continue; fi
    if [ ! -f "sim/tb/${tb}.v" ]; then
        echo "  [跳过] sim/tb/${tb}.v 不存在"; continue
    fi

    echo ""
    echo ">>> xsim 仿真 $tb   (工作目录 $OUT)"
    rm -rf "$OUT/xsim.dir" "$OUT/.Xil" 2>/dev/null || true

    cd "$OUT"
    # 1) 编译
    if ! "$XVLOG" $ROOT/rtl/common/*.v $ROOT/sim/tb/${tb}.v "$GLBL" \
            > "$OUT/${tb}.xvlog.log" 2>&1; then
        echo "  [编译失败] 见 $OUT/${tb}.xvlog.log"; fail=$((fail+1)); cd "$ROOT"; continue
    fi
    # 2) 精化：必须显式带 UNISIM 库和 glbl
    if ! "$XELAB" -debug typical \
            -L unisims_ver -L secureip \
            "$tb" glbl -s "${tb}_sim" \
            > "$OUT/${tb}.xelab.log" 2>&1; then
        echo "  [精化失败] 见 $OUT/${tb}.xelab.log"; fail=$((fail+1)); cd "$ROOT"; continue
    fi
    # 3) 运行
    if "$XSIM" "${tb}_sim" -runall 2>&1 | tee "$OUT/${tb}.xsim.log" \
            | grep -vE "^\*\*|webtalk|xsim \{"; then
        pass=$((pass+1))
    else
        fail=$((fail+1))
    fi
    cd "$ROOT"
done

echo ""
echo "==================== xsim 汇总 ===================="
echo " 通过 $pass  失败 $fail   日志在 sim/build/xsim/"
[ "$fail" -eq 0 ]
