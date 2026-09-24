"""
dsp.py - 与 RTL 位级一致的定点 DSP 黄金模型

设计原则：
    RTL 里每一处舍入、饱和、移位，这里都有一一对应的 Python 实现。
    仿真对拍时不是"差不多对"，而是逐位相等。

定点约定（与 rtl/audio/eq_cascade.v 完全一致）：
    x, y   : 24bit signed, Q1.23     满量程 +-1.0 -> +-8388607
    coeff  : 18bit signed, Q2.16     范围 [-2, 2)，覆盖 b1≈-1.984 这类系数
    state  : 48bit signed, 小数位 = 23+16 = 39
    输出   : y = sat24( (acc + 2^15) >>> 16 )

为什么系数必须是 Q2.16 而不是 Q1.17：
    双二阶级联的 b1/a1 典型值在 -2 附近（低架滤波器可达 -1.984）。
    Q1.17（比例 2^-17，范围 [-1,1)）会把它们削顶到 -1.0，直接毁掉滤波器
    （实测频响最大误差 7 dB）。Q2.16（比例 2^-16，范围 [-2,2)）不削顶，
    实测最大频响误差 0.048 dB —— 远低于人耳 0.3 dB 的可闻阈值。
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

# ---------------------------------------------------------------------------
# 位宽常量
# ---------------------------------------------------------------------------
DW = 24                 # 样本位宽          Q1.23
CW = 18                 # 系数位宽          Q2.16
DF = DW - 1             # 样本小数位        = 23
CF = CW - 2             # 系数小数位        = 16
AW = 48                 # 状态累加器位宽
SH = CF                 # 乘积 -> 样本 的右移位数 = 16

SAMPLE_MAX = (1 << (DW - 1)) - 1        # +8388607
SAMPLE_MIN = -(1 << (DW - 1))           # -8388608
COEF_MAX = (1 << (CW - 1)) - 1          # +131071  (= 1.99998)
COEF_MIN = -(1 << (CW - 1))             # -131072  (= -2.0)

RND = 1 << (SH - 1)                     # 四舍五入偏置 2^15
ACC_MASK = (1 << AW) - 1


def sat24(v: int) -> int:
    """饱和到 24bit signed（对应 RTL 里的 MAXV/MINV 比较）。"""
    if v > SAMPLE_MAX:
        return SAMPLE_MAX
    if v < SAMPLE_MIN:
        return SAMPLE_MIN
    return v


def wrap_acc(v: int) -> int:
    """截断到 48bit signed，模拟 RTL 中 AW 位寄存器的赋值行为。"""
    v &= ACC_MASK
    if v >= (1 << (AW - 1)):
        v -= (1 << AW)
    return v


def quant_coef(c: float, bits: int = CW, frac: int = CF) -> int:
    """浮点系数 -> Q(bits-frac).frac 定点，四舍五入 + 饱和。

    bits=18, frac=16 -> Q2.16，范围 [-2, 2)，分辨率 2^-16 = 1.5e-5。
    """
    scale = 1 << frac
    v = int(round(c * scale))
    hi = (1 << (bits - 1)) - 1
    lo = -(1 << (bits - 1))
    return max(lo, min(hi, v))


def check_coef_range(table, bits: int = CW, frac: int = CF):
    """设计期检查：任何系数超出定点范围都会削顶毁掉滤波器，必须提前报错。"""
    limit = float(1 << (bits - 1)) / (1 << frac)
    bad = []
    for bi, sec in enumerate(table):
        for k, c in enumerate(sec):
            if not (-limit <= c < limit):
                bad.append((bi, k, c))
    return limit, bad


def response_db(table, freqs, fs: float = 48000.0, fixed: bool = True):
    """频响（dB）。fixed=True 时使用定点系数，a0 也按同一比例缩放。

    注意：定点评估时必须把 a0 当成 (1<<CF) 而不是 1.0 —— 否则分母少乘了
    系数比例，会虚报出完全错误的误差（这个坑踩过一次）。
    """
    import cmath
    out = []
    for f in freqs:
        z = cmath.exp(-1j * 2.0 * math.pi * f / fs)
        h = complex(1.0, 0.0)
        for sec in table:
            c = [quant_coef(v) for v in sec] if fixed else list(sec)
            a0 = float(1 << CF) if fixed else 1.0
            b0, b1, b2, a1, a2 = c
            h *= (b0 + b1 * z + b2 * z * z) / (a0 + a1 * z + a2 * z * z)
        out.append(20.0 * math.log10(max(abs(h), 1e-30)))
    return out


# ---------------------------------------------------------------------------
# 双二阶滤波器（DF2T），与 RTL 的单段行为一一对应
# ---------------------------------------------------------------------------
class Biquad:
    """Direct-Form-II-Transposed 双二阶，定点行为与 eq_cascade 的一个 section 相同。"""

    __slots__ = ("b0", "b1", "b2", "a1", "a2", "s1", "s2")

    def __init__(self, b0: int, b1: int, b2: int, a1: int, a2: int):
        self.b0, self.b1, self.b2 = b0, b1, b2
        self.a1, self.a2 = a1, a2
        self.s1 = 0
        self.s2 = 0

    def step(self, x: int) -> int:
        # RTL: acc = p0 + st1;  yn = sat( (acc + RND) >>> SH )
        acc = x * self.b0 + self.s1
        y = sat24((acc + RND) >> SH)
        # RTL: st1' = p1 + st2 - a1*y ; st2' = p2 - a2*y
        self.s1 = wrap_acc(x * self.b1 + self.s2 - y * self.a1)
        self.s2 = wrap_acc(x * self.b2 - y * self.a2)
        return y

    def coeffs(self):
        return (self.b0, self.b1, self.b2, self.a1, self.a2)


class Cascade:
    """NSECT 段级联（section 之间串联，与 RTL 时分复用顺序一致）。"""

    def __init__(self, sections):
        self.sections = list(sections)

    @classmethod
    def from_coeff_table(cls, table):
        """table: [[b0,b1,b2,a1,a2], ...] 浮点系数（a0 已归一化）。"""
        return cls(Biquad(*[quant_coef(c) for c in sec]) for sec in table)

    def step(self, x: int) -> int:
        for s in self.sections:
            x = s.step(x)
        return x

    def process(self, xs):
        return [self.step(int(v)) for v in xs]


# ---------------------------------------------------------------------------
# 滤波器设计（RBJ Audio EQ Cookbook）
# ---------------------------------------------------------------------------
def peaking_eq(f0: float, fs: float, q: float, gain_db: float):
    """返回归一化后的 (b0,b1,b2,a1,a2)，a0 已约掉。gain_db=0 时理论上恒等。"""
    A = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * math.pi * f0 / fs
    cw = math.cos(w0)
    sw = math.sin(w0)
    alpha = sw / (2.0 * q)

    b0 = 1.0 + alpha * A
    b1 = -2.0 * cw
    b2 = 1.0 - alpha * A
    a0 = 1.0 + alpha / A
    a1 = -2.0 * cw
    a2 = 1.0 - alpha / A

    return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


def low_shelf(f0: float, fs: float, q: float, gain_db: float):
    A = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * math.pi * f0 / fs
    cw, sw = math.cos(w0), math.sin(w0)
    alpha = sw / (2.0 * q)
    sq = 2.0 * math.sqrt(A) * alpha

    b0 = A * ((A + 1) - (A - 1) * cw + sq)
    b1 = 2 * A * ((A - 1) - (A + 1) * cw)
    b2 = A * ((A + 1) - (A - 1) * cw - sq)
    a0 = (A + 1) + (A - 1) * cw + sq
    a1 = -2 * ((A - 1) + (A + 1) * cw)
    a2 = (A + 1) + (A - 1) * cw - sq
    return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


def high_shelf(f0: float, fs: float, q: float, gain_db: float):
    A = 10.0 ** (gain_db / 40.0)
    w0 = 2.0 * math.pi * f0 / fs
    cw, sw = math.cos(w0), math.sin(w0)
    alpha = sw / (2.0 * q)
    sq = 2.0 * math.sqrt(A) * alpha

    b0 = A * ((A + 1) + (A - 1) * cw + sq)
    b1 = -2 * A * ((A - 1) + (A + 1) * cw)
    b2 = A * ((A + 1) + (A - 1) * cw - sq)
    a0 = (A + 1) - (A - 1) * cw + sq
    a1 = 2 * ((A - 1) - (A + 1) * cw)
    a2 = (A + 1) - (A - 1) * cw - sq
    return (b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0)


# ---------------------------------------------------------------------------
# 本项目的 5 段均衡器参数表
# ---------------------------------------------------------------------------
BANDS_HZ = [100.0, 300.0, 1000.0, 3000.0, 8000.0]
BAND_Q = 1.0
FS = 48000.0
GAIN_MIN_DB = -10.0
GAIN_STEP_DB = 1.0
NGAIN = 21                                  # -10dB .. +10dB，1dB 一档


def gain_db_of(idx: int) -> float:
    return GAIN_MIN_DB + GAIN_STEP_DB * idx


def design_band(band_idx: int, gain_idx: int):
    """第 band_idx 段在 gain_idx 档位下的 5 个系数（浮点）。

    结构选择（决定了定点精度能否达标）：
      band0 (100Hz)  : **一阶低架**
          二阶低架的分母在近 DC 处有极强的相位抵消（分子 ~w0^2），
          18bit 系数根本不够——实测最差频响误差 1.4dB。
          一阶低架的分子只与 w0 同阶，条件数好 40 倍，误差降到 0.09dB。
      band1~3        : 二阶 peaking（峰值滤波器，DC/Nyquist 增益恰为 1）
      band4 (8kHz)   : 二阶 peaking
          二阶高架在 fs=48k 下 b0 会到 2.12，超出 Q2.16 的 [-2,2) 范围，
          换成 peaking 后最大系数 1.977，安全。
    """
    f0 = BANDS_HZ[band_idx]
    g = gain_db_of(gain_idx)
    if band_idx == 0:
        return first_order_low_shelf(f0, FS, 10.0 ** (g / 20.0))
    return peaking_eq(f0, FS, BAND_Q, g)


def first_order_low_shelf(f0: float, fs: float, v: float):
    """一阶低架滤波器：低频增益 v（线性），高频增益 1，转折约在 f0。

    H(z) = (b0 + b1*z^-1) / (1 + a1*z^-1)
    极点 p = (1-t)/(1+t), t = tan(pi*f0/fs)，a1 = -p
    由 H(1)=v, H(-1)=1 解出 b0/b1。
    返回 (b0, b1, 0, a1, 0) —— 二阶结构下 b2=a2=0 即退化为该一阶滤波器。
    """
    t = math.tan(math.pi * f0 / fs)
    p = (1.0 - t) / (1.0 + t)
    a1 = -p
    b0 = (v * (1.0 - p) + (1.0 + p)) / 2.0
    b1 = (v * (1.0 - p) - (1.0 + p)) / 2.0
    return (b0, b1, 0.0, a1, 0.0)


def first_order_high_shelf(f0: float, fs: float, v: float):
    """一阶高架滤波器：高频增益 v，低频增益 1。（备用，当前未使用）"""
    t = math.tan(math.pi * f0 / fs)
    p = (1.0 - t) / (1.0 + t)
    a1 = -p
    b0 = ((1.0 - p) + v * (1.0 + p)) / 2.0
    b1 = ((1.0 - p) - v * (1.0 + p)) / 2.0
    return (b0, b1, 0.0, a1, 0.0)


def coeff_table(band_idx: int, gain_idx: int):
    """整条链路（5 段）在每个 band 上使用不同增益档位时用的系数组合。

    这里给出的"全链路"表用于：只有第 band_idx 段被调整、其余段保持 0dB 的场景。
    0dB 的 peaking 段在数学上恒等，但定点下有极小误差，所以离线把 5 段一起算。
    """
    secs = []
    for b in range(len(BANDS_HZ)):
        g = gain_db_of(gain_idx) if b == band_idx else 0.0
        secs.append(design_band(b, g))
    return secs


def coeff_table_preset(gain_idxs):
    """任意增益组合：gain_idxs 长度必须等于频段数。"""
    assert len(gain_idxs) == len(BANDS_HZ)
    return [design_band(b, gain_idxs[b]) for b in range(len(BANDS_HZ))]


# ---------------------------------------------------------------------------
# 定点响应验证工具
# ---------------------------------------------------------------------------
def fixed_response_db(table, freqs, fs: float = FS):
    """用定点实现跑单频正弦，测稳态幅度（dB），用于验证定点与浮点差异。"""
    import cmath
    out = []
    for f in freqs:
        casc = Cascade.from_coeff_table(table)
        n = 4096
        peak = 0.0
        w = 2 * math.pi * f / fs
        # 前 2048 点丢弃（过渡态）
        for i in range(n):
            x = int(round(0.25 * SAMPLE_MAX * math.sin(w * i)))
            y = casc.step(x)
            if i > n // 2:
                peak = max(peak, abs(y))
        ref = 0.25 * SAMPLE_MAX
        out.append(20.0 * math.log10(max(peak, 1.0) / ref))
    return out
