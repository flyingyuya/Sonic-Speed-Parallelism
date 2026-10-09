#!/usr/bin/env python3
# =============================================================================
# gen_wave_fir.py - 生成"波形平滑 FIR"的系数
# -----------------------------------------------------------------------------
# 【这个滤波器是干什么的】
#   给波形显示做低通平滑，目的【不是】听感，而是：
#     ① 让波形看起来干净（去掉高频毛刺）
#     ② 让触发点更稳 —— 过零点附近的噪声会让触发时刻抖动，
#        "画面静止"就变成了"画面在抖"
#
# 【设计选择】
#   · 线性相位（系数对称）：波形不会被"相位失真"扭歪。
#     对示波器式的显示来说这点很重要 —— 非线性相位会让不同频率的分量
#     错开，一个方波会被抹成很奇怪的样子。
#   · 加窗 sinc（Hamming）：标准的低通设计，旁瓣比矩形窗低很多。
#   · 归一化到 sum(h) = 1：直流增益严格为 1，
#     所以滤波前后的"幅度"是对得上的，显示侧的比例不用改。
#
# 【运行】
#   python3 scripts/golden/gen_wave_fir.py            # 打印候选方案的频响
#   python3 scripts/golden/gen_wave_fir.py --emit     # 写出 rtl/common/fir_sym_coeff.v
# =============================================================================
import sys, os, math

# ---------------------------------------------------------------------------
# 候选方案：(抽头数, 截止频率/fs)
#   抽头越多 -> 过渡带越窄、越接近理想低通，但资源也越多。
#   N=15 时资源是 8 个 DSP48 + 360 个 FF，对这个项目非常宽裕。
# ---------------------------------------------------------------------------
CANDIDATES = [
    (15, 0.08),
    (15, 0.12),
    (15, 0.16),
    (31, 0.12),
]

# 最终选中的方案（--emit 用这套）
CHOSEN_N, CHOSEN_FC = 15, 0.12


def design_lowpass(n, fc):
    """加窗 sinc 低通。fc 是归一化截止频率（1.0 = fs）。"""
    m = (n - 1) / 2.0
    h = []
    for i in range(n):
        x = i - m
        # sinc：sin(2*pi*fc*x) / (pi*x)，x=0 时取极限 2*fc
        s = 2.0 * fc if abs(x) < 1e-12 else math.sin(2.0 * math.pi * fc * x) / (math.pi * x)
        # Hamming 窗
        w = 0.54 - 0.46 * math.cos(2.0 * math.pi * i / (n - 1))
        h.append(s * w)
    # 归一化：直流增益 = 1
    tot = sum(h)
    return [v / tot for v in h]


def response_db(h, f_norm):
    """在归一化频率 f_norm 处算幅度响应（dB）。"""
    n = len(h)
    m = (n - 1) / 2.0
    re = sum(h[i] * math.cos(2 * math.pi * f_norm * (i - m)) for i in range(n))
    im = sum(h[i] * math.sin(2 * math.pi * f_norm * (i - m)) for i in range(n))
    mag = math.hypot(re, im)
    return 20.0 * math.log10(mag) if mag > 1e-12 else -999.0


def show(n, fc):
    h = design_lowpass(n, fc)
    print(f"\n=== N={n} 抽头, fc={fc:.3f}*fs = {fc*48000:.0f} Hz ===")
    print("  频率(Hz)  " + "".join(f"{int(f*48000):>9d}" for f in
                                  (0.0, 0.02, 0.05, 0.08, 0.12, 0.16, 0.2, 0.3, 0.4, 0.5)))
    print("  增益(dB)  " + "".join(f"{response_db(h, f):>9.2f}" for f in
                                  (0.0, 0.02, 0.05, 0.08, 0.12, 0.16, 0.2, 0.3, 0.4, 0.5)))
    # 系数（Q2.16，18 位有符号）
    q = [max(-131072, min(131071, int(round(v * 65536)))) for v in h]
    print("  Q2.16 系数:", q)
    print(f"  系数和 = {sum(q)} （理想 65536，误差 {sum(q)-65536:+d}）")
    return q


def emit(q, n, fc):
    """生成一个可 `include 的 .vh。

    为什么用 function 而不是 ROM 模块：
      FIR 里 8 个乘法器的系数在【展开的 for 循环】里被索引，
      编译期就是常数。写成 function + case，综合器会直接常量折叠成连线，
      一个 LUT 都不花；写成单独的 ROM 模块反而要 8 个实例或一次串行读。
    为什么只存前一半 + 中心：对称 FIR 的后一半是镜像。
    """
    cw = 18
    half = n // 2
    rows = []
    for i in range(half + 1):
        v = q[i]
        # ⚠️ 有符号字面量的负号必须写在【基数前面】：-18'sd202 对，18'sd-202 错。
        #    写成后者的话 iverilog 和 Verible 都会报语法错（账本第 98 条）。
        lit = f"-18'sd{-v}" if v < 0 else f"18'sd{v}"
        rows.append(f"            4'd{i}: fir_coef = {lit};")
    width = len(str(half))
    src = f"""//=============================================================================
// fir_sym_coeff.vh - 波形平滑 FIR 的系数（**自动生成，不要手改**）
//-----------------------------------------------------------------------------
//   由 scripts/golden/gen_wave_fir.py 生成。
//   改抽头数 / 截止频率 -> 改脚本里的 CHOSEN_N / CHOSEN_FC，然后重新 --emit。
//
//   设计：{n} 抽头、**线性相位（系数对称）**、Hamming 窗加窗 sinc 低通
//         截止 {fc:.3f}*fs = {fc*48000:.0f} Hz @48kHz
//   格式：Q2.16（18 位有符号），和 EQ 用同一套格式
//   系数和 = {sum(q)}（理想 65536）-> 直流增益误差 {20*__import__('math').log10(sum(q)/65536):+.5f} dB，可忽略
//
//   ⚠️ 只存了【前一半 + 中心】，共 {half+1} 个。对称 FIR 的后一半是镜像，
//      不必存 —— 这是省一半 ROM 和一半乘法器的关键。
//=============================================================================

    localparam integer FIR_N    = {n};      // 抽头数（奇数）
    localparam integer FIR_M    = {half};      // (N-1)/2，配对个数
    localparam integer FIR_CW   = {cw};     // 系数位宽

    // 系数查询。idx 在展开的循环里都是常数 -> 综合器直接折叠掉，不占资源。
    function signed [FIR_CW-1:0] fir_coef;
        input [3:0] idx;
        begin
            case (idx)
{chr(10).join(rows)}
                default: fir_coef = 18'sd0;
            endcase
        end
    endfunction
"""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    out = os.path.join(root, "rtl", "common", "fir_sym_coeff.vh")
    with open(out, "w", encoding="utf-8") as f:
        f.write(src)
    print(f"\n  已写出 {out}")


if __name__ == "__main__":
    for n, fc in CANDIDATES:
        show(n, fc)
    q = show(CHOSEN_N, CHOSEN_FC)
    print(f"\n  >>> 选中 N={CHOSEN_N}, fc={CHOSEN_FC}")
    if "--emit" in sys.argv:
        emit(q, CHOSEN_N, CHOSEN_FC)
