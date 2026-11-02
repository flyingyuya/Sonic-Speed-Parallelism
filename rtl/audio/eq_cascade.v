//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    eq_cascade
// Module Name:    eq_cascade
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    eq_cascade.v - 多段双二阶（Biquad）均衡器，时分复用 MAC
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module eq_cascade #(
    parameter integer DW    = 24,   // 数据位宽 Q1.(DW-1)
    parameter integer CW    = 18,   // 系数位宽 Q2.(CW-2)
    parameter integer CF    = 16,   // 系数小数位（CW=18,CF=16 -> Q2.16）
    parameter integer AW    = 48,   // 状态累加器位宽
    parameter integer NSECT = 5     // 双二阶段数
) (
    input  wire clk,
    input  wire rst_n,

    // ---- 系数写入（控制域同步过来的信号）----
    input  wire                    coe_we,
    input  wire [$clog2(NSECT*5)-1:0] coe_addr,
    input  wire signed [CW-1:0]    coe_wdata,

    input  wire                    bypass,      // 1: 直通（保留滤波器内部状态）

    // ---- 样本流 ----
    input  wire signed [DW-1:0]    x_in,
    input  wire                    x_valid,
    output wire                    x_ready,     // 空闲时可接收

    output reg  signed [DW-1:0]    y_out,
    output reg                     y_valid
);

    localparam integer SH = CF;                 // 乘积 -> 样本 的右移位数 = 16

    localparam [AW-1:0] RND  = {{(AW-1){1'b0}}, 1'b1} << (SH-1);  // 四舍五入偏置
    localparam signed [DW-1:0] MAXV = {1'b0, {(DW-1){1'b1}}};
    localparam signed [DW-1:0] MINV = {1'b1, {(DW-1){1'b0}}};

    localparam IDLE = 1'b0, CALC = 1'b1;

    localparam integer SAW = (NSECT > 1) ? $clog2(NSECT) : 1;

    reg                    state;
    reg [SAW-1:0]          sect;
    reg signed [DW-1:0]    x_cur;
    reg signed [DW-1:0]    x_sav;

    reg signed [CW-1:0]    coe  [0:NSECT*5-1];
    reg signed [AW-1:0]    st1  [0:NSECT-1];
    reg signed [AW-1:0]    st2  [0:NSECT-1];

    integer i;

    //-------------------------------------------------------------------------
    // 组合运算通路（每个时钟处理一个 section）
    //-------------------------------------------------------------------------
    wire signed [CW-1:0] b0 = coe[sect*5 + 0];
    wire signed [CW-1:0] b1 = coe[sect*5 + 1];
    wire signed [CW-1:0] b2 = coe[sect*5 + 2];
    wire signed [CW-1:0] a1 = coe[sect*5 + 3];
    wire signed [CW-1:0] a2 = coe[sect*5 + 4];

    wire signed [DW+CW-1:0] p0  = x_cur * b0;
    wire signed [DW+CW-1:0] p1  = x_cur * b1;
    wire signed [DW+CW-1:0] p2  = x_cur * b2;

    wire signed [AW-1:0]    acc = p0 + st1[sect];
    wire signed [AW-1:0]    accr = acc + RND;
    wire signed [AW-1:0]    ysh = accr >>> SH;

    wire ovf_p = (ysh > MAXV);
    wire ovf_n = (ysh < MINV);

    wire signed [DW-1:0]    yn = ovf_p ? MAXV : (ovf_n ? MINV : ysh[DW-1:0]);

    wire signed [DW+CW-1:0] pa1 = yn * a1;
    wire signed [DW+CW-1:0] pa2 = yn * a2;

    wire signed [AW-1:0]    st1n = p1 + st2[sect] - pa1;
    wire signed [AW-1:0]    st2n = p2 - pa2;

    assign x_ready = (state == IDLE);

    //-------------------------------------------------------------------------
    // 状态机
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            state   <= IDLE;
            sect    <= {SAW{1'b0}};
            x_cur   <= {DW{1'b0}};
            x_sav   <= {DW{1'b0}};
            y_out   <= {DW{1'b0}};
            y_valid <= 1'b0;
            for (i = 0; i < NSECT; i = i + 1) begin
                st1[i] <= {AW{1'b0}};
                st2[i] <= {AW{1'b0}};
            end
        end else begin
            y_valid <= 1'b0;

            if (coe_we) coe[coe_addr] <= coe_wdata;

            case (state)
                IDLE: begin
                    if (x_valid) begin
                        x_cur <= x_in;
                        x_sav <= x_in;
                        sect  <= {SAW{1'b0}};
                        state <= CALC;
                    end
                end

                CALC: begin
                    st1[sect] <= st1n;
                    st2[sect] <= st2n;
                    x_cur     <= yn;            // 级联到下一段
                    if (sect == NSECT-1) begin
                        y_out   <= bypass ? x_sav : yn;
                        y_valid <= 1'b1;
                        state   <= IDLE;
                    end else begin
                        sect <= sect + 1'b1;
                    end
                end

                // 1bit 状态已用满，default 不可达
                default: state <= IDLE;
            endcase
        end
    end

endmodule
