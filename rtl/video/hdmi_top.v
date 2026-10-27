//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    hdmi_top
// Module Name:    hdmi_top
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    hdmi_top.v —— HDMI 输出（DVI 兼容）：把一路像素流变成 TMDS 差分对
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

`default_nettype none

module hdmi_top (
    input  wire        rst_n,

    input  wire        clk_hdmi,    // 像素时钟（来自 disp_top 的那一路，800x600@60 是 40MHz）
    input  wire        clk_5x,      // 串行化时钟（5 x 像素时钟 = 200MHz）

    //--------------------- 像素流（时序已由上游产生）---------------------
    input  wire [23:0] pix_rgb,
    input  wire        pix_de,
    input  wire        pix_hs,
    input  wire        pix_vs,

    //--------------------- TMDS 差分对 ---------------------
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire        tmds_d0_p,   // 蓝
    output wire        tmds_d0_n,
    output wire        tmds_d1_p,   // 绿
    output wire        tmds_d1_n,
    output wire        tmds_d2_p,   // 红
    output wire        tmds_d2_n,

    //--------------------- 板级控制 ---------------------
    output wire        hdmi_out_en  // 低有效（接 NC7SZ125 的 OE，原理图确认过）
);

    tmds_out u_tmds (
        .rst_n      (rst_n),
        .clk_pix    (clk_hdmi),
        .clk_5x     (clk_5x),
        .r          (pix_rgb[23:16]),
        .g          (pix_rgb[15:8]),
        .b          (pix_rgb[7:0]),
        .de         (pix_de),
        .hsync      (pix_hs),
        .vsync      (pix_vs),
        .tmds_clk_p (tmds_clk_p), .tmds_clk_n (tmds_clk_n),
        .tmds_d0_p  (tmds_d0_p),  .tmds_d0_n  (tmds_d0_n),
        .tmds_d1_p  (tmds_d1_p),  .tmds_d1_n  (tmds_d1_n),
        .tmds_d2_p  (tmds_d2_p),  .tmds_d2_n  (tmds_d2_n)
    );

    assign hdmi_out_en = 1'b0;

endmodule

`default_nettype wire
