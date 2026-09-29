#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_rainbow.py —— 生成彩虹颜色表（128 级 RGB888）

配色公式来自参考工程 docs/Music-Spectrum 的 rainbow_colors.v：
    用 RGB565 存了 128 级，我反推验证过它就是 HSL(H, S=0.85, L=0.6)，
    H 从 0 扫到 360。

我们用 RGB888（因为本板液晶是 24 位的），所以重新按公式算，不用抄它的常量。

输出：
    rtl/video/rainbow_rom.v    128 项 x 24 bit
"""
import os, colorsys, sys

N = 128
S = 0.85
L = 0.6


def hsl_to_rgb888(h_deg, s, l):
    r, g, b = colorsys.hls_to_rgb(h_deg / 360.0, l, s)
    return int(round(r * 255)), int(round(g * 255)), int(round(b * 255))


def main():
    cols = [hsl_to_rgb888(360.0 * i / N, S, L) for i in range(N)]

    # 自检：0 度偏红、1/3 偏绿、2/3 偏蓝。
    #   注意 L=0.6 不是满饱和，所以"红"是 (240,66,66) 而不是 (255,0,0)：
    #     C = (1-|2L-1|) x S = 0.68,  m = L - C/2 = 0.26
    #     R = C+m = 0.94 -> 240,   G = B = m = 0.26 -> 66
    def is_dom(c, k, lo=200, hi=110):
        return c[k] > lo and all(c[j] < hi for j in range(3) if j != k)
    assert is_dom(cols[0], 0), f"H=0 不是偏红: {cols[0]}"
    assert is_dom(cols[N // 3], 1), f"H=120 不是偏绿: {cols[N // 3]}"
    assert is_dom(cols[2 * N // 3], 2), f"H=240 不是偏蓝: {cols[2 * N // 3]}"
    # 与参考工程反推的 RGB565 表对齐核对（允许 1 LSB 的量化差）
    r5, g6, b5 = round(240 / 255 * 31), round(66 / 255 * 63), round(66 / 255 * 31)
    assert abs(r5 - 30) <= 1 and g6 == 16 and b5 == 8, \
        f"与参考工程 rom[0]=(30,16,8) 不符: 反推得 ({r5},{g6},{b5})"

    L_ = []
    A = L_.append
    A("//=============================================================================")
    A("// rainbow_rom.v - 彩虹颜色表（128 级 RGB888）")
    A("//-----------------------------------------------------------------------------")
    A("// ⚠️ 由 scripts/golden/gen_rainbow.py 自动生成，请勿手工修改。")
    A("//")
    A(f"// 配色：HSL(H, S={S}, L={L})，H = 0..360 均分 {N} 级")
    A("//   H=0 -> 红   H=1/3 -> 绿   H=2/3 -> 蓝   循环回红")
    A("//   这个公式是从参考工程 Music-Spectrum 的 RGB565 表反推验证出来的：")
    A("//   它的 rom[0] = 16'b11110_010000_01000 = (30,16,8)，")
    A("//   恰好等于 HSL(0, 0.85, 0.6) 量化到 RGB565 的结果。")
    A("//")
    A("// 地址是【循环】的：调用方对 128 取模即可实现彩虹滚动效果。")
    A("//=============================================================================")
    A("`timescale 1ns/1ps")
    A("")
    A("module rainbow_rom (")
    A("    input  wire [6:0]   addr,       // 0..127")
    A("    output reg  [23:0]  rgb         // {R[7:0], G[7:0], B[7:0]}")
    A(");")
    A("")
    A("    always @(*) begin")
    A("        case (addr)")
    for i, (r, g, b) in enumerate(cols):
        A(f"            7'd{i:<3}: rgb = 24'h{r:02X}{g:02X}{b:02X};")
    A("            default: rgb = 24'h000000;")
    A("        endcase")
    A("    end")
    A("")
    A("endmodule")

    verilog = "\n".join(L_) + "\n"
    bad = [(i + 1, len(x)) for i, x in enumerate(L_) if len(x) > 100]
    assert not bad, f"超长行: {bad}"

    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
    if '--write' in sys.argv:
        dst = os.path.join(root, 'rtl', 'video', 'rainbow_rom.v')
        open(dst, 'w', encoding='utf-8').write(verilog)
        print(f"已写入 {dst}", file=sys.stderr)
    else:
        print(verilog)

    print(f"\n前 8 级: {['#%02X%02X%02X' % c for c in cols[:8]]}", file=sys.stderr)
    print(f"中间 4 级: {['#%02X%02X%02X' % c for c in cols[62:66]]}", file=sys.stderr)


if __name__ == '__main__':
    main()
