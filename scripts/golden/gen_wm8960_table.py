#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
gen_wm8960_table.py —— 生成 WM8960 初始化寄存器表

为什么要用脚本生成而不是手写：
    每条寄存器要同时出现在三个地方，手算极易出错
      ① Verilog 表：{7'h寄存器, 9'b数据}
      ② I2C 字节对：16 位字拆成两个字节发出（高字节 = {reg[6:0], data[8]}）
      ③ 文档表格
    这三个我都手算错过（把 reg<<9 写成了 reg<<8，还把 SDM 位写反）。
    改成脚本后只要维护上面那张 (reg, data, 注释) 表，三处输出自动一致。

输出：
    rtl/wm8960/WM8960_init_table.v     （--write 时覆盖）
    标准输出                            （文档用的 Markdown 表格）
"""
import sys, os

# =============================================================================
# 寄存器表： (寄存器地址, 9 位数据, 说明)
# -----------------------------------------------------------------------------
# 数据来源：docs/WM8960模块/WM8960_v4.2.pdf  Table 39/40/41/44/45 + P57~61 位域表
# 关键推导见 docs/09-wm8960-module.md §2.5
# =============================================================================
SPEC = [
    # 注释全部用短 ASCII —— 中文说明放在生成文件的头部。
    # 原因是 Verible 的行宽按终端列数算，CJK 字符通常占 2 列，
    # 用 Python len() 无法准确预估，干脆避免。
    # (寄存器地址, 9 位数据, 短注释)
    (0x0F, 0x000, "software reset (must be 1st)"),
    (0x19, 0x1FC, "PWRMGMT1: VMIDSEL=11 VREF AINL AINR"),

    #------------------------------------------------------------------------
    # ★★★ 输入通路：原来【漏掉了这 4 条】，是"说话没反应"的根因 ★★★
    #------------------------------------------------------------------------
    #  R32/R33 = ADC 输入选择。板载话筒接在 LINPUT1（见模块原理图：
    #      MIC1(AOS3729A) -> L1 磁珠 -> C15(10uF 交流耦合) -> INPUT_L1 -> LINPUT1）。
    #      datasheet §"Input Signal Path"：
    #        "In single-ended microphone input configuration the microphone signal
    #         should be input to LINPUT1 or RINPUT1 and the internal non-inverting
    #         input of the input PGA should be switched to VMID."
    #      -> 单端配置就是 LMN1=1 / LMP2=LMP3=0（**这正是 R32 的复位默认值**）。
    #      这里显式写出来，一是为了"配置是自解释的"，二是为了设 LMICBOOST。
    #
    #  R0/R1 = 输入 PGA 音量。**复位默认值里 LINMUTE/RINMUTE = 1，也就是出厂静音！**
    #      datasheet R0 bit7 原文："LINMUTE  DEFAULT 1  1 = Enable Mute"，
    #      并注明 "IPVU must be set to un-mute"。
    #      -> 不写这两条，ADC 永远在转换静音：波形是直的、柱状谱一根都没有。
    #      （这一条是上板实测"说话无反应"的直接原因。）
    #
    #  增益怎么定：板载模拟 MEMS 话筒灵敏度约 -38 dBV/Pa，正常说话到它那儿
    #      只有零点几 mV，而 WM8960 输入满量程约 1 Vrms -> 差着 60 dB 以上。
    #      所以 PGA 内部 boost +20dB、音量 +24dB，合计约 +44dB。
    #      增益不够时先加大这两个，不要先怀疑接线。
    #------------------------------------------------------------------------
    (0x20, 0x120, "ADCL path: LINPUT1 single-ended, PGA boost +20dB"),
    (0x21, 0x120, "ADCR path: RINPUT1 single-ended, PGA boost +20dB"),
    (0x00, 0x137, "L in PGA: IPVU=1 LINMUTE=0 LINVOL +24dB"),
    (0x01, 0x137, "R in PGA: IPVU=1 RINMUTE=0 RINVOL +24dB"),
    (0x2F, 0x00C, "PWRMGMT3: LOMIX ROMIX"),
    (0x1A, 0x1E0, "PWRMGMT2: DACL DACR LOUT1 ROUT1"),
    (0x08, 0x1C4, "CLOCKING2: BCLKDIV=0100 (/4)"),
    (0x07, 0x04A, "IFACE1: MS=1 I2S 24bit"),
    (0x34, 0x038, "PLL N: PRESCALE=1 SDM=1 N=8"),
    (0x35, 0x031, "PLL K[23:16]"),
    (0x36, 0x026, "PLL K[15:8]"),
    (0x37, 0x0E9, "PLL K[7:0] -> K=0x3126E9"),
    (0x1A, 0x1E1, "PWRMGMT2 + PLLEN=1 -> PLL ON"),
    (0x02, 0x1F9, "LOUT1 vol +0dB"),
    (0x03, 0x1F9, "ROUT1 vol +0dB"),
    (0x15, 0x1C3, "L ADC vol 0dB"),
    (0x16, 0x1C3, "R ADC vol 0dB"),
    (0x2D, 0x080, "L mixer bypass 0dB"),
    (0x2E, 0x080, "R mixer bypass 0dB"),
    (0x2B, 0x150, "L input boost LIN3 = 0dB"),
    (0x2C, 0x00A, "R input boost RIN2 = 0dB"),
    (0x04, 0x005, "CLOCKING1: SYSCLKDIV=/2 CLKSEL=PLL"),
]

# 参考工程的表（用来对比差异，只做展示）
REF = {
    0x0F: 0x000, 0x19: 0x1FC, 0x1A: 0x060, 0x2F: 0x00C, 0x04: 0x000,
    0x07: 0x04A, 0x02: 0x1F9, 0x03: 0x1F9, 0x15: 0x1C3, 0x16: 0x1C3,
    0x2D: 0x080, 0x2E: 0x080, 0x2B: 0x150, 0x2C: 0x00A,
}


def word(reg, dat):
    """拼成 WM8960 的 16 位字：[15:9] 7 位寄存器地址，[8:0] 9 位数据"""
    assert 0 <= reg <= 0x7F, f"寄存器地址越界: {reg:#x}"
    assert 0 <= dat <= 0x1FF, f"数据越界: {dat:#x}"
    return (reg << 9) | dat


def bin9(dat):
    """9 位二进制，4+5 分组便于阅读"""
    b = format(dat, '09b')
    return b[0] + '_' + b[1:5] + '_' + b[5:]


def hex7(reg):
    return format(reg, '02x')


# -----------------------------------------------------------------------------
# 输出 1：Verilog ROM
# -----------------------------------------------------------------------------
def gen_verilog():
    n = len(SPEC)
    aw = max(1, (n - 1).bit_length())        # 装得下 n 条即可
    lines = []
    A = lines.append

    A("//=============================================================================")
    A("// WM8960_init_table.v - WM8960 初始化寄存器表")
    A("//-----------------------------------------------------------------------------")
    A("// ⚠️ 本文件由 scripts/golden/gen_wm8960_table.py 自动生成，请勿手工修改。")
    A("//    要改寄存器值请编辑脚本里的 SPEC 表然后重新生成。")
    A("//")
    A("// 数据来源：docs/WM8960模块/WM8960_v4.2.pdf")
    A("//   Table 39/40/41/44/45 + 寄存器位域表（P57~61）")
    A("//   推导过程见 docs/09-wm8960-module.md §2.5")
    A("//")
    A("// 表项格式：{7 位寄存器地址, 9 位数据}")
    A("//   WM8960 的 2-wire 协议是 16 位字：[15:9]=寄存器地址，[8:0]=数据。")
    A("//   I2C 按字节发，所以高字节 = {reg[6:0], data[8]}、低字节 = data[7:0]。")
    A("//   这就是 WM8960_init.v 里 `addr = lut[15:8]` / `wrdata = lut[7:0]` 的由来 ——")
    A("//   9 位数据的最高位藏在 addr 的 bit0 里，不是被截断。")
    A("//")
    A("// 【本表在做什么】")
    A("//   R15  软复位（必须第一条）")
    A("//   R25  PWRMGMT1：VMIDSEL=11(快速启动) + VREF/AINL/AINR/ADCL/ADCR 上电")
    A("//   R47  PWRMGMT3：LOMIX/ROMIX（播放混音器）")
    A("//   R26  PWRMGMT2：DACL/DACR/LOUT1/ROUT1 上电（此刻 PLLEN 还是 0）")
    A("//   R8   CLOCKING2：BCLKDIV=0100 -> BCLK = SYSCLK/4")
    A("//   R7   IFACE1：MS=1（WM8960 当 I2S 主）、WL=24bit、I2S 格式")
    A("//   R52~R55 PLL：PRESCALE=1(24MHz/2=12MHz 进 PLL)、SDM=1(分数模式)、")
    A("//           N=8、K=0x3126E9  ->  f2=98.304MHz，SYSCLK=12.288MHz")
    A("//   R26  再写一次，加上 PLLEN=1  <-- PLL 从这里开始锁定")
    A("//   R2/R3/R21/R22/R45/R46/R43/R44  各路音量与混音，顺便等 PLL 锁好")
    A("//   R4   CLOCKING1：SYSCLKDIV=/2 + CLKSEL=1  <-- 最后一步才切到 PLL")
    A("//")
    A("// 【顺序不能随便改】：")
    A("//   · 软复位必须第一条")
    A("//   · PLL 配置(K/N/PRESCALE)必须在 PLLEN 之前")
    A("//   · CLKSEL=1 必须最后 —— 切过去之前要给 PLL 留够锁定时间")
    A("//     （由 WM8960_init.v 的 DLY_MS 参数保证，每条之间留 1 ms）")
    A("//=============================================================================")
    A("`timescale 1ns/1ps")
    A("")
    A("module WM8960_init_table #(")
    A("    parameter DATA_WIDTH = 16,")
    A(f"    parameter ADDR_WIDTH = {aw}          // 装得下 {n} 条即可")
    A(") (")
    A("    input      [(ADDR_WIDTH-1):0] addr,")
    A("    input                         clk,")
    A("    output reg [(DATA_WIDTH-1):0] q")
    A(");")
    A("")
    A(f"    localparam LUT_SIZE = {n};")
    A("    reg [DATA_WIDTH-1:0] rom [0:(2**ADDR_WIDTH)-1];")
    A("")
    A("    initial begin")
    for i, (reg, dat, cmt) in enumerate(SPEC):
        pad = " " * (len(str(n)) - len(str(i)))
        A(f"        rom[{pad}{i}] = {{7'h{hex7(reg)}, 9'b{bin9(dat)}}};  // {cmt}")
    A("    end")
    A("")
    A("    // 读端口（综合成分布式 ROM）")
    A("    always @(posedge clk) begin")
    A("        q <= rom[addr];")
    A("    end")
    A("")
    A("endmodule")

    # 生成的内容必须满足 Verible 的 100 字符行宽，否则 lint 会报一堆告警
    long_lines = [(i + 1, len(l)) for i, l in enumerate(lines) if len(l) > 100]
    assert not long_lines, f"以下行超过 100 字符，请缩短 SPEC 注释: {long_lines}"
    return "\n".join(lines) + "\n", n, aw


# -----------------------------------------------------------------------------
# 输出 2：Markdown 表格（贴进 docs/09）
# -----------------------------------------------------------------------------
def gen_markdown():
    out = []
    A = out.append
    A("| # | 寄存器 | 9 位数据 | 16 位字 | I2C 字节 | 说明 |")
    A("| --- | --- | --- | --- | --- | --- |")
    for i, (reg, dat, cmt) in enumerate(SPEC):
        W = word(reg, dat)
        hi, lo = (W >> 8) & 0xFF, W & 0xFF
        A(f"| {i} | R{reg} ({hex7(reg).upper()}h) | `{bin9(dat)}` | 0x{W:04X} | `{hi:02X} {lo:02X}` | {cmt} |")
    return "\n".join(out)


# -----------------------------------------------------------------------------
if __name__ == '__main__':
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
    verilog, n, aw = gen_verilog()

    write = '--write' in sys.argv
    if write:
        dst = os.path.join(root, 'rtl', 'wm8960', 'WM8960_init_table.v')
        open(dst, 'w', encoding='utf-8').write(verilog)
        print(f"已写入 {dst}   （{n} 条，ADDR_WIDTH={aw}）", file=sys.stderr)

        # ★ 额外产出"条数"的共享头文件。
        #   以前 WM8960_init.v 里自己写死了一个 LUT_SIZE=20，表里是 24，
        #   两处各自为政 —— 加寄存器时表变了、状态机没变，
        #   结果只发出前 20 条，而且报错是"最后一条不是 R4"，很难看出真正原因。
        #   现在统一 include 这一份，改表就自动跟着变。
        nreg = os.path.join(root, 'rtl', 'wm8960', 'wm8960_nreg.vh')
        with open(nreg, 'w', encoding='utf-8') as f:
            f.write("//=============================================================================\n")
            f.write("// wm8960_nreg.vh - 初始化寄存器表的【条数】（**自动生成，不要手改**）\n")
            f.write("//-----------------------------------------------------------------------------\n")
            f.write("//   由 scripts/golden/gen_wm8960_table.py 生成。\n")
            f.write("//   需要\u3010表有几条\u3011的地方就 include 它，别再自己写一个数\n")
            f.write("//   两处各写一个的话迟早会分家（这个文件就是因为分家才出现的）。\n")
            f.write("//=============================================================================\n\n")
            f.write(f"localparam integer WM8960_NREG = {n};\n")
        print(f"已写入 {nreg}   （WM8960_NREG={n}）", file=sys.stderr)
    else:
        print("--- Verilog 预览（未写入，加 --write 才写） ---")
        print(verilog)

    print("\n\n--- Markdown（docs/09 用） ---", file=sys.stderr)
    print(gen_markdown(), file=sys.stderr)

    # 与参考工程的差异
    print("\n\n--- 与 Music-Spectrum 参考表的差异 ---", file=sys.stderr)
    ours = {reg: dat for reg, dat, _ in SPEC}
    for reg in sorted(set(ours) | set(REF)):
        a, b = REF.get(reg), ours.get(reg)
        if a != b:
            sa = "未写" if a is None else f"{a:#05x}"
            sb = "未写" if b is None else f"{b:#05x}"
            print(f"  R{reg:02X}: 参考 {sa:>7s}  ->  我们 {sb}", file=sys.stderr)
