//////////////////////////////////////////////////////////////////////////////////
// Company:        个人项目 / SonicTwin-Engine
// Engineer:       flyingyu
//
// Create Date:    2026-10-26
// Design Name:    key_gesture
// Module Name:    key_gesture
// Project Name:   音速双擎（SonicTwin-Engine）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    key_gesture.v —— 把按键的"按了一下"翻译成【单击】/【双击】
//                 【为什么需要它】
//                 板子上只有两个按键（KEY1/KEY2），但要表达四种动作：
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
module key_gesture #(
    parameter integer CLK_HZ = 48_000_000,   // 时钟频率（Hz）
    parameter integer WIN_MS = 300           // 双击判定窗（毫秒）
) (
    input  wire clk,
    input  wire rst_n,

    input  wire press,      // 消抖后的"按了一下"（单拍脉冲，高有效）
    output reg  single,     // 单击（窗口期满后才发，严格单拍）
    output reg  dbl         // 双击（严格单拍）
);

    // 窗口长度（时钟拍数）。下限保护成 2，否则状态机没有"等待"的余地。
    localparam integer WIN_RAW = (CLK_HZ / 1000) * WIN_MS;
    localparam integer WIN_CYC = (WIN_RAW < 2) ? 2 : WIN_RAW;
    localparam integer CW      = $clog2(WIN_CYC + 1);

    localparam S_IDLE = 1'b0,
               S_WAIT = 1'b1;

    reg          st;
    reg [CW-1:0] cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            st     <= S_IDLE;
            cnt    <= {CW{1'b0}};
            single <= 1'b0;
            dbl    <= 1'b0;
        end else begin
            // ---- 输出默认拉低：下面只在需要的那一拍显式置 1 ----
            single <= 1'b0;
            dbl    <= 1'b0;

            case (st)
                //---------------------------------------------------------
                // 空闲：等"第一下"
                //---------------------------------------------------------
                S_IDLE: begin
                    cnt <= {CW{1'b0}};
                    if (press)
                        st <= S_WAIT;       // ⚠️ 先别发 single，等窗口
                end

                //---------------------------------------------------------
                // 等待窗：看窗口内还有没有第二下
                //---------------------------------------------------------
                S_WAIT: begin
                    if (press) begin
                        // 窗口内又按了一下 ⟹ 双击。
                        // ⚠️ 这里【绝不能】补发 single —— 双击不能带出单击。
                        //    这是本模块最容易写错的一行。
                        dbl <= 1'b1;
                        st  <= S_IDLE;
                    end else if (cnt == WIN_CYC[CW-1:0] - 1'b1) begin
                        // 窗口期满，确认是单击
                        single <= 1'b1;
                        st     <= S_IDLE;
                    end else begin
                        cnt <= cnt + 1'b1;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
