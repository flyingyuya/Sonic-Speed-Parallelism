//////////////////////////////////////////////////////////////////////////////////
// Company:        个人项目 / SonicTwin-Engine
// Engineer:       flyingyu
//
// Create Date:    2026-10-26
// Design Name:    bg_src
// Module Name:    bg_src
// Project Name:   音速双擎（SonicTwin-Engine）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    bg_src.v - 背景像素源（扩展点 ①）
//                 接口刻意做成【纯组合】：(x, y, mode) -> rgb
//                 这样显示混合逻辑只要"扫描到哪算到哪"，不需要渲染状态机、不需要行缓存。
// Dependencies:   无
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
    // 坐标位宽（P1-3a）：默认 10/9 对应 480x272，与原写死的 [9:0]/[8:0] 一致
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

    // 竖直渐变：顶部更暗，底部略亮（这样频谱柱从底部升起来更自然）
    //-------------------------------------------------------------------------
    // ⚠️ 偏移量必须【按屏幕高度归一化】，不能用固定的 y[8:3]：
    //   · LCD  272 行 ⟹ y[8:3] 是 0..33 ✓ 正确
    //   · HDMI 360 行 ⟹ y[8:3] 在 y>=256 时【回绕到 0】⟹ 下半屏渐变从头开始
    //     ⟹ 和 LCD 的背景看起来完全不一样（用户实测发现）
    //   ⟹ 用 YSH = clog2(VDISP/34) 动态选移位数：
    //        VDISP=272 ⟹ 8  ⟹ YSH=3（和原来的 y[8:3] 完全一致）
    //        VDISP=360 ⟹ 10 ⟹ YSH=4（0..22，铺满全屏不回绕）
    //-------------------------------------------------------------------------
    localparam integer YSH = (VDISP >= 512) ? 4 : 3;
    wire [5:0] t  = y[YSH +: 6];
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
