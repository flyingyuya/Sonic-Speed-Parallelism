//=============================================================================
// tmds_out.v —— 三个 TMDS 数据通道 + 时钟通道（DVI/HDMI 发送端物理层）
//=============================================================================
// 【结构】每个颜色通道：
//
//   tmds_enc ──10bit──┬─ OSERDESE2(MASTER)  D1..D8 = din[7:0]  ── OQ ─┐
//                     └─ OSERDESE2(SLAVE)   D3/D4 = din[9:8]         │
//                              SHIFTOUT1/2 ──► SHIFTIN1/2           │
//                                                                   ▼
//                                                                OBUFDS ── TMDS 差分对
//
//   时钟通道：TMDS 时钟就是【像素时钟本身】（不编码、不串行化），
//            直接 OBUFDS 出去。数据通道才是 10 倍速率。
//
// 【为什么串行化不用自己写】
//   OSERDESE2 是 Xilinx 原语，本来就干这件事。
//   ⚠️ .DATA_RATE_TQ 用 "BUF" 而不是参考例程里的 "DDR"：
//      我们根本不走三态路径（T1..T4 / TCE 全接 0，TQ 空接）。
//      设成 "DDR" 时 Vivado 会报 [DRC AVAL-70]：
//      "DATA_RATE_TQ set DDR expects TRISTATE_WIDTH to be set 4" ——
//      所以要么 TRISTATE_WIDTH 填 4，要么干脆声明这条路径是 BUF。
//      后者更符合实际用法，也省得以后忘了这个约束。
//   一个只支持 8:1，所以要 10:1 必须【两个级联】（MASTER 收低 8 位、SLAVE 收高 2 位）。
//   模型细节见 sim/tb/xilinx_stub.v 里的注释（依据 A7_LITE 教程原文）。
//
// 【时钟关系】
//   clk_5x = 5 × clk_pix。DDR（双沿）⟹ 5 个 clk_5x 周期吐 10 位 = 1 个像素周期 ✓
//   ⚠️ clk_5x 和 clk_pix 必须【同源】（同一个 MMCM 出），否则相位会漂。
//
// 【极性 / 顺序】
//   输出的差分对是 {P, N}，N = ~P（OBUFDS 保证）。
//   各通道映射（DVI 连接器约定）：
//     通道 0（D0）= 蓝
//     通道 1（D1）= 绿
//     通道 2（D2）= 红
//     时钟通道   = 像素时钟
//   蓝通道在消隐期还要传 hsync/vsync（所以只有它接 c0/c1）。
//=============================================================================
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
