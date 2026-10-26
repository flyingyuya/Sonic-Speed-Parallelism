//////////////////////////////////////////////////////////////////////////////////
// Company:        个人项目 / SonicTwin-Engine
// Engineer:       flyingyu
//
// Create Date:    2026-10-26
// Design Name:    env_track
// Module Name:    env_track
// Project Name:   音速双擎（SonicTwin-Engine）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    env_track.v - 包络跟踪 + 自适应触发门限
//                 【解决什么问题】
//                 wave_buf 的触发条件是"信号先低于 -TH 再向上过零"，
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module env_track #(
    parameter integer DW     = 24,      // 采样位宽
    parameter integer AS     = 6,       // 攻击速率（越小跟得越快）
    parameter integer DS     = 12,      // 释放速率（越大放得越慢）
    parameter integer KP     = 3,       // 门限 = 包络 >> KP
    // 门限下限。4096 = 2^12 = 满量程的 1/2048。
    //   太小挡不住底噪；太大则弱信号还是触发不了。这个值要按实测调。
    parameter integer TH_MIN = 4096
) (
    input  wire                 clk,
    input  wire                 rst_n,      // 同步复位（本项目惯例）
    input  wire                 en,         // 采样有效
    input  wire signed [DW-1:0] din,

    // 建议的触发门限（**正数**，表示幅度）。
    //   调用方拿它去跟 -th 比较。始终 >= TH_MIN。
    output reg  signed [DW-1:0] th,
    // 当前包络（调试/观察用，也可以在屏幕上显示出来）
    output reg         [DW-1:0] env
);

    // 多一位：|x| 在 x = -2^(DW-1) 时等于 2^(DW-1)，DW 位装不下
    localparam integer IW = DW + 1;

    localparam [IW-1:0] THMIN_L = TH_MIN;
    localparam [IW-1:0] ONE_L   = {{(IW-1){1'b0}}, 1'b1};

    //-------------------------------------------------------------------------
    // 取绝对值
    //-------------------------------------------------------------------------
    wire signed [IW-1:0] xin = {{1{din[DW-1]}}, din};
    wire        [IW-1:0] ax  = xin[IW-1] ? (~xin + ONE_L) : xin;

    //-------------------------------------------------------------------------
    // 包络：快攻 / 慢放
    //-------------------------------------------------------------------------
    reg [IW-1:0] env_r;

    // 都是无符号运算：上行时 ax >= env_r，差是正的
    wire [IW-1:0] e_up   = env_r + ((ax - env_r) >>> AS);
    wire [IW-1:0] e_down = env_r - (env_r >>> DS);

    wire [IW-1:0] env_nxt = (ax >= env_r) ? e_up : e_down;

    //-------------------------------------------------------------------------
    // 门限 = 包络 >> KP，并夹到 TH_MIN 以上
    //-------------------------------------------------------------------------
    wire [IW-1:0] th_raw = env_nxt >>> KP;
    wire [IW-1:0] th_nxt = (th_raw < THMIN_L) ? THMIN_L : th_raw;

    always @(posedge clk) begin
        if (!rst_n) begin
            env_r <= {IW{1'b0}};
            th    <= {DW{1'b0}};
            env   <= {DW{1'b0}};
        end else if (en) begin
            env_r <= env_nxt;
            // 门限只取 DW 位。因为 th_raw <= env <= 2^(DW-1)，不会溢出。
            th    <= th_nxt[DW-1:0];
            // ⚠️ 这里是 env_nxt 不是 env_r —— 要和 th 用【同一个】包络值，
            //    否则 env 比 th 晚一拍，调试时看着永远对不上（账本里
            //    "和被测信号差一拍"这一族已经栽过好几次）。
            env   <= env_nxt[DW-1:0];
        end
    end

endmodule
