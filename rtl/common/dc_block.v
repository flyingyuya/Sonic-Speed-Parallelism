//////////////////////////////////////////////////////////////////////////////////
// Company:        个人项目 / SonicTwin-Engine
// Engineer:       flyingyu
//
// Create Date:    2026-10-26
// Design Name:    dc_block
// Module Name:    dc_block
// Project Name:   音速双擎（SonicTwin-Engine）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    dc_block.v - 直流阻断器（一阶高通 / DC blocker）
//                 差分方程：
//                 y[n] = x[n] - x[n-1] + y[n-1] * (1 - 2^-SH)
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module dc_block #(
    parameter integer DW = 24,      // 输入/输出位宽
    parameter integer SH = 10,      // R = 1 - 2^-SH
    parameter integer GW = 2        // 内部保护位
) (
    input  wire                 clk,
    input  wire                 rst_n,      // 同步复位（本项目惯例）
    input  wire                 en,         // 采样有效（每个采样一个 strobe）
    input  wire signed [DW-1:0] din,
    output reg  signed [DW-1:0] dout
);

    localparam integer IW = DW + GW;

    // 24 位有符号的边界（用于输出饱和）
    localparam signed [DW-1:0] V_MAX = {1'b0, {(DW-1){1'b1}}};
    localparam signed [DW-1:0] V_MIN = {1'b1, {(DW-1){1'b0}}};

    reg signed [IW-1:0] x1;     // x[n-1]
    reg signed [IW-1:0] y;      // y[n-1]

    // 符号扩展到内部位宽
    wire signed [IW-1:0] xin = {{GW{din[DW-1]}}, din};

    // y[n-1] * R = y - (y >>> SH)
    wire signed [IW-1:0] ysh   = y >>> SH;

    // ⚠️ 反馈路径是 y -> (xin - x1 + y) -> (- ysh) -> y，两级加法器。
    //    xin - x1 不在反馈环上，可以和它并行算，所以关键路径只有 2 个加法器。
    wire signed [IW-1:0] ynext = xin - x1 + y - ysh;

    // 输出要不要饱和：内部值能否用 DW 位有符号表示
    wire y_ovf = (y[IW-1:DW] != {(IW-DW){y[DW-1]}});

    always @(posedge clk) begin
        if (!rst_n) begin
            x1   <= {IW{1'b0}};
            y    <= {IW{1'b0}};
            dout <= {DW{1'b0}};
        end else if (en) begin
            x1 <= xin;
            y  <= ynext;

            // ⚠️ 饱和方向看的是【内部最高位】y[IW-1]，不是 y[DW-1]。
            //    负溢出时 y[DW-1] 可能是 0（比如 -2^24 的 24 位截断是 0），
            //    用它判方向会 saturate 到 +V_MAX，反了。
            if (y_ovf) dout <= y[IW-1] ? V_MIN : V_MAX;
            else       dout <= y[DW-1:0];
        end
    end

endmodule
