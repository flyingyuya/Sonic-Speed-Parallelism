//=============================================================================
// hdmi_top.v —— HDMI 输出（DVI 兼容）：把一路像素流变成 TMDS 差分对
//=============================================================================
// 【它现在只做三件事】
//   ① 接收一路【已经带时序的】像素流（rgb + de + hsync + vsync）
//   ② 交给 tmds_out 做 8b/10b 编码 + 10:1 串行化 + 差分输出
//   ③ 驱动板级使能 HDMI_OUT_EN（低有效）
//
// 【为什么不再自己产生时序和测试图案】
//   第一版它自带 800x600 时序 + 彩条，是为了"先把物理层打通"——
//   那个目标已经达成（上板一次点亮）。现在真正要显示的是
//   disp_top 的画面，所以时序由 disp_top 自己产生（它内部有 lcd_timing），
//   本模块退化成纯粹的物理层包装。
//   测试图案的能力没有丢：disp_top 的 demo 模式（UART 开 T 命令）就是内置图案。
//
// 【像素流的来源】
//   top.v 里例化了【第二个】disp_top，参数是 800x600 + 大屏布局，
//   时钟用 clk_hdmi(40MHz)。它输出的 lcd_rgb/lcd_hs/lcd_vs/lcd_de 直接进来。
//   ⟹ 两路显示彻底解耦：LCD 那一路（480x272@12.5MHz）一行都不用改。
//
// 【已知的跨域点】
//   disp_top 内部的 ui_sel/panel_tog/key_act 来自 clk_sys 域，
//   而 HDMI 这一路跑在 clk_hdmi(40MHz) 域。其中 panel_tog/key_act 是
//   "翻转标志"，跨域安全（本模块内部还会做两级同步 + 边沿检测）；
//   ui_sel 是 4 位电平，跨域没有同步 —— 但它只在按键时变化、只影响高亮，
//   最坏情况是高亮晚一拍或短暂错一格，不影响功能。以后要严格再做同步。
//=============================================================================
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
