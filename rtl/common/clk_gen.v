//=============================================================================
// clk_gen.v - 板载 200 MHz 差分时钟 → 系统所需全部时钟
//-----------------------------------------------------------------------------
// 输入：200 MHz 差分（R4/T4 = IO_L13P/N_MRCC_34，bank 34，Vcco = 1.5V）
// 输出：clk_sys      48   MHz  —— 音频 + 控制全部逻辑
//       clk_pix      12.5 MHz  —— LCD 时序 + Overlay
//       mmcm_locked           —— 供顶层合成复位
//
// 【为什么是 48 MHz 而不是 96 MHz】
//   阶段一综合实测：均衡器关键路径 16.2 ns → Fmax ≈ 61.6 MHz（-2 速度等级）。
//   96 MHz（周期 10.4 ns）时序不收敛；48 MHz（20.8 ns）有 +4.6 ns 正裕量。
//
// 【为什么一个 MMCM 就能同时出 48 和 12.5 MHz】
//   MMCM 的 7 个输出计数器共用同一个 VCO，所以两个频率必须都是它的分频：
//       VCO = 48 × O_sys = 12.5 × O_pix   →   O_pix = 3.84 × O_sys
//   3.84 = 96/25，故 O_sys 必须是 6.25 的倍数。VCO 落在 [600,1200] 内只有三个解：
//       O_sys = 12.5  → VCO =  600 MHz（卡下边界，不选）
//       O_sys = 18.75 → VCO =  900 MHz  ← 选它：居中，jitter 余量最好
//       O_sys = 25    → VCO = 1200 MHz（卡上边界，不选）
//   18.75 是小数，只能放 CLKOUT0_DIVIDE_F（只有它支持 1/8 步进）；
//   72 是整数，放 CLKOUT1_DIVIDE 即可。
//
// 【硬件约束提醒（来自官方例程与手册）】
//   * DIFF_TERM 必须为 FALSE —— 内部 100Ω 差分端接只支持 LVDS 类标准，
//     DIFF_SSTL15 不在支持列表内（端接靠板载电阻/DCI）。
//   * IBUF_LOW_PWR 用 FALSE —— 低功耗模式输入带宽受限，200 MHz 正好在边界。
//   * clk_200m 不引出模块 —— 只有 MMCM 用它，省一个 BUFG。
//=============================================================================
`timescale 1ns/1ps

module clk_gen (
    input  wire clk_200m_p,      // R4  IO_L13P_MRCC_34
    input  wire clk_200m_n,      // T4  IO_L13N_MRCC_34
    input  wire rst_btn_n,       // R14 板载复位按键，低有效
    output wire clk_sys,         // 48 MHz
    output wire clk_pix,         // 12.5 MHz
    output wire mmcm_locked
);

    wire clk_200m;               // IBUFDS 输出的单端 200 MHz
    wire clkfb;                  // MMCM 反馈
    wire clk_sys_raw;            // MMCM 输出，尚未过 BUFG
    wire clk_pix_raw;
    wire locked;

    // 差分转单端
    IBUFDS #(
        .DIFF_TERM    ("FALSE"),        // DIFF_SSTL15 不支持内部端接
        .IBUF_LOW_PWR ("FALSE"),        // 200 MHz 用高性能模式
        .IOSTANDARD   ("DIFF_SSTL15")   // 与 XDC 保持一致
    ) u_ibufds (
        .O  (clk_200m),
        .I  (clk_200m_p),
        .IB (clk_200m_n)
    );

    // MMCM：200 MHz → 48 MHz + 12.5 MHz
    // PFD = 200/4 = 50 MHz，VCO = 50 × 18.000 = 900 MHz
    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .STARTUP_WAIT       ("FALSE"),      // 不在配置完成前等 LOCKED
        .CLKIN1_PERIOD      (5.000),        // 200 MHz
        .DIVCLK_DIVIDE      (4),            // PFD = 50 MHz
        .CLKFBOUT_MULT_F    (18.000),       // VCO = 900 MHz
        .CLKFBOUT_PHASE     (0.000),
        .CLKOUT0_DIVIDE_F   (18.750),       // 900 / 18.75 = 48 MHz
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT0_PHASE      (0.000),
        .CLKOUT1_DIVIDE     (72),           // 900 / 72 = 12.5 MHz
        .CLKOUT1_DUTY_CYCLE (0.500),
        .CLKOUT1_PHASE      (0.000),
        .REF_JITTER1        (0.010)
    ) u_mmcm (
        .CLKIN1   (clk_200m),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),

        .CLKOUT0  (clk_sys_raw),
        .CLKOUT1  (clk_pix_raw),
        .CLKOUT2  (), .CLKOUT3  (), .CLKOUT4  (),
        .CLKOUT5  (), .CLKOUT6  (),
        .CLKOUT0B (), .CLKOUT1B (), .CLKOUT2B (), .CLKOUT3B (),
        .CLKFBOUTB(),

        .LOCKED   (locked),
        .PWRDWN   (1'b0),
        .RST      (~rst_btn_n)
    );

    // 全局时钟缓冲
    BUFG u_bufg_sys (.I(clk_sys_raw), .O(clk_sys));
    BUFG u_bufg_pix (.I(clk_pix_raw), .O(clk_pix));

    // 锁相指示
    assign mmcm_locked = locked;

endmodule
