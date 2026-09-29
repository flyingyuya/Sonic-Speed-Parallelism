"""
fft_dsp.py - FFT 的 Python 定点黄金模型

与 RTL 严格位级对应：
    rtl/fft/fft_butterfly.v   <->  butterfly()
    后续 fft_core.v           <->  会陆续加进来

【核心约定】Python 的 >> 对负数是 floor（算术右移），
            和 Verilog 的 >>> 语义完全一致 —— 这是能逐位对齐的前提。
"""

from __future__ import annotations

# ---------------------------------------------------------------------------
# 默认位宽（与 fft_butterfly.v 的 parameter 对应）
# ---------------------------------------------------------------------------
DW = 24         # 数据位宽  Q1.23
TW = 16         # 旋转因子  Q1.15

# 旋转因子的右移量 = 系数的小数位
SH_TW = TW - 1          # 15
RND_TW = 1 << (SH_TW - 1)   # 2^14，四舍五入偏置


def sat(v: int, bits: int = DW) -> int:
    """饱和到 bits 位有符号（对应 RTL 里的 sat() 函数）。"""
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    return lo if v < lo else (hi if v > hi else v)


def butterfly_ex(ar: int, ai: int, br: int, bi: int,
                 wr: int, wi: int,
                 dw: int = DW, tw: int = TW):
    """蝶形运算（带饱和标志），位级复刻 fft_butterfly.v。

    返回 (pr, pi, qr, qi, saturated)：
        saturated=True 表示中间结果触发了饱和，
        此时与"纯浮点参考"的差异是**预期行为**（不是 bug），
        做浮点量级自检时应该排除这些点。
    """
    sh_tw  = tw - 1
    rnd_tw = 1 << (sh_tw - 1)
    lo, hi = -(1 << (dw - 1)), (1 << (dw - 1)) - 1

    t_re_w = br * wr - bi * wi
    t_im_w = br * wi + bi * wr

    t_re_raw = (t_re_w + rnd_tw) >> sh_tw
    t_im_raw = (t_im_w + rnd_tw) >> sh_tw
    sat_flag = not (lo <= t_re_raw <= hi and lo <= t_im_raw <= hi)

    t_re = sat(t_re_raw, dw)
    t_im = sat(t_im_raw, dw)

    pr_raw = ((ar + t_re) + 1) >> 1
    pi_raw = ((ai + t_im) + 1) >> 1
    qr_raw = ((ar - t_re) + 1) >> 1
    qi_raw = ((ai - t_im) + 1) >> 1
    if not (lo <= pr_raw <= hi and lo <= pi_raw <= hi
            and lo <= qr_raw <= hi and lo <= qi_raw <= hi):
        sat_flag = True

    return (sat(pr_raw, dw), sat(pi_raw, dw),
            sat(qr_raw, dw), sat(qi_raw, dw), sat_flag)


def butterfly(ar: int, ai: int, br: int, bi: int,
              wr: int, wi: int,
              dw: int = DW, tw: int = TW):
    """同 butterfly_ex，只返回 4 个输出（不含饱和标志）。"""
    pr, pi, qr, qi, _ = butterfly_ex(ar, ai, br, bi, wr, wi, dw, tw)
    return pr, pi, qr, qi


# ---------------------------------------------------------------------------
# 自检：用浮点参考验证定点模型（只做量级检查，不做逐位比对）
# ---------------------------------------------------------------------------
def butterfly_float(ar: int, ai: int, br: int, bi: int,
                    wr: int, wi: int, dw: int = DW, tw: int = TW):
    """同一运算的浮点版本，用于量级自检。"""
    scale = float(1 << (dw - 1))          # Q1.23 的满量程
    a = complex(ar / scale, ai / scale)
    b = complex(br / scale, bi / scale)
    w = complex(wr / float(1 << (tw - 1)), wi / float(1 << (tw - 1)))
    t = w * b
    p = (a + t) / 2.0
    q = (a - t) / 2.0

    def qz(v):
        return sat(int(round(v.real * scale)), dw), sat(int(round(v.imag * scale)), dw)

    return qz(p) + qz(q)


# ---------------------------------------------------------------------------
# 完整 FFT 的黄金模型（镜像 rtl/fft/fft_core.v）
# ---------------------------------------------------------------------------
import os
import re

ROOT_GD = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ROM_V   = os.path.join(ROOT_GD, "rtl", "fft", "fft_twiddle_rom.v")


def load_twiddle_from_rom(path: str = ROM_V):
    """从生成的 Verilog ROM 里解析旋转因子表。

    为什么不在模型里重算 cos/sin：
      ROM 已经独立验证过了（用量化表跑直接 DFT 与 numpy.fft 对比，
      误差 2.9e-06）。这里直接读 ROM，保证模型和硬件用的是同一份数据。
    """
    tbl = []
    for line in open(path):
        m = re.match(r"\s*9'd(\d+): dout = 32'h([0-9A-Fa-f]{8});", line)
        if m:
            assert int(m.group(1)) == len(tbl)
            w = int(m.group(2), 16)
            r, i = w & 0xFFFF, (w >> 16) & 0xFFFF
            if r >= 0x8000: r -= 0x10000
            if i >= 0x8000: i -= 0x10000
            tbl.append((r, i))
    return tbl


def mag_approx(re: int, im: int):
    """|X| ≈ max + 0.4375·min，位级复刻 fft_core.v 的幅度计算。

    注意：绝对值必须先取到 dw+1 位再比较，否则 re = -2^23 会算错。
    """
    are = (-re) if re < 0 else re
    aim = (-im) if im < 0 else im
    mx = are if are > aim else aim
    mn = aim if are > aim else are
    return mx + ((mn >> 1) - (mn >> 4))


def addr_naive(log2n: int, cnt: int, s: int):
    """朴素地址生成（除法取模）—— 故意和 RTL 的位操作走不同路径。

    rtl/fft/fft_addr_gen.v 用"插 0 / 插 1"的位移实现，
    两边已用穷举验证过等价（LOG2N=3 与 10 各 0 处不符）。
    模型这边用直译版，保持独立。
    """
    half  = 1 << s
    group, j = divmod(cnt, half)
    p = group * 2 * half + j
    return p, p + half, j * ((1 << log2n) // (2 * half))


def fft_core_model(x, log2n: int = 10, twiddle=None, dw: int = DW, tw: int = TW):
    """完整 FFT 的位级模型。

    输入 x：长度为 N 的实数样本（Q1.23 raw）
    输出  ：长度 N/2 的幅度近似值列表
    """
    N = 1 << log2n
    if twiddle is None:
        twiddle = load_twiddle_from_rom()

    re_a = [0] * N
    im_a = [0] * N
    # 位反转写地址，虚部为 0
    for k in range(N):
        a = int(format(k, "0%db" % log2n)[::-1], 2)
        re_a[a] = x[k]
        im_a[a] = 0

    # LOG2N 级蝶形
    for s in range(log2n):
        for c in range(N // 2):
            p, q, ti = addr_naive(log2n, c, s)
            wr, wi = twiddle[ti]
            pr, pi, qr, qi = butterfly(re_a[p], im_a[p], re_a[q], im_a[q], wr, wi, dw, tw)
            re_a[p], im_a[p] = pr, pi
            re_a[q], im_a[q] = qr, qi

    return [mag_approx(re_a[k], im_a[k]) for k in range(N // 2)]
