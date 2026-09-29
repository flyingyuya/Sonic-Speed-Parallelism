//=============================================================================
// uart_tx.v - UART 发送（8N1，参数化波特率）
//-----------------------------------------------------------------------------
// 用途：把配置查询的回执、上电横幅送回电脑，方便确认板子活着、参数改对了。
//
// 接口：拉高 `send` 一拍，模块把 `data` 按 8N1 发出去，期间 `busy` 为 1。
//       调用方必须等 `busy` 落回 0 才能发下一字节（否则会被丢掉）。
//=============================================================================
`timescale 1ns/1ps

module uart_tx #(
    parameter integer CLK_HZ = 48_000_000,
    parameter integer BAUD   = 115200
) (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       send,         // 1 拍脉冲
    input  wire [7:0] data,
    output reg        tx,           // 空闲为高
    output reg        busy
);

    localparam integer DIV = (CLK_HZ + BAUD / 2) / BAUD;

    localparam [1:0] S_IDLE = 2'd0, S_START = 2'd1, S_DATA = 2'd2, S_STOP = 2'd3;

    reg [1:0]  st;
    reg [15:0] cnt;
    reg [2:0]  bidx;
    reg [7:0]  sh;

    always @(posedge clk) begin
        if (!rst_n) begin
            st   <= S_IDLE;
            tx   <= 1'b1;
            busy <= 1'b0;
            cnt  <= 16'd0;
            bidx <= 3'd0;
            sh   <= 8'd0;
        end else begin
            case (st)
                S_IDLE: begin
                    tx <= 1'b1;
                    if (send) begin
                        sh   <= data;
                        st   <= S_START;
                        cnt  <= 16'd0;
                        busy <= 1'b1;
                    end else
                        busy <= 1'b0;
                end

                // 起始位：1 个比特周期的低电平
                S_START: begin
                    tx <= 1'b0;
                    if (cnt == DIV[15:0] - 1) begin
                        cnt  <= 16'd0;
                        bidx <= 3'd0;
                        st   <= S_DATA;
                    end else
                        cnt <= cnt + 1'b1;
                end

                // 8 位数据，LSB 先发
                S_DATA: begin
                    tx <= sh[0];
                    if (cnt == DIV[15:0] - 1) begin
                        cnt <= 16'd0;
                        sh  <= {1'b1, sh[7:1]};
                        if (bidx == 3'd7)
                            st <= S_STOP;
                        else
                            bidx <= bidx + 1'b1;
                    end else
                        cnt <= cnt + 1'b1;
                end

                // 停止位：1 个比特周期的高电平
                S_STOP: begin
                    tx <= 1'b1;
                    if (cnt == DIV[15:0] - 1) begin
                        cnt  <= 16'd0;
                        st   <= S_IDLE;
                        busy <= 1'b0;
                    end else
                        cnt <= cnt + 1'b1;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
