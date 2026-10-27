//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    i2s_clkgen
// Module Name:    i2s_clkgen
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    i2s_clkgen.v - I2S 主模式时钟生成（BCLK / LRCLK / 位计数 / 边沿选通）
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module i2s_clkgen #(
    parameter integer DIV  = 2,     // BCLK 半周期 clk 数
    parameter integer SLOT = 32     // 每声道位数
) (
    input  wire clk,
    input  wire rst_n,

    output reg  bclk,               // 给 codec 的位时钟
    output reg  lrclk,              // 给 codec 的声道时钟（0=左, 1=右）

    output reg  bclk_rise,          // 上升沿选通（与 bclk 新值同周期有效）
    output reg  bclk_fall,          // 下降沿选通
    output wire frame_start,        // **组合**：本下降沿是整帧起点（左声道起点）
    output wire half_start,         // **组合**：本下降沿是右声道起点
    output wire [5:0] bit_idx,      // 当前位下标 0 .. 2*SLOT-1（上升沿时有效）
    output wire sample_stb          // 一个立体声帧（L+R）收齐
);

    localparam integer NFRAME = 2 * SLOT;   // 一帧的 BCLK 个数
    localparam [5:0]   NLAST  = NFRAME - 1; // 一帧最后一位的下标
    localparam [5:0]   HLAST  = SLOT - 1;   // 左声道最后一位的下标

    reg [15:0] divcnt;                      // 0 .. 2*DIV-1
    reg [5:0]  bcnt;                        // 0 .. NFRAME-1

    wire [15:0] divcnt_nxt = (divcnt == (2*DIV-1)) ? 16'd0 : divcnt + 16'd1;
    wire        bclk_nxt   = (divcnt_nxt >= DIV);

    wire [5:0]  bcnt_nxt   = (bcnt == NLAST) ? 6'd0 : bcnt + 6'd1;

    always @(posedge clk) begin
        if (!rst_n) begin
            divcnt      <= 16'd0;
            bclk        <= 1'b0;
            bclk_rise   <= 1'b0;
            bclk_fall   <= 1'b0;
            lrclk       <= 1'b1;            // 复位为 1：第一个 frame_start 后变 0（左声道）
            bcnt        <= NLAST;           // 复位为 NLAST：第一次下降沿即整帧起点
        end else begin
            divcnt    <= divcnt_nxt;
            bclk      <= bclk_nxt;
            bclk_rise <=  bclk_nxt & ~bclk;
            bclk_fall <= ~bclk_nxt &  bclk;

            if (bclk_fall) begin
                bcnt  <= bcnt_nxt;
                lrclk <= (bcnt_nxt >= SLOT);   // 直接译码，而非"翻转"
            end
        end
    end

    // 位下标：在两次下降沿之间保持稳定，正好等于下一次上升沿要采样的位序号
    assign bit_idx = bcnt;

    // frame_start / half_start 必须与 bclk_fall **同周期**有效，
    // 否则收发端会在错误的时钟沿执行装载（曾因此丢掉整帧数据）。
    assign frame_start = bclk_fall & (bcnt == NLAST);
    assign half_start  = bclk_fall & (bcnt == HLAST);

    // 整帧起点即新的立体声样本开始
    assign sample_stb = frame_start;

endmodule
