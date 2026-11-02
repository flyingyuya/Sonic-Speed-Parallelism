//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    clk_gen
// Module Name:    clk_gen
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    clk_gen.v - 板载 200 MHz 差分时钟 → 系统所需全部时钟
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module clk_gen (
    input  wire clk_200m_p,      // R4  IO_L13P_MRCC_34
    input  wire clk_200m_n,      // T4  IO_L13N_MRCC_34
    input  wire rst_btn_n,       // R14 板载复位按键，低有效
    output wire clk_sys,         // 48 MHz
    output wire clk_pix,         // 12.5 MHz
    output wire clk_hdmi,        // 25 MHz   —— HDMI 像素时钟（640x480@60）
    output wire clk_5x,          // 125 MHz  —— HDMI 串行化时钟（5 x 25）
    output wire mmcm_locked
);

    wire clk_200m;               // IBUFDS 输出的单端 200 MHz
    wire clkfb;                  // MMCM 反馈
    wire clk_sys_raw;            // MMCM 输出，尚未过 BUFG
    wire clk_pix_raw;
    wire locked;
    wire clkfb_h;                // 第二个 MMCM 的反馈
    wire locked_h;

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

    //=========================================================================
    // 第二个 MMCM：给 HDMI 出 40 MHz 和 200 MHz
    //=========================================================================
    wire clk_hdmi_raw;
    wire clk_5x_raw;

    MMCME2_BASE #(
        .BANDWIDTH          ("OPTIMIZED"),
        .STARTUP_WAIT       ("FALSE"),
        .CLKIN1_PERIOD      (5.000),        // 200 MHz
        .DIVCLK_DIVIDE      (4),            // PFD = 50 MHz
        .CLKFBOUT_MULT_F    (20.000),       // VCO = 50 x 20 = 1000 MHz
        .CLKFBOUT_PHASE     (0.000),
        .CLKOUT0_DIVIDE_F   (40.000),       // 1000 / 40 = 25 MHz
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT0_PHASE      (0.000),
        .CLKOUT1_DIVIDE     (8),            // 1000 / 8 = 125 MHz
        .CLKOUT1_DUTY_CYCLE (0.500),
        .CLKOUT1_PHASE      (0.000),
        .REF_JITTER1        (0.010)
    ) u_mmcm_hdmi (
        .CLKIN1   (clk_200m),
        .CLKFBIN  (clkfb_h),
        .CLKFBOUT (clkfb_h),

        .CLKOUT0  (clk_hdmi_raw),
        .CLKOUT1  (clk_5x_raw),
        .CLKOUT2  (), .CLKOUT3  (), .CLKOUT4  (),
        .CLKOUT5  (), .CLKOUT6  (),
        .CLKOUT0B (), .CLKOUT1B (), .CLKOUT2B (), .CLKOUT3B (),
        .CLKFBOUTB(),

        .LOCKED   (locked_h),
        .PWRDWN   (1'b0),
        .RST      (~rst_btn_n)
    );

    // 全局时钟缓冲
    BUFG u_bufg_sys  (.I(clk_sys_raw),  .O(clk_sys));
    BUFG u_bufg_pix  (.I(clk_pix_raw),  .O(clk_pix));
    BUFG u_bufg_hdmi (.I(clk_hdmi_raw), .O(clk_hdmi));
    BUFG u_bufg_5x   (.I(clk_5x_raw),   .O(clk_5x));

    // 锁相指示：两个 MMCM 都锁上了才算好
    assign mmcm_locked = locked & locked_h;

endmodule
