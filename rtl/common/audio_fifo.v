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
// Dependencies:
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
    // 重要：full/empty 必须只由已寄存的指针来译码，不能用 wptr_nxt
    // 旧写法 `do_wr = wr_en && !full(wptr_nxt)` 会构成组合环：
    //      wptr_nxt -> full -> do_wr -> wptr_nxt
    // Vivado 综合报 DRC LUTLP-1 Combinatorial Loop Alert
    //-------------------------------------------------------------------------
    assign full  = (wptr[AW] != rptr[AW]) &&
                   (wptr[AW-1:0] == rptr[AW-1:0]);
    assign empty = (wptr == rptr);
    assign count = wptr - rptr;

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    assign dout = mem[rptr[AW-1:0]];

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
