//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    bg_src
// Module Name:    bg_src
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    bg_src.v - 背景像素源
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module bg_src #(
    parameter integer HDISP = 480,
    parameter integer VDISP = 272,
    parameter integer GRID  = 32,        // 网格间距（像素）
    // 坐标位宽：默认 10/9 对应 480x272
    parameter integer XW    = 10,
    parameter integer YW    = 9
) (
    input  wire [XW-1:0] x,
    input  wire [YW-1:0] y,
    input  wire [3:0]   mode,
    output reg  [23:0]  rgb              // {R[7:0], G[7:0], B[7:0]}
);

    localparam integer GW = $clog2(GRID);

    // 网格线：每 GRID 像素一条
    wire grid_x = (x[GW-1:0] == {GW{1'b0}});
    wire grid_y = (y[GW-1:0] == {GW{1'b0}});
    wire grid   = grid_x | grid_y;

    //=========================================================================
    // 竖直渐变：顶部更暗，底部略亮（频谱柱从底部升起来更自然）
    //=========================================================================
    localparam integer YSH = (VDISP >= 512) ? 4 : 3;    // 272 行取 3，360 行取 4
    wire [5:0] t  = y[YSH +: 6];                        // 0..33 / 0..22
    wire [7:0] gr = 8'd6  + {2'b00, t};
    wire [7:0] gg = 8'd7  + {2'b00, t};
    wire [7:0] gb = 8'd22 + {2'b00, t};

    // 网格线在这个基础上再加一点亮度
    wire [7:0] add = grid ? 8'd16 : 8'd0;

    always @(*) begin
        if (mode == 4'd1) begin
            // 模式 1：不要网格，只有渐变
            rgb = {gr, gg, gb};
        end else begin
            // 模式 0（以及其他未定义值）：渐变 + 网格
            rgb = {gr + add, gg + add, gb + add};
        end
    end

endmodule
