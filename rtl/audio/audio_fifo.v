//=============================================================================
// audio_fifo.v - 同步 FIFO（寄存器实现，深度小、面积小、零 BRAM）
//-----------------------------------------------------------------------------
// 用途：隔离 I2S 帧节拍与 DSP 处理节拍，吸收抖动、防止欠载/溢出丢样。
// 指针多一位用于区分"满"和"空"。
//=============================================================================
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

    always @(posedge clk or negedge rst_n) begin
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
