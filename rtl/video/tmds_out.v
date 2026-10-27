//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    tmds_out
// Module Name:    tmds_out
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    tmds_out.v —— 三个 TMDS 数据通道 + 时钟通道（DVI/HDMI 发送端物理层）
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

`default_nettype none

module tmds_out (
    input  wire        rst_n,

    input  wire        clk_pix,     // 像素时钟（= TMDS 时钟通道速率）
    input  wire        clk_5x,      // 5 × clk_pix（DDR 用）

    input  wire [7:0]  r,
    input  wire [7:0]  g,
    input  wire [7:0]  b,
    input  wire        de,          // 数据有效
    input  wire        hsync,
    input  wire        vsync,

    //--------------------- TMDS 差分对 ---------------------
    output wire        tmds_clk_p,
    output wire        tmds_clk_n,
    output wire        tmds_d0_p,   // 蓝
    output wire        tmds_d0_n,
    output wire        tmds_d1_p,   // 绿
    output wire        tmds_d1_n,
    output wire        tmds_d2_p,   // 红
    output wire        tmds_d2_n
);

    //=========================================================================
    // 1. 三个通道的 8b/10b 编码
    //    只有蓝通道带控制位（hsync/vsync 靠它在消隐期传出去）
    //=========================================================================
    wire [9:0] bd, gd, rd;

    tmds_enc u_enc_b (
        .clk(clk_pix), .rst_n(rst_n),
        .din(b), .c0(hsync), .c1(vsync), .de(de), .dout(bd)
    );

    tmds_enc u_enc_g (
        .clk(clk_pix), .rst_n(rst_n),
        .din(g), .c0(1'b0), .c1(1'b0), .de(de), .dout(gd)
    );

    tmds_enc u_enc_r (
        .clk(clk_pix), .rst_n(rst_n),
        .din(r), .c0(1'b0), .c1(1'b0), .de(de), .dout(rd)
    );

    //=========================================================================
    // 2. 一个通道的串行化 + 差分输出
    //    写成"重复三次"而不是 generate，是为了每根线都看得见、好对照原理图。
    //=========================================================================
    //------------------------------ 蓝通道 ----------------------------------
    wire b_ser;
    wire b_sh1, b_sh2;

    OSERDESE2 #(
        .DATA_RATE_OQ ("DDR"), .DATA_RATE_TQ ("BUF"), .DATA_WIDTH (10),
        .INIT_OQ (1'b0), .INIT_TQ (1'b0), .SERDES_MODE ("SLAVE"),
        .SRVAL_OQ (1'b0), .SRVAL_TQ (1'b0),
        .TBYTE_CTL ("FALSE"), .TBYTE_SRC ("FALSE"), .TRISTATE_WIDTH (1)
    ) u_oser_b_slave (
        .OFB(), .OQ(), .SHIFTOUT1(b_sh1), .SHIFTOUT2(b_sh2),
        .TBYTEOUT(), .TFB(), .TQ(),
        .D1(1'b0), .D2(1'b0), .D3(bd[8]), .D4(bd[9]),
        .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
        .CLK(clk_5x), .CLKDIV(clk_pix),
        .SHIFTIN1(1'b0), .SHIFTIN2(1'b0),
        .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
        .TBYTEIN(1'b0), .TCE(1'b0), .OCE(1'b1), .RST(~rst_n)
    );

    OSERDESE2 #(
        .DATA_RATE_OQ ("DDR"), .DATA_RATE_TQ ("BUF"), .DATA_WIDTH (10),
        .INIT_OQ (1'b0), .INIT_TQ (1'b0), .SERDES_MODE ("MASTER"),
        .SRVAL_OQ (1'b0), .SRVAL_TQ (1'b0),
        .TBYTE_CTL ("FALSE"), .TBYTE_SRC ("FALSE"), .TRISTATE_WIDTH (1)
    ) u_oser_b_master (
        .OFB(), .OQ(b_ser), .SHIFTOUT1(), .SHIFTOUT2(),
        .TBYTEOUT(), .TFB(), .TQ(),
        .D1(bd[0]), .D2(bd[1]), .D3(bd[2]), .D4(bd[3]),
        .D5(bd[4]), .D6(bd[5]), .D7(bd[6]), .D8(bd[7]),
        .CLK(clk_5x), .CLKDIV(clk_pix),
        .SHIFTIN1(b_sh1), .SHIFTIN2(b_sh2),
        .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
        .TBYTEIN(1'b0), .TCE(1'b0), .OCE(1'b1), .RST(~rst_n)
    );

    OBUFDS u_obuf_b (.O(tmds_d0_p), .OB(tmds_d0_n), .I(b_ser));

    //------------------------------ 绿通道 ----------------------------------
    wire g_ser;
    wire g_sh1, g_sh2;

    OSERDESE2 #(
        .DATA_RATE_OQ ("DDR"), .DATA_RATE_TQ ("BUF"), .DATA_WIDTH (10),
        .INIT_OQ (1'b0), .INIT_TQ (1'b0), .SERDES_MODE ("SLAVE"),
        .SRVAL_OQ (1'b0), .SRVAL_TQ (1'b0),
        .TBYTE_CTL ("FALSE"), .TBYTE_SRC ("FALSE"), .TRISTATE_WIDTH (1)
    ) u_oser_g_slave (
        .OFB(), .OQ(), .SHIFTOUT1(g_sh1), .SHIFTOUT2(g_sh2),
        .TBYTEOUT(), .TFB(), .TQ(),
        .D1(1'b0), .D2(1'b0), .D3(gd[8]), .D4(gd[9]),
        .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
        .CLK(clk_5x), .CLKDIV(clk_pix),
        .SHIFTIN1(1'b0), .SHIFTIN2(1'b0),
        .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
        .TBYTEIN(1'b0), .TCE(1'b0), .OCE(1'b1), .RST(~rst_n)
    );

    OSERDESE2 #(
        .DATA_RATE_OQ ("DDR"), .DATA_RATE_TQ ("BUF"), .DATA_WIDTH (10),
        .INIT_OQ (1'b0), .INIT_TQ (1'b0), .SERDES_MODE ("MASTER"),
        .SRVAL_OQ (1'b0), .SRVAL_TQ (1'b0),
        .TBYTE_CTL ("FALSE"), .TBYTE_SRC ("FALSE"), .TRISTATE_WIDTH (1)
    ) u_oser_g_master (
        .OFB(), .OQ(g_ser), .SHIFTOUT1(), .SHIFTOUT2(),
        .TBYTEOUT(), .TFB(), .TQ(),
        .D1(gd[0]), .D2(gd[1]), .D3(gd[2]), .D4(gd[3]),
        .D5(gd[4]), .D6(gd[5]), .D7(gd[6]), .D8(gd[7]),
        .CLK(clk_5x), .CLKDIV(clk_pix),
        .SHIFTIN1(g_sh1), .SHIFTIN2(g_sh2),
        .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
        .TBYTEIN(1'b0), .TCE(1'b0), .OCE(1'b1), .RST(~rst_n)
    );

    OBUFDS u_obuf_g (.O(tmds_d1_p), .OB(tmds_d1_n), .I(g_ser));

    //------------------------------ 红通道 ----------------------------------
    wire r_ser;
    wire r_sh1, r_sh2;

    OSERDESE2 #(
        .DATA_RATE_OQ ("DDR"), .DATA_RATE_TQ ("BUF"), .DATA_WIDTH (10),
        .INIT_OQ (1'b0), .INIT_TQ (1'b0), .SERDES_MODE ("SLAVE"),
        .SRVAL_OQ (1'b0), .SRVAL_TQ (1'b0),
        .TBYTE_CTL ("FALSE"), .TBYTE_SRC ("FALSE"), .TRISTATE_WIDTH (1)
    ) u_oser_r_slave (
        .OFB(), .OQ(), .SHIFTOUT1(r_sh1), .SHIFTOUT2(r_sh2),
        .TBYTEOUT(), .TFB(), .TQ(),
        .D1(1'b0), .D2(1'b0), .D3(rd[8]), .D4(rd[9]),
        .D5(1'b0), .D6(1'b0), .D7(1'b0), .D8(1'b0),
        .CLK(clk_5x), .CLKDIV(clk_pix),
        .SHIFTIN1(1'b0), .SHIFTIN2(1'b0),
        .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
        .TBYTEIN(1'b0), .TCE(1'b0), .OCE(1'b1), .RST(~rst_n)
    );

    OSERDESE2 #(
        .DATA_RATE_OQ ("DDR"), .DATA_RATE_TQ ("BUF"), .DATA_WIDTH (10),
        .INIT_OQ (1'b0), .INIT_TQ (1'b0), .SERDES_MODE ("MASTER"),
        .SRVAL_OQ (1'b0), .SRVAL_TQ (1'b0),
        .TBYTE_CTL ("FALSE"), .TBYTE_SRC ("FALSE"), .TRISTATE_WIDTH (1)
    ) u_oser_r_master (
        .OFB(), .OQ(r_ser), .SHIFTOUT1(), .SHIFTOUT2(),
        .TBYTEOUT(), .TFB(), .TQ(),
        .D1(rd[0]), .D2(rd[1]), .D3(rd[2]), .D4(rd[3]),
        .D5(rd[4]), .D6(rd[5]), .D7(rd[6]), .D8(rd[7]),
        .CLK(clk_5x), .CLKDIV(clk_pix),
        .SHIFTIN1(r_sh1), .SHIFTIN2(r_sh2),
        .T1(1'b0), .T2(1'b0), .T3(1'b0), .T4(1'b0),
        .TBYTEIN(1'b0), .TCE(1'b0), .OCE(1'b1), .RST(~rst_n)
    );

    OBUFDS u_obuf_r (.O(tmds_d2_p), .OB(tmds_d2_n), .I(r_ser));

    //=========================================================================
    // 3. 时钟通道：就是像素时钟本身，直接差分出去
    //=========================================================================
    OBUFDS u_obuf_clk (.O(tmds_clk_p), .OB(tmds_clk_n), .I(clk_pix));

endmodule

`default_nettype wire
