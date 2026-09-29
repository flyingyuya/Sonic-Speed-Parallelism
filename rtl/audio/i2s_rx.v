//=============================================================================
// i2s_rx.v - I2S 接收（主模式，单时钟域）
//-----------------------------------------------------------------------------
// 在 bclk 上升沿采样 sdin，按 64 位移位寄存器拼帧，帧末（bit_idx = 2*SLOT-1）
// 同时得到左/右声道数据并输出一个 sample_valid 脉冲。
//
// 声道对齐：I2S 标准下 LRCLK 下降沿后的第一个上升沿是左声道 MSB，
//           因此先收到的 SLOT 位是左声道，后 SLOT 位是右声道。
// 数据对齐：24bit 音频数据位于 32bit 槽的高 24 位（低位补零）。
//=============================================================================
`timescale 1ns/1ps

module i2s_rx #(
    parameter integer SLOT      = 32,   // 槽位宽
    parameter integer DATA_BITS = 24,   // 有效数据位
    parameter integer DW        = 24    // 输出样本位宽（Q1.(DW-1)）
) (
    input  wire clk,
    input  wire rst_n,

    // 来自 i2s_clkgen
    input  wire bclk_rise,
    input  wire bclk_fall,
    input  wire [5:0] bit_idx,

    input  wire sdin,                   // 串行数据输入

    output reg  signed [DW-1:0] l_data,
    output reg  signed [DW-1:0] r_data,
    output reg  sample_valid            // 一周期脉冲
);

    localparam integer NFRAME = 2 * SLOT;
    localparam [5:0]   NLAST  = NFRAME - 1;
    localparam integer UP     = DW - DATA_BITS;   // 左移到满量程的位数

    reg [NFRAME-1:0] sr;
    wire [NFRAME-1:0] sr_nxt = {sr[NFRAME-2:0], sdin};

    // 槽内高 DATA_BITS 位 -> DW 位满量程
    wire [DATA_BITS-1:0] l_raw = sr_nxt[NFRAME-1 -: DATA_BITS];
    wire [DATA_BITS-1:0] r_raw = sr_nxt[SLOT-1   -: DATA_BITS];

    generate
        if (UP == 0) begin : g_same
            wire signed [DW-1:0] l_val = l_raw;
            wire signed [DW-1:0] r_val = r_raw;
            always @(posedge clk) begin
                if (!rst_n) begin
                    sr           <= {NFRAME{1'b0}};
                    l_data       <= {DW{1'b0}};
                    r_data       <= {DW{1'b0}};
                    sample_valid <= 1'b0;
                end else begin
                    sample_valid <= 1'b0;
                    if (bclk_rise) begin
                        sr <= sr_nxt;
                        if (bit_idx == NLAST) begin
                            l_data       <= l_val;
                            r_data       <= r_val;
                            sample_valid <= 1'b1;
                        end
                    end
                end
            end
        end else begin : g_up
            wire signed [DW-1:0] l_val = {{UP{1'b0}}, l_raw} <<< UP;
            wire signed [DW-1:0] r_val = {{UP{1'b0}}, r_raw} <<< UP;
            always @(posedge clk) begin
                if (!rst_n) begin
                    sr           <= {NFRAME{1'b0}};
                    l_data       <= {DW{1'b0}};
                    r_data       <= {DW{1'b0}};
                    sample_valid <= 1'b0;
                end else begin
                    sample_valid <= 1'b0;
                    if (bclk_rise) begin
                        sr <= sr_nxt;
                        if (bit_idx == NLAST) begin
                            l_data       <= l_val;
                            r_data       <= r_val;
                            sample_valid <= 1'b1;
                        end
                    end
                end
            end
        end
    endgenerate

endmodule
