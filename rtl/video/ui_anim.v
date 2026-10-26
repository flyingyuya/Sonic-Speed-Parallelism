//////////////////////////////////////////////////////////////////////////////////
// Company:        个人项目 / SonicTwin-Engine
// Engineer:       flyingyu
//
// Create Date:    2026-10-26
// Design Name:    ui_anim
// Module Name:    ui_anim
// Project Name:   音速双擎（SonicTwin-Engine）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    ui_anim.v - 属性插值器（UI 三件套之一）
//                 【解决什么问题】
//                 现在按 KEY1 切视图预设，屏幕上是【硬跳】：极坐标"啪"地出现 / 消失。
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module ui_anim #(
    parameter integer NCH  = 3,     // 通道数（本项目 = 三个视图）
    parameter integer FULL = 128,   // 满值（必须是 2 的幂，显示侧才好用移位除）
    parameter integer STEP = 4      // 每帧步进（FULL/STEP = 过渡帧数）
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 frame,          // 每帧一个脉冲（显示侧的 sof）

    input  wire [NCH-1:0]       target,         // 1 = 该通道展开
    output reg  [NCH*8-1:0]     level           // 每通道 8 位，取值 0..FULL
);

    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin
            level <= {(NCH*8){1'b0}};
        end else if (frame) begin
            // 只在帧起始更新 —— 见文件头"为什么必须有 frame 门控"
            for (i = 0; i < NCH; i = i + 1) begin
                if (target[i]) begin
                    // 向上：钳到 FULL 就停（不能回绕，否则会突然掉回 0）
                    if (level[i*8 +: 8] > FULL - STEP)
                        level[i*8 +: 8] <= FULL[7:0];
                    else
                        level[i*8 +: 8] <= level[i*8 +: 8] + STEP[7:0];
                end else begin
                    // 向下：钳到 0 就停
                    if (level[i*8 +: 8] < STEP[7:0])
                        level[i*8 +: 8] <= 8'd0;
                    else
                        level[i*8 +: 8] <= level[i*8 +: 8] - STEP[7:0];
                end
            end
        end
    end

endmodule
