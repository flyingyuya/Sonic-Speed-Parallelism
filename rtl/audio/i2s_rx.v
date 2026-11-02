//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    i2s_rx
// Module Name:    i2s_rx
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    i2s_rx.v - I2S 接收（主模式，单时钟域）
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module i2s_rx #(
    parameter integer SLOT      = 32,   // 槽位宽
    parameter integer DATA_BITS = 24,   // 有效数据位
    parameter integer DW        = 24,   // 输出样本位宽（Q1.(DW-1)）

    // 数据帧内位偏移：0: 左对齐 8: 右对齐
    parameter integer OFF       = 0
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

    // 槽内取 DATA_BITS 位:
    //   OFF = 0 -> 取槽的高 DATA_BITS 位（左对齐，I2S 标准）
    //   OFF = SLOT-DATA_BITS = 8 -> 取槽的低 DATA_BITS 位（右对齐）
    wire [DATA_BITS-1:0] l_raw = sr_nxt[NFRAME-1-OFF -: DATA_BITS];
    wire [DATA_BITS-1:0] r_raw = sr_nxt[SLOT-1-OFF   -: DATA_BITS];

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
