#!/usr/bin/env python3
"""
gen_fft_butterfly_vec.py - 生成蝶形单元的测试向量

产物：
    sim/vectors/bf_vec.txt   每行 10 个 hex 字段：
                             ar ai br bi wr wi | pr pi qr qi
                             （前 6 个是输入，后 4 个是黄金模型输出）

用法：
    python3 scripts/golden/gen_fft_butterfly_vec.py

【为什么要用散文件而不是 $readmemh】
    $readmemh 一个文件只能读一列。这里每行有多列输入，
    用 $fscanf 读更自然（testbench 里也是这么做的）。

【测试激励设计】除了随机，还要专门覆盖边界：
    1. 全零            —— 最平凡的情形
    2. 满量程 ±max     —— 触发饱和分支
    3. W = 1+0j        —— 恒等（t = b）
    4. W = -1+0j       —— 取负
    5. W = 0-1j        —— 乘 -j（实虚部交换 + 变号）
    6. b 很大 + a 很大 —— 逼出 a±t 的位宽增长
"""

from __future__ import annotations

import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fft_dsp import DW, TW, butterfly_ex, butterfly_float  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VEC  = os.path.join(ROOT, "sim", "vectors", "bf_vec.txt")

MAXV = (1 << (DW - 1)) - 1      # +8388607
MINV = -(1 << (DW - 1))         # -8388608
TW16_MAX = (1 << (TW - 1)) - 1  # +32767
TW16_MIN = -(1 << (TW - 1))

random.seed(20240923)


def h(v: int, bits: int) -> str:
    return format(v & ((1 << bits) - 1), "0%dx" % ((bits + 3) // 4))


def build_cases():
    """返回 [(ar,ai,br,bi,wr,wi, 说明), ...]"""
    C = []

    # ---- 1. 边界：全零 / 满量程 ----
    C.append((0, 0, 0, 0, 0, 0,            "全零"))
    C.append((MAXV, MAXV, MAXV, MAXV, TW16_MAX, TW16_MAX, "全 +max（触发饱和）"))
    C.append((MINV, MINV, MINV, MINV, TW16_MIN, TW16_MIN, "全 -min（触发饱和）"))
    C.append((MAXV, MINV, MAXV, MINV, TW16_MAX, TW16_MIN, "正负交替极值"))

    # ---- 2. 特殊旋转因子 ----
    for wr_, wi_, name in [(TW16_MAX, 0, "W=1"),
                           (TW16_MIN, 0, "W=-1"),
                           (0, TW16_MIN, "W=-j"),
                           (0, TW16_MAX, "W=+j")]:
        for _ in range(4):
            C.append((random.randint(MINV, MAXV), random.randint(MINV, MAXV),
                      random.randint(MINV, MAXV), random.randint(MINV, MAXV),
                      wr_, wi_, name))

    # ---- 3. W = 0（结果应为 a/2）----
    C.append((MAXV, MINV, MAXV, MINV, 0, 0, "W=0"))

    # ---- 4. 随机（主体）----
    for i in range(500):
        C.append((random.randint(MINV, MAXV), random.randint(MINV, MAXV),
                  random.randint(MINV, MAXV), random.randint(MINV, MAXV),
                  random.randint(TW16_MIN, TW16_MAX),
                  random.randint(TW16_MIN, TW16_MAX),
                  f"随机#{i}"))

    # ---- 5. 小幅度（音频实际量级 ~0.1 满量程）----
    for i in range(100):
        def small():
            return random.randint(-MAXV // 8, MAXV // 8)
        C.append((small(), small(), small(), small(),
                  random.randint(TW16_MIN, TW16_MAX),
                  random.randint(TW16_MIN, TW16_MAX),
                  f"小信号#{i}"))

    return C


def main():
    cases = build_cases()
    os.makedirs(os.path.dirname(VEC), exist_ok=True)

    worst = 0.0
    worst_desc = ""
    n_sat = 0
    n_checked = 0

    with open(VEC, "w") as f:
        for (ar, ai, br, bi, wr, wi, desc) in cases:
            pr, pi, qr, qi, satd = butterfly_ex(ar, ai, br, bi, wr, wi)

            # ---- 自检：和浮点版本比量级 ----
            # 触发了饱和的点必须排除：那种情况下定点结果故意"削平"，
            # 和纯浮点参考差异大是**预期行为**，不是 bug。
            # （饱和逻辑本身由 testbench 与定点模型的逐位对拍来保证）
            if not satd:
                n_checked += 1
                fp = butterfly_float(ar, ai, br, bi, wr, wi)
                scale = float(1 << (DW - 1))
                for g, r in zip((pr, pi, qr, qi), fp):
                    e = abs(g - r) / scale
                    if e > worst:
                        worst, worst_desc = e, desc
            else:
                n_sat += 1

            f.write("%s %s %s %s %s %s %s %s %s %s\n" % (
                h(ar, DW), h(ai, DW), h(br, DW), h(bi, DW),
                h(wr, TW), h(wi, TW),
                h(pr, DW), h(pi, DW), h(qr, DW), h(qi, DW)))

    print(f"  生成 {len(cases)} 组向量 -> {os.path.relpath(VEC, ROOT)}")
    print(f"  浮点量级自检（排除 {n_sat} 组饱和点，实检 {n_checked} 组）")
    print(f"    最大相对误差 : {worst:.3e}   （最差点: {worst_desc}）")
    if worst > 5e-3:
        print("    ⚠️ 误差偏大，检查定点模型")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
