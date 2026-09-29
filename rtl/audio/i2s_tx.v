//=============================================================================
// i2s_tx.v - I2S 发送（主模式，单时钟域）
//-----------------------------------------------------------------------------
// 每个帧起始的 bclk 下降沿装载新的立体声帧，其后每个下降沿输出下一位。
// 数据在 bclk 下降沿变化，接收端在上升沿采样 —— 标准 I2S 时序。
//
// 实现说明：不使用移位寄存器，而是整帧保存、用位下标直接索引，
//           避免"移位"与"索引"错位这类经典 off-by-one bug。
//=============================================================================
`timescale 1ns/1ps

module i2s_tx #(
    parameter integer SLOT      = 32,
    parameter integer DATA_BITS = 24,
    parameter integer DW        = 24
) (
    input  wire clk,
    input  wire rst_n,

    input  wire bclk_fall,
    input  wire frame_start,
    input  wire [5:0] bit_idx,          // 本沿之前的位下标

    // 待发送数据（在每个 frame_start 之前必须稳定）
    input  wire signed [DW-1:0] l_data,
    input  wire signed [DW-1:0] r_data,
    input  wire                 data_en,   // 0 时保持上一帧（欠载保护）

    output reg  sdout
);

    localparam integer NFRAME = 2 * SLOT;

    // 数据位左对齐放入槽的高位，低位补零（标准 I2S 对齐）
    wire [SLOT-1:0]   l_slot    = {l_data[DW-1 -: DATA_BITS], {(SLOT-DATA_BITS){1'b0}}};
    wire [SLOT-1:0]   r_slot    = {r_data[DW-1 -: DATA_BITS], {(SLOT-DATA_BITS){1'b0}}};
    wire [NFRAME-1:0] tx_frame  = {l_slot, r_slot};   // 左声道在前

    reg [NFRAME-1:0] sr;

    // 下一次下降沿要输出的位下标：帧起始为 0，否则 +1（帧起始承担回绕）
    wire [5:0]        idx_nxt = frame_start ? 6'd0 : (bit_idx + 6'd1);
    wire [NFRAME-1:0] sr_nxt  = (frame_start && data_en) ? tx_frame : sr;

    always @(posedge clk) begin
        if (!rst_n) begin
            sr    <= {NFRAME{1'b0}};
            sdout <= 1'b0;
        end else if (bclk_fall) begin
            sr    <= sr_nxt;
            sdout <= sr_nxt[NFRAME-1 - idx_nxt];
        end
    end

endmodule
