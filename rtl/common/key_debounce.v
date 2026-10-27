//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    key_debounce
// Module Name:    key_debounce
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    key_debounce.v - 按键消抖 + 单次触发
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module key_debounce #(
    parameter integer CLK_HZ = 48_000_000,
    parameter integer MS     = 20
) (
    input  wire clk,
    input  wire rst_n,
    input  wire key_n,          // 原始按键输入，按下 = 0
    output reg  key_pressed,    // 消抖后的电平，按下 = 1
    output reg  press           // 按下瞬间的 1 拍脉冲
);

    localparam integer CNT_MAX = CLK_HZ / 1000 * MS;

    //-------------------------------------------------------------------------
    // 两级同步（按键是异步输入）
    //-------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg k_s1, k_s2;

    always @(posedge clk) begin
        if (!rst_n) begin
            k_s1 <= 1'b1;
            k_s2 <= 1'b1;
        end else begin
            k_s1 <= key_n;
            k_s2 <= k_s1;
        end
    end

    wire key_in = ~k_s2;        // 按下 = 1

    //-------------------------------------------------------------------------
    // 稳定计数器：电平保持不变才累加，一变就清零
    //-------------------------------------------------------------------------
    reg [31:0] cnt;

    always @(posedge clk) begin
        if (!rst_n)
            cnt <= 32'd0;
        else if (key_in != key_pressed) begin
            if (cnt >= CNT_MAX[31:0])
                cnt <= 32'd0;
            else
                cnt <= cnt + 1'b1;
        end else
            cnt <= 32'd0;
    end

    //-------------------------------------------------------------------------
    // 状态更新 + 按下脉冲
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            key_pressed <= 1'b0;
            press       <= 1'b0;
        end else if (cnt >= CNT_MAX[31:0]) begin
            // 稳定够久了，承认新的电平
            press       <= key_in && !key_pressed;   // 只在"变成按下"那一拍给脉冲
            key_pressed <= key_in;
        end else begin
            press <= 1'b0;
        end
    end

endmodule
