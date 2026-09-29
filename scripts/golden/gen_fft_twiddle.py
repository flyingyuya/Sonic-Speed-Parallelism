#!/usr/bin/env python3
"""
gen_fft_twiddle.py - 生成 FFT 旋转因子系数 ROM

产物：
    rtl/fft/fft_twiddle_rom.v    旋转因子的只读系数表

用法：
    python3 scripts/golden/gen_fft_twiddle.py

数学：
    W_N^k = e^(-j·2πk/N) = cos(2πk/N) - j·sin(2πk/N)

    只存 k = 0 ~ N/2-1 共 N/2 = 512 项，因为
        W_N^(k + N/2) = -W_N^k          （后半圈靠取负得到）

定点：
    实部、虚部各 16bit Q1.15（|W| = 1，两部分都在 [-1, +1) 内）
    ROM 字宽 32bit：{imag[15:0], real[15:0]}

    ⚠️ W^0 = 1.0 量化后是 32768，超出 Q1.15 正数上限 32767，
       会被钳位到 32767（误差 -3e-5，可忽略）。钳位是必须的，否则回绕成负数。

为什么用 case 语句而不是 $readmemh：
    和 eq_coeff_rom.v 保持一致 —— 生成的 ROM 自包含，
    不依赖外部 .mem 文件的路径，仿真/综合/换目录都不会失效。
"""

from __future__ import annotations

import math
import os
import sys

# ---------------------------------------------------------------------------
# 参数
# ---------------------------------------------------------------------------
N      = 1024               # FFT 点数
HALF   = N // 2             # 只存一半：512
LOG2N  = 10

Q      = 15                 # Q1.15
QMIN   = -(1 << Q)          # -32768
QMAX   = (1 << Q) - 1       # +32767
QSCALE = 1 << Q

ADDR_W = (HALF - 1).bit_length()      # 9 位地址（0~511）

ROOT   = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
OUT_V  = os.path.join(ROOT, "rtl", "fft", "fft_twiddle_rom.v")


# ---------------------------------------------------------------------------
# 量化
# ---------------------------------------------------------------------------
def quant(v: float) -> int:
    """浮点 -> Q1.15 定点，四舍五入（远离零）+ 钳位。

    不用 Python 内置 round()：它是"银行家舍入"（.5 往偶数靠），
    行为不直观。这里显式写成远离零的舍入，和通常的 DSP 实现一致。
    """
    scaled = v * QSCALE
    if scaled >= 0.0:
        n = int(math.floor(scaled + 0.5))
    else:
        n = int(math.ceil(scaled - 0.5))
    return max(QMIN, min(QMAX, n))


def gen_table() -> list[tuple[int, int]]:
    """返回 [(re, im), ...]，共 HALF 项。"""
    tbl = []
    for k in range(HALF):
        ang = 2.0 * math.pi * k / N
        re = quant(math.cos(ang))
        im = quant(-math.sin(ang))          # ← 负号！正变换是 e^{-j...}
        tbl.append((re, im))
    return tbl


# ---------------------------------------------------------------------------
# 自检
# ---------------------------------------------------------------------------
def check(tbl: list[tuple[int, int]]) -> bool:
    ok = True

    # --- 1. 幅度检查：|W^k| 必须恒为 1（误差 < 0.01%）---
    worst = 0.0
    worst_k = -1
    for k, (re, im) in enumerate(tbl):
        mag2 = (re * re + im * im) / float(QSCALE * QSCALE)
        err = abs(mag2 - 1.0)
        if err > worst:
            worst, worst_k = err, k
    if worst > 1e-4:
        print(f"  ✗ 幅度检查失败：k={worst_k} 相对误差 {worst:.2e}")
        ok = False

    # --- 2. 关键点手算核对 ---
    # k=0:    W^0   =  1 - 0j
    # k=N/4:  W^256 =  0 - 1j
    # k=N/8:  W^128 = √2/2 - √2/2 j
    # k=N/16: W^64  = cos(π/8) - sin(π/8) j
    expect = {
        0:        (32767,      0),        # 1.0 被钳位到 32767
        64:       (30274, -12540),        # cos(π/8)=0.92388, sin(π/8)=0.38268
        128:      (23170, -23170),        # √2/2 = 0.70711
        256:      (0,     -32768),        # -1j
    }
    for k, (er, ei) in expect.items():
        gr, gi = tbl[k]
        if (gr, gi) != (er, ei):
            print(f"  ✗ k={k} 期望 ({er},{ei})，实际 ({gr},{gi})")
            ok = False

    # --- 3. 共轭对称性：W^(N-k) = conj(W^k)，在表内体现为
    #        W^(HALF-k) = -conj(W^k)      （因为 W^(HALF) = -1）
    bad_sym = 0
    for k in range(1, HALF // 2):
        re_a, im_a = tbl[k]
        re_b, im_b = tbl[HALF - k]
        # 期望 (re_b, im_b) ≈ (-re_a, +im_a)
        if abs(re_b + re_a) > 2 or abs(im_b - im_a) > 2:
            bad_sym += 1
            if bad_sym <= 3:
                print(f"  ✗ 对称性 k={k}: W^k=({re_a},{im_a}) W^(512-k)=({re_b},{im_b})")
    if bad_sym:
        print(f"  ✗ 对称性检查失败 {bad_sym} 处")
        ok = False

    # --- 报告 ---
    print(f"  幅度误差最大 {worst:.2e} （阈值 1e-4）  最差点 k={worst_k}")
    print(f"  关键点核对 : {'通过' if ok else '不通过'}")
    print(f"  共轭对称性 : {'通过' if bad_sym == 0 else f'{bad_sym} 处不符'}")
    return ok


# ---------------------------------------------------------------------------
# 生成 Verilog
# ---------------------------------------------------------------------------
HEADER = """//=============================================================================
// fft_twiddle_rom.v - {n} 点 FFT 旋转因子表
//-----------------------------------------------------------------------------
//   **本文件由 scripts/golden/gen_fft_twiddle.py 自动生成，不要手改**
//
//   W_N^k = cos(2*pi*k/N) - j*sin(2*pi*k/N)      k = 0 ~ {half_minus1}
//   （后半圈 W^(k+N/2) = -W^k，由蝶形单元取负得到，不占 ROM）
//
//   定点：Q1.{Q}，字宽 32bit = {{imag[15:0], real[15:0]}}
//         |W| 恒为 1，实虚部都在 [-1, +1) 内
//         注意 W^0 = 1.0 量化后是 {qscale}，超出上限 {qmax}，已钳位
//
//   地址 {addr_w} 位，深度 {half}
//   综合后应映射为分布式 LUT ROM 或 1 个 BRAM18
//=============================================================================
`timescale 1ns/1ps

module fft_twiddle_rom (
    input  wire [{awm1}:0] addr,      // 0 ~ {half_minus1}
    output reg  [31:0]     dout       // {{imag[15:0], real[15:0]}}
);

    always @* begin
        case (addr)
"""

FOOTER = """            // 兜底：W^0 = 1 - 0j（正常情况下不可达）
            default: dout = 32'h00007fff;
        endcase
    end

endmodule
"""


def gen_verilog(tbl: list[tuple[int, int]]) -> str:
    lines = [HEADER.format(
        n=N, Q=Q, half=HALF, half_minus1=HALF - 1,
        qscale=QSCALE, qmax=QMAX, addr_w=ADDR_W, awm1=ADDR_W - 1,
    )]

    for k, (re, im) in enumerate(tbl):
        # 每 64 项插一条角度注释，方便调试时定位
        if k % 64 == 0:
            deg = 360.0 * k / N
            lines.append(f"            // ---- k = {k:3d} ~ {min(k+63, HALF-1):3d}"
                         f"   角度 {deg:6.1f} ~ {360.0*min(k+63,HALF-1)/N:6.1f} 度 ----\n")
        word = ((im & 0xFFFF) << 16) | (re & 0xFFFF)
        lines.append(f"            {ADDR_W}'d{k}: dout = 32'h{word:08X};"
                     f"   // W^{k} = {re/QSCALE:+.5f} {im/QSCALE:+.5f}j\n")

    lines.append(FOOTER)
    return "".join(lines)


# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
def main() -> int:
    print(f"[1/3] 生成 {N} 点旋转因子表（只存前 {HALF} 项，Q1.{Q}）...")
    tbl = gen_table()

    print(f"[2/3] 自检 ...")
    if not check(tbl):
        print("自检不通过，**不生成文件**。")
        return 1

    print(f"[3/3] 写出 Verilog ...")
    os.makedirs(os.path.dirname(OUT_V), exist_ok=True)
    with open(OUT_V, "w") as f:
        f.write(gen_verilog(tbl))

    size = os.path.getsize(OUT_V)
    print(f"  已生成 {os.path.relpath(OUT_V, ROOT)}"
          f"（{HALF} 项，{size/1024:.1f} KB）")
    print("完成。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
