//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    audio_fifo
// Module Name:    audio_fifo
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    audio_fifo.v - 同步 FIFO（寄存器实现，深度小、面积小、零 BRAM）
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module audio_fifo #(
    parameter integer DW    = 48,
    parameter integer DEPTH = 8
) (
    input  wire          clk,
    input  wire          rst_n,

    input  wire          wr_en,
    input  wire [DW-1:0] din,
    output wire          full,

    input  wire          rd_en,
    output wire [DW-1:0] dout,      // show-ahead：rd_en 当拍即可用
    output wire          empty,

    output wire [$clog2(DEPTH):0] count
);

    localparam integer AW = $clog2(DEPTH);

    reg [DW-1:0]      mem [0:DEPTH-1];
    reg [AW:0]        wptr, rptr;

    //-------------------------------------------------------------------------
    // 重要：full/empty 必须只由**已寄存的指针**译码，不能用 wptr_nxt。
    // 旧写法 `do_wr = wr_en && !full(wptr_nxt)` 会构成组合环
    //   wptr_nxt -> full -> do_wr -> wptr_nxt
    // iverilog 仿真时恰好收敛因此没暴露，Vivado 综合报 DRC LUTLP-1
    // Combinatorial Loop Alert。这是上板后真正的竞争风险。
    //-------------------------------------------------------------------------
    assign full  = (wptr[AW] != rptr[AW]) &&
                   (wptr[AW-1:0] == rptr[AW-1:0]);
    assign empty = (wptr == rptr);
    assign count = wptr - rptr;

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    assign dout = mem[rptr[AW-1:0]];

    //-------------------------------------------------------------------------
    // 复位用【同步】风格（always @(posedge clk) + if (!rst_n)），不用
    // `or negedge rst_n`。原因：本 FIFO 的 empty/full 会一路传到
    // fft_core 里 BRAM 的 WEBWE 使能脚。带异步复位的寄存器在复位有效时
    // 会在两个时钟沿之间异步跳变，时钟沿落到跳变中就可能在非法时刻使能
    // BRAM 写 —— 默认静态时序分析不覆盖这条路径，Vivado 报 REQP-1839。
    // 前提：复位期间 clk 必须一直跑（本工程由 MMCM + rst_sync 保证）。
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            wptr <= {(AW+1){1'b0}};
            rptr <= {(AW+1){1'b0}};
        end else begin
            if (do_wr) begin
                mem[wptr[AW-1:0]] <= din;
                wptr <= wptr + 1'b1;
            end
            if (do_rd) rptr <= rptr + 1'b1;
        end
    end

endmodule
