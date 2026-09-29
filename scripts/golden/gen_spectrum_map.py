#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_spectrum_map.py —— 生成频谱柱的「bin 分组表」

背景：
    fft_core 每次输出 512 个频点（index 0..511，bin k 的频率 = k x fs/N）。
    显示上要合成几十根柱子，分组方式直接决定观感。

为什么不能纯对数分组：
    512 个 bin 分 32 根柱，平均每柱 16 个 bin。
    纯对数的话前几根柱只覆盖 1 个 bin 甚至 0 个 —— 会看到一根根空柱子。
    （低频段 bin 密，高频段 bin 疏，这是 FFT 的天然特性）

本工程采用【混合分组】：
    · 低频 8 根柱：每根 1 个 bin（线性）—— 低频信息量大，给它最好的分辨率
    · 高频 24 根柱：从 bin 8 到 bin 512 对数分组，每 4 根柱频率翻一倍
      start(8 + j) = round(2^(3 + j/4))    j = 0..24

    这样高频段恰好是「每个八度 4 根柱」，和音乐上的听感一致。

输出：
    rtl/audio/spectrum_map.v     —— 32 项的「本柱最后一个 bin 编号」ROM
    标准输出                      —— 文档用的频率对照表
"""
import os, sys, math

NBARS   = 60      # 柱数。与屏幕宽度的关系见下：
                  #   480 px / 60 根 = 每根正好 8 px -> bar_idx = x[8:3]，零运算
                  #   原则：柱数要能让 480/N 落成 2 的幂，否则算下标要做除法。
NLINEAR = 16      # 低频线性段的柱数（柱 0..NLINEAR-1 各覆盖 1 个 bin）
                  #   占 16/60 ≈ 27%，与 30 根时（8/30）同比例，
                  #   低频段覆盖到 bin 15 ≈ 703 Hz
NBINS   = 512
FS      = 48000.0

# =============================================================================
# 计算每根柱的 bin 起点
# =============================================================================
def build_starts():
    """返回 NBARS+1 个「本柱第一个 bin 编号」，最后一项固定为 NBINS。"""
    st = [0] * (NBARS + 1)
    # ---- 低频线性段：柱 0..NLINEAR-1 各覆盖 1 个 bin ----
    for i in range(NLINEAR + 1):
        st[i] = i                      # st[0..NLINEAR] = 0,1,...,NLINEAR
    # ---- 高频对数段：bin NLINEAR -> NBINS，均分到 (NBARS - NLINEAR) 根柱 ----
    nlog = NBARS - NLINEAR
    lo, hi = math.log2(NLINEAR), math.log2(NBINS)      # 例如 3.0 -> 9.0
    for j in range(1, nlog + 1):
        st[NLINEAR + j] = int(round(2.0 ** (lo + (hi - lo) * j / nlog)))
    st[NBARS] = NBINS                  # 收尾
    # 保证严格递增（四舍五入可能撞车）
    for i in range(1, NBARS + 1):
        if st[i] <= st[i - 1]:
            st[i] = st[i - 1] + 1
    return st


def main():
    st = build_starts()
    assert st[NBARS] == NBINS, f"末位应为 {NBINS}，实得 {st[NBARS]}"
    assert len(st) == NBARS + 1

    AW = max(1, (NBARS - 1).bit_length())     # 柱编号位宽
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')

    # -------------------------------------------------------------------------
    # 生成 Verilog ROM：bar_last[i] = 第 i 根柱的最后一个 bin 编号
    # -------------------------------------------------------------------------
    L = []
    A = L.append
    A("//=============================================================================")
    A("// spectrum_map.v - 频谱柱的 bin 分组表（bar -> 本柱最后一个 bin 编号）")
    A("//-----------------------------------------------------------------------------")
    A("// ⚠️ 由 scripts/golden/gen_spectrum_map.py 自动生成，请勿手工修改。")
    A("//")
    A("// 分组方式：")
    A(f"//   柱 0..{NLINEAR-1:<2}    : bin 0..{NLINEAR-1}        （线性，每柱 1 个 bin）")
    A(f"//   柱 {NLINEAR}..{NBARS-1:<2}   : bin {NLINEAR} -> {NBINS-1}     （对数均分）")
    A("//")
    A(f"//   bin k 的频率 = k x fs/N = k x {FS:.0f}/{2*NBINS} = k x {FS/(2*NBINS):.3f} Hz")
    A("//=============================================================================")
    A("`timescale 1ns/1ps")
    A("")
    A("module spectrum_map #(")
    A(f"    parameter integer NBARS = {NBARS},")
    A(f"    parameter integer AW    = {AW}          // 柱编号位宽 = $clog2(NBARS)")
    A(") (")
    A("    input  wire [AW-1:0]    bar,         // 柱编号 0..NBARS-1")
    A("    output reg  [8:0]       last_bin     // 该柱覆盖的最后一个 bin 编号")
    A(");")
    A("")
    A("    always @(*) begin")
    A("        case (bar)")
    for i in range(NBARS):
        A(f"            {AW}'d{i:<2}: last_bin = 9'd{st[i+1]-1};")
    A("            default: last_bin = 9'd0;")
    A("        endcase")
    A("    end")
    A("")
    A("endmodule")

    verilog = "\n".join(L) + "\n"
    long_lines = [(i + 1, len(x)) for i, x in enumerate(L) if len(x) > 100]
    assert not long_lines, f"超长行: {long_lines}"

    if '--write' in sys.argv:
        dst = os.path.join(root, 'rtl', 'audio', 'spectrum_map.v')
        open(dst, 'w', encoding='utf-8').write(verilog)
        print(f"已写入 {dst}", file=sys.stderr)
    else:
        print(verilog)

    # -------------------------------------------------------------------------
    # 文档用的频率对照表
    # -------------------------------------------------------------------------
    print("\n--- 频率对照表 ---", file=sys.stderr)
    print("| 柱 | bin 范围 | 频率范围 (Hz) | 柱宽 | 说明 |", file=sys.stderr)
    print("| --- | --- | --- | --- | --- |", file=sys.stderr)
    for i in range(NBARS):
        lo, hi = st[i], st[i + 1] - 1
        f0, f1 = lo * FS / (2 * NBINS), (hi + 1) * FS / (2 * NBINS)
        note = ""
        if i == 0:                 note = "直流"
        elif i < NLINEAR:          note = "线性段"
        elif (i - NLINEAR) % 4 == 0: note = f"八度附近"
        print(f"| {i} | {lo}–{hi} | {f0:.1f} – {f1:.1f} | {hi-lo+1} | {note} |",
              file=sys.stderr)
    print(f"\n起点表: {st}", file=sys.stderr)


if __name__ == '__main__':
    main()
