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
IVFLAGS="-g2005 -Wall -Wno-timescale -I rtl/common -I rtl/audio"
TBEXTRA="sim/tb/codec_model.v"
RTL="rtl/common/cdc_sync.v rtl/common/rst_sync.v rtl/audio/i2s_clkgen.v \
     rtl/audio/i2s_rx.v rtl/audio/i2s_tx.v rtl/audio/audio_fifo.v \
     rtl/audio/eq_cascade.v rtl/audio/eq_coeff_rom.v rtl/audio/audio_top.v"

ALL_TB="eq_cascade i2s_loopback audio_top"
WANT="${1:-all}"

pass=0
fail=0
skip=0

echo "iverilog : $IVERILOG"
echo "           $IV_VERSION"

for tb in $ALL_TB; do
    if [ "$WANT" != "all" ] && [ "$WANT" != "$tb" ]; then continue; fi
    if [ ! -f "sim/tb/tb_${tb}.v" ]; then
        echo "  [跳过] sim/tb/tb_${tb}.v 不存在"
        skip=$((skip + 1))
        continue
    fi

    echo ""
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
    if ( cd "$ROOT" && "$VVP" $VVP_LIBFLAGS "$OUT/tb_${tb}.vvp" $VVPARG ); then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
    fi
done

echo ""
echo "==================== 仿真汇总 ===================="
echo " 通过 $pass  失败 $fail  跳过 $skip"
[ "$fail" -eq 0 ]
