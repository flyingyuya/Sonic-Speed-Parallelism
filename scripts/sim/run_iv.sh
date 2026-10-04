#!/usr/bin/env bash
#=============================================================================
# run_iv.sh - iverilog 快速仿真流程（秒级迭代，日常开发用这个）
#-----------------------------------------------------------------------------
# 用法：
#   bash scripts/sim/run_iv.sh              # 跑全部 testbench
#   bash scripts/sim/run_iv.sh eq_cascade   # 只跑指定 testbench
#   WAVE=1 bash scripts/sim/run_iv.sh       # 额外生成 VCD 波形（很大，默认关）
#   bash scripts/sim/run_iv.sh tools        # 只打印工具版本和路径，不跑仿真
#
# 注意：
#   1) 必须在仓库根目录执行（testbench 里用的是相对路径）
#   2) 脚本会自己搜索 iverilog/vvp 的位置，不依赖你的 PATH ——
#      因为很多机器上 iverilog 是"绿色解包"安装（如 ~/.local/opt/iverilog），
#      不在默认 PATH 里。详见 docs/07-toolchain-and-workflow.md
#=============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

OUT="$ROOT/sim/build"
mkdir -p "$OUT"

#-----------------------------------------------------------------------------
# 工具定位：先查 PATH，再按常见位置兜底
#   顺序有意为之 —— 包装脚本（~/.local/bin）排在裸二进制前面，
#   因为包装脚本里带了解包安装需要的 -B / -M 运行库路径。
#-----------------------------------------------------------------------------
locate_tool() {
    local name="$1"; shift
    local p
    if p="$(command -v "$name" 2>/dev/null)"; then printf '%s\n' "$p"; return 0; fi
    for p in "$@"; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

IVERILOG="$(locate_tool iverilog \
        "$HOME/.local/bin/iverilog" \
        "$HOME/.local/opt/iverilog/usr/bin/iverilog" \
        /usr/local/bin/iverilog /usr/bin/iverilog /opt/iverilog/bin/iverilog)" || {
    cat >&2 <<'ERR'
=========================================================
错误：找不到 iverilog
---------------------------------------------------------
安装方式（Arch Linux，官方 extra 源）：
    sudo pacman -S iverilog

如果已经装在 ~/.local/bin 但不在 PATH 里，把下面这行加到 ~/.bashrc：
    export PATH="$HOME/.local/bin:$PATH"
=========================================================
ERR
    exit 2
}

VVP="$(locate_tool vvp \
        "$HOME/.local/bin/vvp" \
        "$HOME/.local/opt/iverilog/usr/bin/vvp" \
        /usr/local/bin/vvp /usr/bin/vvp /opt/iverilog/bin/vvp)" || {
    echo "错误：找不到 vvp（应与 iverilog 一起安装）" >&2
    exit 2
}

# 绿色解包安装：可执行文件不在系统 bin 目录，需显式指定运行时库(ivl)位置
IVERILOG_LIBFLAGS=""
VVP_LIBFLAGS=""
case "$IVERILOG" in
    */opt/iverilog/usr/bin/iverilog)
        _pfx="${IVERILOG%/bin/iverilog}"
        IVERILOG_LIBFLAGS="-B $_pfx/lib/ivl"
        VVP_LIBFLAGS="-M $_pfx/lib/ivl"
        ;;
esac

# 注意：set -o pipefail 下 `iverilog -V | head -1` 会因 SIGPIPE 判定为失败，
# 所以这里临时关掉 pipefail，避免把 "(版本获取失败)" 拼到版本号后面。
IV_VERSION="$( set +o pipefail; "$IVERILOG" -V 2>&1 | head -n 1 )"

#-----------------------------------------------------------------------------
# tools 子命令：只报告环境，不跑仿真
#-----------------------------------------------------------------------------
if [ "${1:-}" = "tools" ]; then
    echo "========================================================="
    echo " 仿真工具链"
    echo "========================================================="
    echo " iverilog : $IVERILOG"
    echo "            $IV_VERSION"
    echo " vvp      : $VVP"
    echo " 库路径   : ${IVERILOG_LIBFLAGS:-（使用默认路径）}"
    echo
    echo " 当前 shell 的 PATH 是否含 iverilog 所在目录："
    case ":$PATH:" in
        *":$(dirname "$IVERILOG"):"*) echo "   是" ;;
        *) echo "   否  <- 所以你直接敲 iverilog 会 command not found，"
           echo "          但本脚本仍然能跑（脚本自己找）。" ;;
    esac
    echo "========================================================="
    exit 0
fi

#-----------------------------------------------------------------------------
# 源文件清单
#-----------------------------------------------------------------------------
IVFLAGS="-g2005 -Wall -Wno-timescale -I rtl/common -I rtl/audio -I rtl/video"
TBEXTRA="sim/tb/codec_model.v"
RTL="rtl/fft/fft_addr_gen.v rtl/fft/fft_twiddle_rom.v rtl/fft/fft_butterfly.v rtl/fft/fft_core.v \
     rtl/common/cdc_sync.v rtl/common/rst_sync.v rtl/common/audio_fifo.v \
     rtl/common/async_fifo.v rtl/common/key_debounce.v \
     rtl/control/ui_ctrl.v \
     rtl/control/uart_rx.v rtl/control/uart_tx.v rtl/control/cmd_proc.v \
     rtl/audio/i2s_clkgen.v rtl/audio/i2s_rx.v rtl/audio/i2s_tx.v \
     rtl/audio/i2s_slave_clk.v \
     rtl/audio/eq_cascade.v rtl/audio/eq_coeff_rom.v rtl/audio/audio_top.v \
     rtl/audio/spectrum.v rtl/audio/spectrum_map.v \
     rtl/wm8960/WM8960_init.v rtl/wm8960/WM8960_init_table.v \
     rtl/wm8960/i2c_control.v rtl/wm8960/i2c_bit_shift.v \
     rtl/video/lcd_timing.v rtl/video/spec_sync.v rtl/video/bg_src.v \
     rtl/video/disp_mix.v rtl/video/disp_top.v rtl/video/rainbow_rom.v \
     rtl/video/polar_map.v rtl/video/wave_buf.v rtl/video/demo_src.v \
     rtl/video/ui_anim.v rtl/video/font_rom.v rtl/video/text_buf.v \
     rtl/video/status_line.v"

ALL_TB="eq_cascade i2s_loopback audio_top fft_addr_gen fft_butterfly fft_core wm8960_init lcd_timing spectrum disp_top i2s_slave polar_map wave_buf ui_ctrl uart_cmd demo_src ui_anim font_rom text_buf status_line"
WANT="${1:-all}"

pass=0
fail=0
skip=0

#-----------------------------------------------------------------------------
# 半路挂掉时也要说清楚【挂在哪一步】
#-----------------------------------------------------------------------------
# 本脚本开头是 `set -euo pipefail` —— 任何一条命令非零退出都会【立刻中止】。
# 好处是不带病往下跑，坏处是：一旦中途挂了，末尾那段"仿真汇总"根本不执行，
# 于是日志里只剩一堆输出，看不出是哪一步的问题（CI 上尤其难受）。
#
# 所以这里注册一个 EXIT trap：只在非零退出时打印"最后进入的步骤"。
# 每进入一个阶段就更新 CUR_STEP，日志末尾就总能对上号。
#-----------------------------------------------------------------------------
CUR_STEP="(启动阶段：探测工具链)"
FINISHED=0            # 全部测试跑完置 1；用来区分"跑完了"和"半路挂了"
trap 'rc=$?; if [ "$rc" -ne 0 ]; then
  if [ "$FINISHED" -eq 1 ]; then
    # 正常跑完，只是有测试失败 —— 上面已经打印过失败清单，不用再喊
    echo "（全部测试已跑完，见上方的失败清单）"
  else
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo " 提前中止（退出码 $rc）"
    echo " 最后进入的步骤：$CUR_STEP"
    echo ""
    echo " set -euo pipefail 下【未被捕获的】命令失败会立刻中止，"
    echo " 所以后面的测试和末尾的汇总都没跑到。"
    echo " 详细日志在 sim/build/ 下（*.log / *.run.log）。"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
  fi
fi; true' EXIT

#-----------------------------------------------------------------------------
# Verilator 静态检查（比 iverilog 严，专门补它的盲区）
#-----------------------------------------------------------------------------
# 【为什么需要它】
#   iverilog 会**默默接受多重驱动** —— 连 -Wall 都不报（实测）。Verible 也不报。
#   而综合器会直接报 [Synth 8-6859] multi-driven net 并让 opt_design 失败。
#   结果就是：本脚本报"21/21 PASS"，设计却根本综合不过去。
#   真实案例见 docs/08-skills-index.md 第 52 条。
#
#   Verilator 的 MULTIDRIVENPROC 正好堵这个洞，另外还能抓组合环
#   (UNOPTFLAT)、意外锁存器 (LATCH) 等等 —— 都是"仿真看不出来、
#   只有综合器会报"的那一类。
#
# 【为什么关掉一批警告】
#   下面 -Wno- 关掉的全是【风格类】，不是正确性问题：
#     WIDTHEXPAND / WIDTHTRUNC  位宽隐式扩展/截断。本工程大量
#                               `(a << 3) + b` 这类写法，行为是明确的
#                               （无符号补零 / 有意截断），全部都经过逐位对拍。
#     UNUSEDSIGNAL / UNUSEDPARAM 调试口、预留口、上游没用的输出。
#     PINCONNECTEMPTY           `.dbg_xxx()` 这种刻意留空的端口连接。
#     SYNCASYNCNET              rst_sync 的"异步置位、同步释放"就是【故意】
#                               同时有同步和异步用法，这是它存在的意义。
#     PROCASSINIT               xilinx_stub.v 的初值 + always #延时，
#                               那是仿真模型，不是综合目标。
#     DECLFILENAME / VARHIDDEN / TIMESCALEMOD  命名/文件风格。
#   关掉它们不是"藏警告"，是"这类检查的前提在本工程不成立"
#   —— 判据同 docs/07「零警告该怎么做到」那一节。
#
# 【如果这个检查报了错，先去读提示的位置，不要先关规则】
#-----------------------------------------------------------------------------
# 【为什么用"白名单过滤"而不是一串 -Wno-】
#   不同 Verilator 版本的【警告名集合不一样】。传一个该版本不认识的名字，
#   verilator 会直接 "Unknown warning specified" **报错退出** —— 不是设计有问题，
#   而是命令行不兼容。本地是 5.052，CI 上跑的是 Ubuntu 仓库的版本，就撞了这条。
#
#   所以改成：照常跑 -Wall，把输出全部收下来，再按【类别白名单】过滤。
#   白名单里是预期内的风格类警告；白名单【之外】的任何警告都算失败。
#   这样和版本无关，也不依赖任何 -Wno- 名字。
#
# ⚠️ VL_ALLOW 必须写成【单行】：下面的 case 是 " $VL_ALLOW " 里找 " $c "，
#    带换行的话行首/行尾的类名永远匹配不上。
VL_ALLOW="WIDTHEXPAND WIDTHTRUNC UNUSEDSIGNAL UNUSEDPARAM PROCASSINIT DECLFILENAME VARHIDDEN SYNCASYNCNET TIMESCALEMOD PINCONNECTEMPTY"

# 只保留【版本无关】的选项：-Wall 开全部检查，-Wno-fatal 让退出码只反映真 Error
VLFLAGS="--lint-only -Wall -Wno-fatal +incdir+rtl/video +incdir+rtl/common"

run_verilator_lint() {
    echo ""
    CUR_STEP="Verilator 静态检查"
    echo ">>> Verilator 静态检查（补 iverilog 的盲区：多重驱动 / 组合环 / 锁存器）"
    if ! command -v verilator >/dev/null 2>&1; then
        echo "  [跳过] 没装 verilator  ->  sudo pacman -S verilator"
        echo "         装了之后这项能抓住 multi-driven net 这类"
        echo "         iverilog 不报、但综合器会直接失败的错。"
        skip=$((skip + 1))
        return
    fi

    echo "  版本: $(verilator --version 2>/dev/null | head -1)"

    # shellcheck disable=SC2086
    verilator $VLFLAGS --top-module top \
        sim/tb/xilinx_stub.v $(ls rtl/*.v rtl/*/*.v) \
        > "$OUT/verilator.log" 2>&1
    vl_rc=$?

    # --- ① 真正的 Error（命令行不兼容、语法错误…）直接失败 ---
    n_err=$(grep -cE "^%Error" "$OUT/verilator.log" || true)
    if [ "${n_err:-0}" -gt 0 ] || [ "$vl_rc" -ne 0 ]; then
        fail=$((fail + 1))
        echo "  [失败] verilator 返回 $vl_rc，有 $n_err 条 Error："
        grep -E "^%Error" "$OUT/verilator.log" | head -10
        return
    fi

    # --- ② 白名单之外的警告才算真问题 ---
    cats=$(grep -oE "^%Warning-[A-Z0-9_]+" "$OUT/verilator.log" 2>/dev/null \
           | sed 's/^%Warning-//' | sort -u | tr '\n' ' ' || true)
    bad=""
    for c in $cats; do
        case " $VL_ALLOW " in
            *" $c "*) ;;
            *) bad="$bad $c" ;;
        esac
    done

    n_warn=$(grep -cE "^%Warning" "$OUT/verilator.log" || true)
    if [ -n "$bad" ]; then
        fail=$((fail + 1))
        echo "  [有警告] 白名单之外：$bad"
        echo "  （共 $n_warn 条，完整输出见 $OUT/verilator.log）"
        for c in $bad; do
            grep -A3 "^%Warning-$c" "$OUT/verilator.log" | head -8
        done
    else
        pass=$((pass + 1))
        echo "  0 个意外警告（共 $n_warn 条，类别全部在白名单内：$cats）"
    fi
}

#-----------------------------------------------------------------------------
# 异步 FIFO：单个 testbench，但要用 4 组不同的时钟比跑
#   -P 是 iverilog 的【编译期】参数，所以每组都要重新编译一次
#   4 组覆盖：写远慢于读 / 写远快于读 / 接近同速（非整数比） / 极端失衡
#-----------------------------------------------------------------------------
ASYNC_SCEN="写慢读快_3M→48M:WPER=25.0,RPER=2.0,WR_PCT=80,RD_PCT=90 \
            写快读慢_48M→12.5M:WPER=7.4,RPER=28.0,WR_PCT=85,RD_PCT=60 \
            接近同速_非整数比:WPER=7.3,RPER=11.7,WR_PCT=70,RD_PCT=70 \
            极端失衡_1比10:WPER=3.0,RPER=31.0,WR_PCT=95,RD_PCT=80"

run_async_fifo() {
    local scen name params flags
    for scen in $ASYNC_SCEN; do
        name="${scen%%:*}"
        params="${scen#*:}"
        flags=""
        local kv
        for kv in ${params//,/ }; do
            flags="$flags -Ptb_async_fifo.${kv}"
        done
        echo ""
        CUR_STEP="async_fifo [$name]"
        echo ">>> 仿真 async_fifo  [$name]"
        # shellcheck disable=SC2086
        if "$IVERILOG" $IVERILOG_LIBFLAGS $IVFLAGS $flags \
                -o "$OUT/tb_async_fifo.vvp" \
                $RTL $TBEXTRA "sim/tb/tb_async_fifo.v" 2>"$OUT/async_fifo.log"; then
            :
        else
            echo "  [编译失败]"; cat "$OUT/async_fifo.log"; fail=$((fail + 1)); continue
        fi
        grep -i "warning" "$OUT/async_fifo.log" | head -20 || true
        # ⚠️ 不能只看 vvp 的退出码 —— $finish 永远返回 0，
        #    必须检查输出里的 PASS/FAIL 文本。这个坑曾经让一个失败的
        #    testbench 被统计成"通过"。
        if ( cd "$ROOT" && "$VVP" $VVP_LIBFLAGS "$OUT/tb_async_fifo.vvp" +novcd ) \
                | tee "$OUT/async_fifo.run.log" | grep -q "\*\*\* PASS"; then
            pass=$((pass + 1))
        else
            echo "  [测试失败]"; grep -E "\[ERR\]|FAIL" "$OUT/async_fifo.run.log" | head -10
            fail=$((fail + 1))
        fi
    done
}

#-----------------------------------------------------------------------------
# 整机冒烟：需要 Xilinx 原语的行为模型（iverilog 没有 unisims），
#   而且要跑约 30 ms 仿真时间（上电 1 ms + I2C + 2 帧 FFT + 3 帧显示），
#   所以单独处理，默认也跑（它是唯一验证"模块之间接对了"的测试）。
#-----------------------------------------------------------------------------
run_top_smoke() {
    echo ""
    CUR_STEP="top 整机冒烟"
    echo ">>> 仿真 top（整机冒烟，约需 1~2 分钟）"
    if "$IVERILOG" $IVERILOG_LIBFLAGS $IVFLAGS -s tb_top \
            -o "$OUT/tb_top.vvp" \
            sim/tb/xilinx_stub.v \
            $(ls rtl/*.v rtl/*/*.v 2>/dev/null) \
            "sim/tb/tb_top.v" 2>"$OUT/top.log"; then
        :
    else
        echo "  [编译失败]"; cat "$OUT/top.log"; fail=$((fail + 1)); return
    fi
    grep -i "warning" "$OUT/top.log" | head -20 || true
    if ( cd "$ROOT" && "$VVP" $VVP_LIBFLAGS "$OUT/tb_top.vvp" +novcd ) \
            | tee "$OUT/top.run.log" | grep -q "\*\*\* PASS"; then
        pass=$((pass + 1))
    else
        echo "  [测试失败]"; grep -E "\[ERR\]|FAIL" "$OUT/top.run.log" | head -10
        fail=$((fail + 1))
    fi
}

echo "iverilog : $IVERILOG"
echo "           $IV_VERSION"

run_verilator_lint

if [ "$WANT" = "all" ] || [ "$WANT" = "async_fifo" ]; then
    run_async_fifo
fi

if [ "$WANT" = "all" ] || [ "$WANT" = "top" ]; then
    run_top_smoke
fi

for tb in $ALL_TB; do
    if [ "$WANT" != "all" ] && [ "$WANT" != "$tb" ]; then continue; fi
    if [ ! -f "sim/tb/tb_${tb}.v" ]; then
        echo "  [跳过] sim/tb/tb_${tb}.v 不存在"
        skip=$((skip + 1))
        continue
    fi

    echo ""
    CUR_STEP="TB: $tb"
    echo ">>> 仿真 $tb"
    if "$IVERILOG" $IVERILOG_LIBFLAGS $IVFLAGS -o "$OUT/tb_${tb}.vvp" \
            $RTL $TBEXTRA "sim/tb/tb_${tb}.v" 2>"$OUT/${tb}.log"; then
        :
    else
        echo "  [编译失败]"; cat "$OUT/${tb}.log"; fail=$((fail + 1)); continue
    fi
    grep -i "warning" "$OUT/${tb}.log" | head -20 || true

    # 默认加 +novcd 关波形；WAVE=1 时不加，波形落在 sim/build/ 下
    if [ -n "${WAVE:-}" ]; then VVPARG=""; else VVPARG="+novcd"; fi
    # 同上：必须检查输出文本，不能只看退出码
    if ( cd "$ROOT" && "$VVP" $VVP_LIBFLAGS "$OUT/tb_${tb}.vvp" $VVPARG ) \
            | tee "$OUT/${tb}.run.log" | grep -q "\*\*\* PASS"; then
        pass=$((pass + 1))
    else
        echo "  [测试失败]"; grep -E "\[ERR\]|FAIL" "$OUT/${tb}.run.log" | head -10
        fail=$((fail + 1))
    fi
done

echo ""
FINISHED=1
echo "==================== 仿真汇总 ===================="
echo " 通过 $pass  失败 $fail  跳过 $skip"
[ "$fail" -eq 0 ]
