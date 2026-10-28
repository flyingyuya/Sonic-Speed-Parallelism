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
    #=========================================================================
    # ★ 2026-10 按【官方 C 例程】重写（Open103Z_I2S/WM8960_Record）
    #=========================================================================
    #   官方例程（board mic）的关键配置：
    #     R25(19h)=0x0E8   R26(1A)=0x1F8   R47(2F)=0x03C
    #     R4 (04h)=0x000   R7 (07h)=0x002   R0/R1=0x13F
    #     R20(20h)=0x108   R21(21h)=0x000   R43/R44=0x000
    #     R5 (05h)=0x00C   R21/R22(15/16)=0x1C3   R23(17h)=0x1C4
    #     R49(31h)=0x0F7   ← "Enable Left and right speakers"
    #
    #   ★★ 三个我们原来【漏掉/配错】的致命项 ★★
    #
    #   ① R32 (20h)：**必需 LMIC2B = 1**（bit3）
    #        "Connect Left Input PGA to Left Input Boost Mixer"
    #        WM8960 的 ADC 输入取的是【输入 Boost 混音器的输出】，
    #        不是直接取 PGA。LMIC2B=0 -> PGA 的输出进不去 -> ADC 恒为 0。
    #        -> 这就是我们读到"±256 / -90dBFS 数字静音"的真正原因。
    #        官方值 0x108 = LMN1=1(LINPUT1) + LMICBOOST=00 + 【LMIC2B=1】
    #        （我们上一版写 0x130，boost=11 但 LMIC2B=0，正好踩坑）
    #
    #   ② R26 (1Ah)：**必需 SPKL/SPKR**（bit4/bit3）
    #        官方 0x1F8 = DACL DACR LOUT1 ROUT1 **SPKL SPKR**
    #        （我们原来 0x1E1 没有喇叭位 -> 喇叭永远不响）
    #
    #   ③ R49 (31h) = 0x0F7 【类 D 功放的控制寄存器，我们完全没写过】
    #        官方注释原文："Analogue Output Control / Enable Left and right speakers"
    #
    #   ⚠️ 保留我们自己的：
    #     · PLL（本模块是 24MHz 晶振 + 我们让 WM8960 当 I2S 主）
    #     · 24bit 字长（官方是 16bit 从模式 + MCU 提供 MCLK，和我们的板子不同）
    #     · 寄存器顺序（CLKSEL=1 必须最后）
    #=========================================================================
    (0x0F, 0x000, "software reset (must be 1st)"),

    # PWRMGMT1: VMIDSEL=01 VREF AINL AINR ADCL ADCR MICB DIGENB
    #   我们保留 MICB=1（本模块话筒由 VCC_3V3 供电，MICBIAS 接不接都行）
    (0x19, 0x0FE, "PWRMGMT1: VMIDSEL=01 VREF AINL AINR ADCL ADCR MICB=1"),

    # PWRMGMT3: LOMIX ROMIX LMIC RMIC（官方 0x03C 全开）
    #   LMIC/RMIC = 左右输入 Boost 混音器使能，**不打开的话 ADC 也是死的**
    (0x2F, 0x03C, "PWRMGMT3: LOMIX ROMIX LMIC RMIC"),

    # ★ DAC -> 输出混音器（默认断开）
    (0x22, 0x100, "L out mixer: LD2LO=1 (DAC -> L mixer)"),
    (0x25, 0x100, "R out mixer: RD2RO=1 (DAC -> R mixer)"),

    # ★ PWRMGMT2: 含 SPKL/SPKR（喇叭）—— 官方 0x1F8 的关键就在这两位
    (0x1A, 0x1E0, "PWRMGMT2: DACL DACR LOUT1 ROUT1 SPKL SPKR"),

    (0x08, 0x1C4, "CLOCKING2: BCLKDIV=0100 (/4)"),
    (0x07, 0x04A, "IFACE1: MS=1 I2S 24bit"),

    (0x34, 0x038, "PLL N: PRESCALE=1 SDM=1 N=8"),
    (0x35, 0x031, "PLL K[23:16]"),
    (0x36, 0x026, "PLL K[15:8]"),
    (0x37, 0x0E9, "PLL K[7:0] -> K=0x3126E9"),
    (0x1A, 0x1F9, "PWRMGMT2 + PLLEN=1 -> PLL ON (SPKL/SPKR kept)"),

    # ★★ 输入通路：LINPUT1 + 【LMIC2B=1】★★
    (0x20, 0x118, "ADCL path: LINPUT1 + LMIC2B=1 + PGA boost 13dB"),
    (0x21, 0x000, "ADCR path: off (mono mic, DATSEL copies L to R)"),

    # ★ DATSEL=01：单声道话筒数据复制到左右两路（官方 0x1C4）
    (0x17, 0x1C4, "R23: TSDEN=1, DATSEL=01 (left ADC -> L and R)"),

    # Input PGA：IPVU=1 LINMUTE=0 ＋ 【0dB】
    #   官方用 +30dB -> 那是给它那颗【驻极体】话筒的（灵敏度低）。
    #   我们板上是 MEMS 话筒（AOS3729A-T42）✗ 灵敏度高得多 ✗
    #   照抄 +30dB 的实测现象是："不说话也有一大片噪声 ✗ 波形几乎失真 ✗
    #   频谱全频段都是高柱子" —— 底噪被放大了 30dB，把信号淹掉了。
    #   正确做法：**模拟增益只给够 ✗ 剩下在数字域补**（显示侧的 G 命令能到 x256，
    #   数字域放大不引入模拟噪声）。所以这里先用 0dB，需要时按 G 加大。
    # Input PGA：IPVU=1 LINMUTE=0 ＋ 【+12dB】
    #   ⚠️ 模拟增益要给够！之前"加大模拟增益就一片噪声"的结论是【无效的】——
    #      那是接收器还坏着的时候测的。接收器修好之后重新调：
    #      0 dB  -> 波形几乎不动，必须靠 G 放大
    #      +12dB -> 要 G05（数字 x32）才看得清
    #      但【数字域放大会把噪声一起放大，触发点每次落在不同采样上，
    #      屏幕上会出现"两条线"在动】—— 这是触发抖动的典型表现。
    #      正确做法：模拟增益给够，数字侧 G 只做微调。
    #
    #   【2026-10 微调】+37 -> +31 -> **+25dB**（boost +13 + LINVOL +12）。
    #      用户的取舍：增益越高频谱越"不干净"（房间底噪被抬起来），
    #      但增益太低又得靠数字 G 补 -> 触发抖（屏幕上"两条线"）。
    #      +25dB 配合默认 G02（数字 x4）是实测最舒服的点。
    #      ⚠️ 这是【真实的权衡】，不是配错了：
    #        模拟增益抬高，信号和【话筒自噪 + 环境噪声】一起抬高；
    #        而 ADC 的量化噪声是固定的 -> SNR 会变好，但屏幕上"能看见的东西"
    #        也变多了（连房间底噪都看得见）。所以存在一个最舒服的点，
    #        要按实际环境试。可选的 boost 档只有 0/13/20/29 dB，
    #        细调靠 LINVOL（0.75dB 一档）。
    (0x00, 0x127, "L in PGA: IPVU=1 LINMUTE=0 LINVOL +12dB"),
    (0x01, 0x127, "R in PGA: IPVU=1 RINMUTE=0 RINVOL +12dB"),

    # 输入 boost 混音器：官方不 boost（0x000）
    (0x2B, 0x000, "L input boost: 0dB"),
    (0x2C, 0x000, "R input boost: 0dB"),

    # ★★ R5 (05h)：DACMU 必须 = 0，否则 DAC 一直静音 ★★
    #   datasheet 原文（P41）："The DAC is soft-muted by default. To play back
    #   an audio signal, this function must first be disabled by setting the
    #   DACMU bit to zero."
    #     bit3 DACMU  默认 1 -> 【出厂静音】
    #     bit0 ADCHPD 默认 0 -> ADC 高通【开启】（这正是我们要的，去直流）
    #   ⚠️ 官方例程写两条：先 0x00C（配 HPF/去加重）再 0x0000（解静音）。
    #      我上一版只抄了第一条 -> DACMU 一直是 1 -> DAC 永远静音。
    #      这就是"喇叭/耳机接了也没声音"的直接原因。
    (0x05, 0x000, "R5: DACMU=0 (unmute DAC!), ADCHPD=0 (ADC HPF on)"),

    (0x15, 0x1C3, "L ADC digital vol 0dB"),
    (0x16, 0x1C3, "R ADC digital vol 0dB"),
    (0x0A, 0x1FF, "L DAC digital vol 0dB (update)"),
    (0x0B, 0x1FF, "R DAC digital vol 0dB (update)"),

    (0x02, 0x1F9, "LOUT1 vol +0dB"),
    (0x03, 0x1F9, "ROUT1 vol +0dB"),
    (0x2D, 0x080, "L mixer bypass 0dB"),
    (0x2E, 0x080, "R mixer bypass 0dB"),

    # ★★ R49 (31h)：类 D 功放控制 —— 官方原文 "Enable Left and right speakers" ★★
    (0x31, 0x0F7, "ClassD ctl: enable speakers"),

    # ★★★ R40/R41：左右【喇叭音量】★★★
    #   datasheet 原文（R40 28h 的 SPKLVOL[6:0]）：
    #       1111111 = +6dB ... 0110000 = -73dB
    #       0101111 到 0000000 = 【Analogue MUTE】
    #   复位默认值是 0000000，正好落在 MUTE 区间 => 喇叭出厂就是静音的。
    #
    #   ⚠️ 这一条以前【一直漏着】，而且它的症状极具迷惑性：
    #       · 上电时喇叭会"噗"一声（功放和喇叭都是好的）
    #       · 但任何音频都出不来
    #       · 而且 T08（走 top.v 里另一个 i2s_tx）和新的 i2s_bclk_if 都试过，
    #         两条完全独立的发送路径都不响 -> 说明公共环节不是"发送"
    #   => 遇到"两条独立通路都不工作"，要去找它们的【公共下游】
    #      （这里是 WM8960 的音量/静音位），而不是继续怀疑上游。
    #
    #   值 0x17F = SPKVU(bit8)=1 更新 + SPKLVOL=1111111 (+6dB)
    #   （官方放音例程就是 0x007F | 0x0100）
    (0x28, 0x17F, "L spk vol: SPKVU=1 +6dB (rst=MUTE)"),
    (0x29, 0x17F, "R spk vol: SPKVU=1 +6dB (rst=MUTE)"),

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

    # A("//=============================================================================")
    # A("// WM8960_init_table.v - WM8960 初始化寄存器表")
    # A("//-----------------------------------------------------------------------------")
    # A("// 本文件由 scripts/golden/gen_wm8960_table.py 自动生成")
    # A("//    要改寄存器值请编辑脚本里的 SPEC 表然后重新生成。")
    # A("//")
    # A("// 数据来源：docs/WM8960模块/WM8960_v4.2.pdf")
    # A("//   Table 39/40/41/44/45 + 寄存器位域表（P57~61）")
    # A("//   推导过程见 docs/09-wm8960-module.md §2.5")
    # A("//")
    # A("// 表项格式：{7 位寄存器地址, 9 位数据}")
    # A("//   WM8960 的 2-wire 协议是 16 位字：[15:9]=寄存器地址，[8:0]=数据。")
    # A("//   I2C 按字节发，所以高字节 = {reg[6:0], data[8]}、低字节 = data[7:0]。")
    # A("//   这就是 WM8960_init.v 里 `addr = lut[15:8]` / `wrdata = lut[7:0]` 的由来 ——")
    # A("//   9 位数据的最高位藏在 addr 的 bit0 里，不是被截断。")
    # A("//")
    # A("// 【本表在做什么】")
    # A("//   R15  软复位（必须第一条）")
    # A("//   R25  PWRMGMT1：VMIDSEL=11(快速启动) + VREF/AINL/AINR/ADCL/ADCR 上电")
    # A("//   R47  PWRMGMT3：LOMIX/ROMIX（播放混音器）")
    # A("//   R26  PWRMGMT2：DACL/DACR/LOUT1/ROUT1 上电（此刻 PLLEN 还是 0）")
    # A("//   R8   CLOCKING2：BCLKDIV=0100 -> BCLK = SYSCLK/4")
    # A("//   R7   IFACE1：MS=1（WM8960 当 I2S 主）、WL=24bit、I2S 格式")
    # A("//   R52~R55 PLL：PRESCALE=1(24MHz/2=12MHz 进 PLL)、SDM=1(分数模式)、")
    # A("//           N=8、K=0x3126E9  ->  f2=98.304MHz，SYSCLK=12.288MHz")
    # A("//   R26  再写一次，加上 PLLEN=1  <-- PLL 从这里开始锁定")
    # A("//   R2/R3/R21/R22/R45/R46/R43/R44  各路音量与混音，顺便等 PLL 锁好")
    # A("//   R4   CLOCKING1：SYSCLKDIV=/2 + CLKSEL=1  <-- 最后一步才切到 PLL")
    # A("//")
    # A("// 【顺序不能随便改】：")
    # A("//   · 软复位必须第一条")
    # A("//   · PLL 配置(K/N/PRESCALE)必须在 PLLEN 之前")
    # A("//   · CLKSEL=1 必须最后 —— 切过去之前要给 PLL 留够锁定时间")
    # A("//     （由 WM8960_init.v 的 DLY_MS 参数保证，每条之间留 1 ms）")
    # A("//=============================================================================")
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
    A("    // 强制分布式 RAM（LUTRAM），不要 BRAM")
    A("    (* rom_style = \"distributed\" *) reg [DATA_WIDTH-1:0] rom [0:(2**ADDR_WIDTH)-1];")
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
