#!/usr/bin/env python3
"""
gen_all.py - 生成仿真向量与系数 ROM

产物：
    sim/vectors/eq_coeff.hex    25 个 18bit 系数（5 段 x {b0,b1,b2,a1,a2}）
    sim/vectors/eq_in.hex       输入样本（24bit signed hex）
    sim/vectors/eq_out.hex      黄金模型输出（24bit signed hex）
    sim/vectors/eq_meta.txt     元信息（段数、样本数、增益配置）
    rtl/audio/eq_coeff_rom.v    5 段 x 21 增益档 x 5 系数的只读系数表

用法：
    python3 scripts/golden/gen_all.py
"""

from __future__ import annotations

import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from dsp import (  # noqa: E402
    BANDS_HZ, DW, CW, CF, FS, GAIN_MIN_DB, NGAIN, Cascade,
    design_band, gain_db_of, quant_coef, coeff_table_preset,
    SAMPLE_MAX, SAMPLE_MIN, check_coef_range, response_db,
)

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
VEC_DIR = os.path.join(ROOT, "sim", "vectors")
RTL_DIR = os.path.join(ROOT, "rtl", "audio")


def h(value: int, bits: int) -> str:
    return format(value & ((1 << bits) - 1), "0%dx" % ((bits + 3) // 4))


# ---------------------------------------------------------------------------
# 1. 测试向量
# ---------------------------------------------------------------------------
def make_input(n: int) -> list[int]:
    """三段式输入：冲激响应 / 多音信号 / 满量程方波（压饱和）。"""
    seg = n // 3
    xs: list[int] = []

    # 段1：冲激（检验每个 section 的极点/零点实现）
    for i in range(seg):
        xs.append(SAMPLE_MAX // 2 if i == 0 else 0)

    # 段2：多音叠加（100/1000/8000 Hz），幅度 1/4 满量程
    tones = [100.0, 1000.0, 8000.0]
    for i in range(seg):
        v = 0.0
        for f in tones:
            v += math.sin(2 * math.pi * f * i / FS)
        xs.append(int(round(v / len(tones) * 0.25 * SAMPLE_MAX)))

    # 段3：满量程方波（1 kHz），两段之间夹极值，专门触发饱和分支
    for i in range(n - 2 * seg):
        v = SAMPLE_MAX if ((i * 1000) // int(FS)) % 2 == 0 else SAMPLE_MIN
        xs.append(v)

    return xs


def gen_vectors():
    os.makedirs(VEC_DIR, exist_ok=True)

    # 演示用增益配置：低音 +6dB，中低 -3dB，中频 0dB，中高 +4dB，高音 -6dB
    gain_db = [6.0, -3.0, 0.0, 4.0, -6.0]
    gain_idx = [int(round((g - GAIN_MIN_DB))) for g in gain_db]
    assert all(0 <= g < NGAIN for g in gain_idx), gain_idx

    table = coeff_table_preset(gain_idx)
    casc = Cascade.from_coeff_table(table)

    n = 6000
    xs = make_input(n)
    ys = casc.process(xs)

    with open(os.path.join(VEC_DIR, "eq_coeff.hex"), "w") as f:
        for sec in table:
            for c in sec:
                f.write(h(quant_coef(c), CW) + "\n")

    with open(os.path.join(VEC_DIR, "eq_in.hex"), "w") as f:
        for v in xs:
            f.write(h(v, DW) + "\n")

    with open(os.path.join(VEC_DIR, "eq_out.hex"), "w") as f:
        for v in ys:
            f.write(h(v, DW) + "\n")

    with open(os.path.join(VEC_DIR, "eq_meta.txt"), "w") as f:
        f.write("NSECT=5 NSAMP=%d DW=%d CW=%d\n" % (n, DW, CW))
        f.write("gain_db=" + ",".join("%.1f" % g for g in gain_db) + "\n")
        f.write("gain_idx=" + ",".join(str(g) for g in gain_idx) + "\n")

    # 定点 vs 浮点频响对比
    lim, bad = check_coef_range(table)
    if bad:
        raise SystemExit("系数超出 Q2.16 范围 [-%g, %g)：%s" % (lim, lim, bad))

    freqs = [20, 50, 100, 300, 1000, 3000, 8000, 12000, 20000]
    f_fixed = response_db(table, freqs, fixed=True)
    f_float = response_db(table, freqs, fixed=False)
    print("  频点(Hz) :", "  ".join("%8d" % f for f in freqs))
    print("  浮点(dB) :", "  ".join("%+8.3f" % v for v in f_float))
    print("  定点(dB) :", "  ".join("%+8.3f" % v for v in f_fixed))
    err = max(abs(a - b) for a, b in zip(f_fixed, f_float))
    print("  最大定点误差: %.4f dB  (系数范围 |c| < %g, 满量程 %.4f)" %
          (err, lim, max(abs(c) for s in table for c in s)))
    if err > 0.1:
        raise SystemExit("定点误差 %.3f dB 过大，检查系数格式" % err)
    return n


# ---------------------------------------------------------------------------
# 2. 系数 ROM
# ---------------------------------------------------------------------------
ROM_HEADER = """//=============================================================================
// eq_coeff_rom.v - 均衡器系数表（**本文件由 scripts/golden/gen_all.py 自动生成**）
//-----------------------------------------------------------------------------
// 结构：{频段, 增益档} -> 该段双二阶的 5 个系数 {b0,b1,b2,a1,a2}
//   频段 : 0..%d 对应 %s Hz
//   增益 : 0..%d 对应 %.1f .. %.1f dB，步进 1.0 dB
//   地址 : (band*%d + gain)*5 + k
//
// 系数格式：18bit signed Q2.16（范围 [-2,2)，分辨率 1.5e-5）
//   —— 不能用 Q1.17，低架滤波器的 b1 会超过 -1 被削顶。
//
// 为什么用 ROM 表而不是片上实时计算系数：
//   实时计算需要 sin/cos/sqrt/除法，定点误差难以控制；离线用 Python 高精度算好后
//   量化到 Q1.17，片上只需一次查表 + 5 次寄存器写，零 DSP、零精度风险。
//=============================================================================
`timescale 1ns/1ps

module eq_coeff_rom (
    input  wire [%d:0] addr,
    output reg  signed [%d:0] dout
);

    always @* begin
        case (addr)
"""


def gen_rom():
    nband = len(BANDS_HZ)
    entries = nband * NGAIN
    total = entries * 5
    aw = max(1, (total - 1).bit_length())

    lines = [ROM_HEADER % (
        nband - 1,
        "/".join("%g" % f for f in BANDS_HZ),
        NGAIN - 1,
        GAIN_MIN_DB, GAIN_MIN_DB + (NGAIN - 1),
        NGAIN,
        aw - 1, CW - 1,
    )]

    lim, bad = check_coef_range(
        [design_band(b, g) for b in range(nband) for g in range(NGAIN)]
    )
    if bad:
        raise SystemExit("ROM 中有系数超出 Q2.16 范围：%s" % bad[:5])

    for band in range(nband):
        for gi in range(NGAIN):
            sec = design_band(band, gi)
            q = [quant_coef(c) for c in sec]
            base = (band * NGAIN + gi) * 5
            lines.append("            // band=%d (%gHz) gain=%+.1fdB\n"
                         % (band, BANDS_HZ[band], gain_db_of(gi)))
            for k in range(5):
                a = base + k
                lines.append("            %d'd%d: dout = 18'sh%s;\n"
                             % (aw, a, h(q[k], CW)))

    lines.append("            default: dout = 18'sh00000;\n")
    lines.append("        endcase\n    end\n\nendmodule\n")

    path = os.path.join(RTL_DIR, "eq_coeff_rom.v")
    with open(path, "w") as f:
        f.write("".join(lines))
    print("  已生成 %s（%d 项 x 5 系数 = %d 个常量）" % (path, entries, total))


# ---------------------------------------------------------------------------
# 3. audio_top 端到端测试用的冲激响应参考
# ---------------------------------------------------------------------------
def gen_ir():
    """生成 EQ 的冲激响应参考 + 频段增益档位，供 tb_audio_top 使用。

    输入：单个半量程冲激，其后全零（与 testbench 完全一致）。
    """
    gain_db = [6.0, -3.0, 0.0, 4.0, -6.0]
    gain_idx = [int(round((g - GAIN_MIN_DB))) for g in gain_db]

    imp = 1 << 22                     # 半量程冲激 = 4194304
    n = 256
    xs = [imp] + [0] * (n - 1)

    table = coeff_table_preset(gain_idx)
    ys = Cascade.from_coeff_table(table).process(xs)

    with open(os.path.join(VEC_DIR, "ir_ref.hex"), "w") as f:
        for v in ys:
            f.write(h(v, DW) + "\n")

    with open(os.path.join(VEC_DIR, "ir_meta.txt"), "w") as f:
        f.write("imp=%d n=%d\n" % (imp, n))
        f.write("band_gain=" + ",".join(str(g) for g in gain_idx) + "\n")

    # 把 5 个档位打包成一个 25bit 常量，供 testbench 直接赋值
    packed = 0
    for b, g in enumerate(gain_idx):
        packed |= (g & 0x1F) << (b * 5)
    print("  IR 参考: %d 点, 首值 %d, band_gain 打包 = 25'h%07x" % (n, ys[0], packed))
    print("  band_gain 端口应赋值: 25'd%d" % packed)
    return packed


def gen_wm8960():
    """调用 WM8960 寄存器表生成器（--write 才会真正写文件）。

    ⚠️ 这个生成器以前【不在】gen_all 里 —— 于是"跑 gen_all 就全都生成好了"
       是个错觉：改了 WM8960 的表，直接跑 gen_all 不会重新生成，
       而 rtl/wm8960/WM8960_init_table.v 静静地保持着旧版本，
       编译照过、上板就是不对。（和账本第 48 条"旧报告冒充新报告"同族。）

    ⚠️ 另外注意它需要 **--write**，不加只打印预览。
       第一次加寄存器时就是漏了这个参数，白跑一趟。
    """
    import subprocess
    here = os.path.dirname(os.path.abspath(__file__))
    r = subprocess.run(
        [sys.executable, os.path.join(here, "gen_wm8960_table.py"), "--write"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        raise SystemExit("gen_wm8960_table.py 失败：\n" + r.stderr)
    # 它的 stderr 里是 Markdown 表格（给 docs/09 抄的），这里只挑第一行状态
    for ln in r.stderr.splitlines():
        if ln.startswith("已写入"):
            print("  " + ln)
            break
    else:
        raise SystemExit("gen_wm8960_table.py 没有报告写入，可能参数不对")


def main():
    print("[1/4] 生成测试向量 ...")
    gen_vectors()
    print("[2/4] 生成系数 ROM ...")
    gen_rom()
    print("[3/4] 生成冲激响应参考 ...")
    gen_ir()
    print("[4/4] 生成 WM8960 初始化寄存器表 ...")
    gen_wm8960()
    print("完成。")


if __name__ == "__main__":
    main()
