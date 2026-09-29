//=============================================================================
// uart_rx.v - UART 接收（8N1，参数化波特率）
//-----------------------------------------------------------------------------
// 【为什么不用 rtl/common/uart_byte_rx.v】
//   那份参考工程抄过来的代码里有 `rx_r[0] <= #1 uart_rx;` 这种**延时赋值**。
//   Vivado 综合时会报"ignored delay"警告，而本工程要求零警告。
//   另外它的时钟频率写死 50 MHz，我们是 48 MHz。
//   所以重写一份：无延时、全参数化、和工程风格一致。
//
// 【采样策略】
//   不用 16 倍过采样，直接"每个比特周期数 DIV 个 clk、在正中采样"：
//       等半个比特 -> 确认起始位仍是 0（滤掉毛刺）
//       然后每 DIV 个 clk 采一位，共 8 位
//       最后检查停止位 = 1，否则报帧错误
//   误差余量：115200 baud @48MHz 时 DIV = 416.7 -> 取整 416，
//   累积到第 10 位偏差 0.16%，远小于半个比特（50%）。
//=============================================================================
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
