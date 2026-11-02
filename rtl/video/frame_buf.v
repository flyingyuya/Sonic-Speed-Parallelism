//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    frame_buf
// Module Name:    frame_buf
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    frame_buf.v  ——  一帧图片的帧缓冲（双口 BRAM）
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps


module frame_buf #(
    parameter integer W = 480,          // 帧宽（像素）
    parameter integer H = 272           // 帧高（像素）
) (
    //------------------- 写口（搬帧，通常 clk_sys）-------------------
    input  wire        wr_clk,
    input  wire        wr_en,
    input  wire [18:0] wr_addr,         // 像素线性地址 = y*W + x
    input  wire [15:0] wr_data,         // RGB565

    //------------------- 读口（显示扫描，clk_pix / clk_hdmi）-------------------
    input  wire        rd_clk,
    input  wire [18:0] rd_addr,
    output reg  [15:0] rd_data
);

    localparam integer DEPTH = W * H;

    //=========================================================================
    // 存储体：简单双口（1 写 + 1 读）-> 综合器可靠推断成 BRAM
    //=========================================================================
    reg [15:0] mem [0:DEPTH-1];

    //=========================================================================
    // 写口（搬帧，通常 clk_sys）
    //=========================================================================
    always @(posedge wr_clk) begin
        if (wr_en && (wr_addr < DEPTH[18:0]))
            mem[wr_addr] <= wr_data;
    end

    //=========================================================================
    // 读口（显示扫描，clk_pix / clk_hdmi）：1 拍延迟
    //=========================================================================
    always @(posedge rd_clk) begin
        if (rd_addr < DEPTH[18:0])
            rd_data <= mem[rd_addr];
        else
            rd_data <= 16'd0;                   // 越界读给 0，避免 X 传播
    end

endmodule
