//=============================================================================
// i2s_clkgen.v - I2S 主模式时钟生成（BCLK / LRCLK / 位计数 / 边沿选通）
//-----------------------------------------------------------------------------
// 全部逻辑运行在 clk（clk_audio = 12.288 MHz）单一时钟域内，输出 bclk/lrclk
// 给外部 codec，同时产生与 bclk 边沿严格对齐的选通脉冲，供 i2s_rx / i2s_tx 使用
// —— **整个 I2S 接口无跨时钟域，无亚稳态风险**。
//
// 参数：
//   DIV   : BCLK 半周期占据的 clk 个数；BCLK 周期 = 2*DIV 个 clk
//           clk=12.288MHz, DIV=2  -> BCLK = 3.072 MHz = 48kHz x 64
//   SLOT  : 每个声道位数（BCLK 周期数/声道），32 -> LRCLK = 48 kHz
//
// 时序（SLOT=4 示意，实际 SLOT=32）：
//            _   _   _   _   _   _   _   _
//   bclk    | |_| |_| |_| |_| |_| |_| |_| |_
//   bit_idx  0   1   2   3 | 0   1   2   3 | 0 ...
//   lrclk   ________________|¯¯¯¯¯¯¯¯¯¯¯¯¯¯¯|
//             左声道(32bit)   右声道(32bit)   下一帧
//           ^frame_start                    ^frame_start
//                            ^half_start
//
// 关键点：
//   1) LRCLK 由 bit_idx 直接译码得到（bit_idx >= SLOT），而不是"每个帧翻转一次"，
//      否则 LRCLK 半周期会变成 2*SLOT 个 BCLK（分频比错一倍）。
//   2) LRCLK 在 BCLK 下降沿翻转，其后第一个上升沿采到的是该声道 MSB，
//      符合标准 Philips I2S 时序。
//   3) frame_start 只在"整帧起点（左声道起点）"脉冲；右声道起点是 half_start。
//      发送端只能在 frame_start 重载整帧，绝不能在 half_start 重载。
//=============================================================================
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

    always @(posedge clk or negedge rst_n) begin
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
