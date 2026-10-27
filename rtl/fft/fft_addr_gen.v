//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    fft_addr_gen
// Module Name:    fft_addr_gen
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    fft_addr_gen.v - FFT 蝶形地址与旋转因子索引生成（纯组合逻辑）
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module fft_addr_gen #(
    parameter integer LOG2N = 10            // N = 2^LOG2N
) (
    input  wire [LOG2N-2:0]  cnt,           // 蝶形编号 0 .. N/2-1
    input  wire [3:0]        stage,         // 当前级数 0 .. LOG2N-1
    output wire [LOG2N-1:0]  p,             // 蝶形第一个点地址
    output wire [LOG2N-1:0]  q,             // 蝶形第二个点地址
    output wire [LOG2N-2:0]  tw_idx         // 旋转因子 ROM 索引
);

    //=========================================================================
    // 地址推导：把蝶形编号 cnt 映射成一对点 (p, q) 和旋转因子索引
    //=========================================================================
    localparam [LOG2N-1:0] ONE = {{(LOG2N-1){1'b0}}, 1'b1};

    // 移位量用 5 位宽 —— stage = 15 时 stage+1 会溢出成 0
    wire [4:0] stage_w = {1'b0, stage};
    wire [4:0] sh_p    = stage_w + 5'd1;                // stage + 1
    wire [4:0] sh_tw   = LOG2N[4:0] - 5'd1 - stage_w;   // LOG2N - 1 - stage

    wire [LOG2N-1:0] lo_mask = (ONE << stage_w) - ONE;  // 低 stage 位掩码
    wire [LOG2N-1:0] cnt_x   = {1'b0, cnt};             // cnt 扩位

    // 插 0：高位左移一格，第 stage 位补 0，低位不变
    assign p = ((cnt_x >> stage_w) << sh_p) | (cnt_x & lo_mask);

    // 插 1：在 p 的第 stage 位置 1
    assign q = p | (ONE << stage_w);

    // 旋转因子索引
    assign tw_idx = (cnt & lo_mask[LOG2N-2:0]) << sh_tw;

endmodule
