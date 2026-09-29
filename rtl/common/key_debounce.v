//=============================================================================
// key_debounce.v - 按键消抖 + 单次触发
//-----------------------------------------------------------------------------
// 机械按键按下/松开时触点会抖动几毫秒，直接当信号用会一次按下被识别成十几次。
//
// 做法：把输入打两拍同步后，用一个计数器要求"连续 N 个时钟电平不变"
//       才承认状态改变。状态改变的那一拍输出一个 press 脉冲。
//
// 参数：
//   CLK_HZ : 本模块工作时钟频率
//   MS     : 需要稳定多少毫秒才承认（默认 20 ms，对绝大多数按键足够）
//
// 注意 key_n 是【按下 = 0】（板上按键一端接 IO、一端接 GND，带上拉）。
// 本模块内部统一成"按下 = 1"的 key_pressed 语义，减少上层出错机会。
//=============================================================================
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
