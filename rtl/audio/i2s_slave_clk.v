//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    i2s_slave_clk
// Module Name:    i2s_slave_clk
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    i2s_slave_clk.v - I2S 从模式时钟恢复
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module i2s_slave_clk #(
    parameter integer SLOT = 32          // 每个声道位数
) (
    input  wire         clk,             // clk_sys = 48 MHz
    input  wire         rst_n,

    input  wire         bclk,            // 来自 WM8960（异步）
    input  wire         lrclk,           // 来自 WM8960（异步）

    output reg          bclk_rise,       // 上升沿选通
    output reg          bclk_fall,       // 下降沿选通
    output wire         frame_start,     // 整帧起点（左声道起点）
    output wire         half_start,      // 右声道起点
    output wire [5:0]   bit_idx,         // 本次上升沿要采样的位下标
    output wire         sample_stb       // 一个立体声帧收齐
);

    localparam integer NFRAME = 2 * SLOT;
    localparam [5:0]   NLAST  = NFRAME - 1;
    localparam [5:0]   HLAST  = SLOT - 1;

    //=========================================================================
    // 输入同步 + 边沿检测
    //=========================================================================
    reg [2:0] bclk_sr;
    reg [2:0] lr_sr;

    always @(posedge clk) begin
        if (!rst_n) begin
            bclk_sr <= 3'b000;
            lr_sr   <= 3'b000;
        end else begin
            bclk_sr <= {bclk_sr[1:0], bclk};
            lr_sr   <= {lr_sr[1:0],   lrclk};
        end
    end

    wire bclk_now  = bclk_sr[1];         // 已同步的 BCLK
    wire bclk_prev = bclk_sr[2];
    wire lr_now    = lr_sr[1];           // 已同步的 LRCLK

    wire rise_w =  bclk_now & ~bclk_prev;
    wire fall_w = ~bclk_now &  bclk_prev;

    //=========================================================================
    // 选通输出
    //=========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            bclk_rise <= 1'b0;
            bclk_fall <= 1'b0;
        end else begin
            bclk_rise <= rise_w;
            bclk_fall <= fall_w;
        end
    end

    //=========================================================================
    // 位计数器
    //=========================================================================
    reg  [5:0] bcnt;
    wire [5:0] bcnt_nxt = (bcnt == NLAST) ? 6'd0 : bcnt + 6'd1;

    // 计数器隐含的声道 = 1 表示右声道
    wire lr_expect = (bcnt >= SLOT);

    // 上升沿做纠正
    wire       misalign = (lr_now != lr_expect);
    wire [5:0] bcnt_fix = lr_now ? SLOT[5:0] : 6'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            bcnt <= 6'd0;
        end else if (bclk_rise) begin
            if (misalign)
                bcnt <= bcnt_fix;
        end else if (bclk_fall) begin
            bcnt <= bcnt_nxt;
        end
    end

    // bit_idx：本次上升沿要采样的位下标
    assign bit_idx = (bclk_rise && misalign) ? bcnt_fix : bcnt;

    // frame_start / half_start 必须与 bclk_fall 同周期有效
    assign frame_start = bclk_fall & (bcnt == NLAST);
    assign half_start  = bclk_fall & (bcnt == HLAST);

    assign sample_stb  = frame_start;

endmodule
