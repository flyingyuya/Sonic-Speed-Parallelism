//=============================================================================
// hdmi_top.v —— HDMI 输出（DVI 兼容）：800x600@60 测试图案
//=============================================================================
// 【本模块现阶段的任务】
//   只验证【物理链路】：像素时序 -> TMDS 编码 -> 10:1 串行化 -> 差分输出
//   -> 显示器能不能锁住并显示正确画面。
//   图案用最简单的彩条 + 棋盘，不依赖任何音频/UI 数据。
//
// 【为什么不直接用 disp_top 的画面】
//   disp_top 的布局常数（柱状起点、极坐标圆心/半径、波形中轴…）都是按
//   480x272 精确调过的。直接换成 800x600，那些常数会全部错位 ——
//   那是一次独立的"大屏布局设计"，和"HDMI 物理层通不通"是两件事。
//   先通物理层，再谈布局：出问题时才分得清是"链路坏"还是"布局歪"。
//
// 【800x600@60 时序（VESA）】
//   H: 有效 800 + 前肩 40 + 同步 128 + 后肩 88 = 1056
//   V: 有效 600 + 前肩  1 + 同步   4 + 后肩 23 =  628
//   像素时钟 = 1056 x 628 x 60 ≈ 39.8 MHz，本设计用 40 MHz
//   同步极性【负】（低有效）—— lcd_timing 正好是低有效，可直接复用。
//
// 【HDMI_OUT_EN】
//   板上这根线接 U14 的 0E（带上划线 = 低有效），所以使能输出要驱动 0。
//   原理图确认过的（见 docs/06-board-resources.md）。
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module hdmi_top #(
    // 800x600@60 VESA 时序
    parameter integer H_SYNC  = 128,
    parameter integer H_BACK  = 88,
    parameter integer H_DISP  = 800,
    parameter integer H_FRONT = 40,
    parameter integer V_SYNC  = 4,
    parameter integer V_BACK  = 23,
    parameter integer V_DISP  = 600,
    parameter integer V_FRONT = 1,
    parameter integer HW = $clog2(H_SYNC + H_BACK + H_DISP + H_FRONT),
    parameter integer VW = $clog2(V_SYNC + V_BACK + V_DISP + V_FRONT)
) (
    input  wire        rst_n,

    input  wire        clk_hdmi,    // 40 MHz 像素时钟
    input  wire        clk_5x,      // 200 MHz 串行化时钟（5 x 40）

    input  wire [2:0]  pattern,     // 测试图案选择（拨码/UART 都行）

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
    output wire        hdmi_out_en  // 低有效（接 U14 的 0E）
);

    //=========================================================================
    // 1. 800x600 像素时序（复用 lcd_timing，它本来就是全参数化的）
    //=========================================================================
    wire [HW-1:0] x;
    wire [VW-1:0] y;
    wire          de;
    wire          hs;
    wire          vs;

    lcd_timing #(
        .H_SYNC (H_SYNC), .H_BACK (H_BACK), .H_DISP (H_DISP), .H_FRONT (H_FRONT),
        .V_SYNC (V_SYNC), .V_BACK (V_BACK), .V_DISP (V_DISP), .V_FRONT (V_FRONT)
    ) u_timing (
        .clk     (clk_hdmi),
        .rst_n   (rst_n),
        .rgb_in  (24'h000000),      // 下面自己算颜色，这里不用它的 rgb_in
        .rgb_out (),
        .hsync   (hs),
        .vsync   (vs),
        .de      (de),
        .x       (x),
        .y       (y),
        .sof     ()
    );

    //=========================================================================
    // 2. 测试图案
    //    pattern[0] = 1: 彩条（8 条竖条，经典 RGB 排列）
    //                 0: 灰阶渐变（横向 0..255）
    //    pattern[1] = 1: 叠加棋盘格（每 64x64 反转一次），用来看"位置对不对"
    //    pattern[2] = 1: 边框（四周 8 像素白框），用来看"图像有没有被裁掉"
    //   全部为 0 时是黑屏 + 白框以外的纯灰，便于确认信号有没有到。
    //=========================================================================
    reg [23:0] pat_rgb;

    always @(*) begin
        // ---- 底色：灰阶渐变（横向 0..255），或者 8 条彩条 ----
        if (pattern[0]) begin
            // 8 条竖条：白、黄、青、绿、品红、红、蓝、黑
            case (x[HW-1:0] / (H_DISP / 8))
                3'd0: pat_rgb = 24'hFFFFFF;
                3'd1: pat_rgb = 24'hFFFF00;
                3'd2: pat_rgb = 24'h00FFFF;
                3'd3: pat_rgb = 24'h00FF00;
                3'd4: pat_rgb = 24'hFF00FF;
                3'd5: pat_rgb = 24'hFF0000;
                3'd6: pat_rgb = 24'h0000FF;
                default: pat_rgb = 24'h000000;
            endcase
        end else begin
            // 横向灰阶（用高位做亮度，避免除法）
            pat_rgb = {x[HW-1:2], x[HW-1:2], x[HW-1:2], x[HW-1:2],
                       x[HW-1:2], x[HW-1:2]};
        end

        // ---- 棋盘格叠加 ----
        if (pattern[1] && (x[6] ^ y[6]))
            pat_rgb = pat_rgb ^ 24'h404040;

        // ---- 白边框（四周 8 像素）----
        if (pattern[2] && ((x < 8) || (x >= (H_DISP - 8)) ||
                           (y < 8) || (y >= (V_DISP - 8))))
            pat_rgb = 24'hFFFFFF;
    end

    // 消隐期给黑色（TMDS 编码在 de=0 时会自动发控制码，数据位无所谓）
    wire [23:0] pix_rgb = de ? pat_rgb : 24'h000000;

    //=========================================================================
    // 3. TMDS 编码 + 串行化 + 差分输出
    //=========================================================================
    tmds_out u_tmds (
        .rst_n      (rst_n),
        .clk_pix    (clk_hdmi),
        .clk_5x     (clk_5x),
        .r          (pix_rgb[23:16]),
        .g          (pix_rgb[15:8]),
        .b          (pix_rgb[7:0]),
        .de         (de),
        .hsync      (hs),
        .vsync      (vs),
        .tmds_clk_p (tmds_clk_p), .tmds_clk_n (tmds_clk_n),
        .tmds_d0_p  (tmds_d0_p),  .tmds_d0_n  (tmds_d0_n),
        .tmds_d1_p  (tmds_d1_p),  .tmds_d1_n  (tmds_d1_n),
        .tmds_d2_p  (tmds_d2_p),  .tmds_d2_n  (tmds_d2_n)
    );

    //=========================================================================
    // 4. 板级使能：低有效（原理图上接的是 U14 的 0E）
    //=========================================================================
    assign hdmi_out_en = 1'b0;

endmodule

`default_nettype wire
