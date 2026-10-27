//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    uart_rx
// Module Name:    uart_rx
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    uart_rx.v - UART 接收（8N1，参数化波特率）
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module uart_rx #(
    parameter integer CLK_HZ = 48_000_000,
    parameter integer BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       rx,           // 空闲为高
    output reg  [7:0] data,
    output reg        valid,        // 收到一个字节时的 1 拍脉冲
    output reg        ferr          // 帧错误（停止位不为 1）
);

    localparam integer DIV = (CLK_HZ + BAUD / 2) / BAUD;   // 四舍五入
    localparam integer HALF = DIV / 2;

    //-------------------------------------------------------------------------
    // 输入同步
    //-------------------------------------------------------------------------
    (* ASYNC_REG = "TRUE" *) reg rx_s1, rx_s2;
    always @(posedge clk) begin
        if (!rst_n) begin
            rx_s1 <= 1'b1;
            rx_s2 <= 1'b1;
        end else begin
            rx_s1 <= rx;
            rx_s2 <= rx_s1;
        end
    end

    //-------------------------------------------------------------------------
    // 状态机
    //-------------------------------------------------------------------------
    localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    reg [1:0]  st;
    reg [15:0] cnt;         // 半比特 / 全比特计时
    reg [2:0]  bidx;        // 位序号 0..7
    reg [7:0]  sh;          // 移位寄存器

    always @(posedge clk) begin
        if (!rst_n) begin
            st    <= S_IDLE;
            cnt   <= 16'd0;
            bidx  <= 3'd0;
            sh    <= 8'd0;
            data  <= 8'd0;
            valid <= 1'b0;
            ferr  <= 1'b0;
        end else begin
            valid <= 1'b0;
            ferr  <= 1'b0;

            case (st)
                //-------------------------------------------------------------
                // 等起始位下降沿
                //-------------------------------------------------------------
                S_IDLE: begin
                    if (!rx_s2) begin          // 检测到低电平，可能是起始位
                        st  <= S_START;
                        cnt <= 16'd0;
                    end
                end

                //-------------------------------------------------------------
                // 等半个比特，确认仍然是低（滤掉毛刺）
                //-------------------------------------------------------------
                S_START: begin
                    if (cnt == HALF[15:0] - 1) begin
                        cnt <= 16'd0;
                        if (!rx_s2) begin
                            st   <= S_DATA;
                            bidx <= 3'd0;
                        end else begin
                            st <= S_IDLE;      // 是毛刺，丢掉
                        end
                    end else
                        cnt <= cnt + 1'b1;
                end

                //-------------------------------------------------------------
                // 每个比特周期采一位（采样点正好在比特正中）
                //-------------------------------------------------------------
                S_DATA: begin
                    if (cnt == DIV[15:0] - 1) begin
                        cnt <= 16'd0;
                        sh  <= {rx_s2, sh[7:1]};       // LSB 先到
                        if (bidx == 3'd7)
                            st <= S_STOP;
                        else
                            bidx <= bidx + 1'b1;
                    end else
                        cnt <= cnt + 1'b1;
                end

                //-------------------------------------------------------------
                // 检查停止位
                //-------------------------------------------------------------
                S_STOP: begin
                    if (cnt == DIV[15:0] - 1) begin
                        cnt   <= 16'd0;
                        st    <= S_IDLE;
                        data  <= sh;
                        valid <= 1'b1;
                        ferr  <= !rx_s2;           // 停止位应当为 1
                    end else
                        cnt <= cnt + 1'b1;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
