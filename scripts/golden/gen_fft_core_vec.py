#!/usr/bin/env python3
"""
gen_fft_core_vec.py - 生成 fft_core 的端到端测试向量

产物：
    sim/vectors/fft_in.hex    NTEST x N   个输入样本（实数，Q1.23，24bit hex）
    sim/vectors/fft_mag.hex   NTEST x N/2 个期望幅度（25bit hex）
    sim/vectors/fft_meta.txt  元信息（测试数、点数）

用法：
    python3 scripts/golden/gen_fft_core_vec.py

【测试激励设计】每组针对一个具体的算法性质：
    1. 冲激        -> 频谱应完全平坦（所有 bin 相等），最能暴露地址/位反转错误
    2. 单音 1kHz   -> 峰值必须精确落在 bin 21
    3. 双音        -> 两个峰 + 各自的镜像峰
    4. 小幅 1kHz   -> 实际音频量级（0.05 满量程），检查小信号精度
"""

from __future__ import annotations

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fft_dsp import DW, fft_core_model, load_twiddle_from_rom  # noqa: E402

N     = 1024
LOG2N = 10
HALF  = N // 2
FS    = 48000.0
FSAMP = float(1 << (DW - 1))        # Q1.23 满量程 8388608

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VECD = os.path.join(ROOT, "sim", "vectors")


def h(v: int, bits: int) -> str:
    return format(v & ((1 << bits) - 1), "0%dx" % ((bits + 3) // 4))


def tone(freq: float, amp: float, n: int, phase: float = 0.0):
    return [int(round(amp * FSAMP * math.sin(2 * math.pi * freq * i / FS + phase)))
            for i in range(n)]


def build_tests():
    """返回 [(名字, 输入样本列表), ...]"""
    T = []

    # 1) 冲激：频谱应该完全平坦
    T.append(("冲激", [1 << 22] + [0] * (N - 1)))

    # 2) 单音 1 kHz（幅度 0.5）
    T.append(("单音 1kHz", tone(1000.0, 0.5, N)))

    # 3) 双音 1 kHz + 3 kHz
    a = tone(1000.0, 0.5, N)
    b = tone(3000.0, 0.25, N)
    T.append(("双音 1k+3k", [x + y for x, y in zip(a, b)]))

    # 4) 小幅度单音（实际音频量级 0.05）
    T.append(("小信号 1kHz", tone(1000.0, 0.05, N)))

    return T


def main():
    tests = build_tests()
    tw = load_twiddle_from_rom()
    os.makedirs(VECD, exist_ok=True)

    with open(os.path.join(VECD, "fft_in.hex"), "w") as fi, \
         open(os.path.join(VECD, "fft_mag.hex"), "w") as fm:

        for name, x in tests:
            assert len(x) == N, name
            mag = fft_core_model(x, LOG2N, tw)

            for v in x:
                fi.write(h(v, DW) + "\n")
            for v in mag:
                fm.write(h(v, DW + 1) + "\n")

            # 打印一个可眼检的结论
            pk = max(range(HALF), key=lambda k: mag[k])
            pkf = pk * FS / N
            print(f"  {name:14s} 峰值 bin={pk:3d} ({pkf:7.1f} Hz)  "
                  f"幅值={mag[pk]:8d}  DC={mag[0]:6d}")

    with open(os.path.join(VECD, "fft_meta.txt"), "w") as f:
        f.write(f"NTEST={len(tests)} N={N} LOG2N={LOG2N}\n")

    print(f"  生成 {len(tests)} 组测试 -> sim/vectors/fft_{{in,mag}}.hex")
    return 0


if __name__ == "__main__":
    sys.exit(main())
