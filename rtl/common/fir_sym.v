//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    fir_sym
// Module Name:    fir_sym
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    fir_sym.v - 对称（线性相位）FIR 低通，用于波形平滑
// Dependencies:   fir_sym_coeff.vh
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module fir_sym #(
    parameter integer DW     = 24,
    // 系数的小数位数
    parameter integer CF     = 16,
    // 1 = 旁路（输出直接等于输入），给测试做 A/B 用。
    parameter integer BYPASS = 0
) (
    input  wire                 clk,
    input  wire                 rst_n,      // 同步复位
    input  wire                 en,         // 采样有效
    input  wire signed [DW-1:0] din,
    output reg  signed [DW-1:0] dout
);

    // 抽头数 / 配对数 / 系数位宽，以及系数查询函数（自动生成的）
    `include "fir_sym_coeff.vh"

    localparam integer ACW = DW + FIR_CW + 4;       // 累加器位宽（含保护位）

    localparam signed [DW-1:0] V_MAX = {1'b0, {(DW-1){1'b1}}};
    localparam signed [DW-1:0] V_MIN = {1'b1, {(DW-1){1'b0}}};

    //=========================================================================
    // 延迟线：sr[0] = 最新采样，sr[N-1] = 最旧
    //=========================================================================
    reg signed [DW-1:0] sr [0:FIR_N-1];

    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < FIR_N; i = i + 1)
                sr[i] <= {DW{1'b0}};
        end else if (en) begin
            sr[0] <= din;
            for (i = 1; i < FIR_N; i = i + 1)
                sr[i] <= sr[i-1];
        end
    end

    //=========================================================================
    // 对称配对求和：psum[k] = x[k] + x[N-1-k]
    //=========================================================================
    wire signed [DW:0] psum [0:FIR_M-1];

    genvar g;
    generate
        for (g = 0; g < FIR_M; g = g + 1) begin : gen_pair
            assign psum[g] = sr[g] + sr[FIR_N-1-g];
        end
    endgenerate

    //=========================================================================
    // 卷积（纯组合，写成 generate 加法链）
    //-----------------------------------------------------------------------------
    // 统一成一个抽头数组：前 M 个是配对和，最后一个是中心抽头
    wire signed [DW:0] tap [0:FIR_M];

    generate
        for (g = 0; g < FIR_M; g = g + 1) begin : gen_tap
            assign tap[g] = psum[g];
        end
    endgenerate

    assign tap[FIR_M] = sr[FIR_M];      // 中心抽头只算一次

    // 累加链：acc[0] = c0*tap0, acc[k] = acc[k-1] + ck*tapk
    wire signed [ACW-1:0] acc [0:FIR_M];

    generate
        for (g = 0; g <= FIR_M; g = g + 1) begin : gen_mac
            if (g == 0) begin : gen_first
                assign acc[0] = fir_coef(0) * tap[0];
            end else begin : gen_rest
                assign acc[g] = acc[g-1] + (fir_coef(g) * tap[g]);
            end
        end
    endgenerate

    wire signed [ACW-1:0] acc_sum = acc[FIR_M];

    //=========================================================================
    // 取整 + 饱和
    //=========================================================================
    // 乘积累加是 Q1.23 的 2^16 倍，右移【CF = 16】位回来
    localparam signed [ACW-1:0] RND = (1 <<< (CF-1));

    wire signed [ACW-1:0] ysh = (acc_sum + RND) >>> CF;
    wire [DW-1:0]         ylo = ysh[DW-1:0];
    wire                  ovf = (ysh[ACW-1:DW] != {(ACW-DW){ysh[DW-1]}});

    always @(posedge clk) begin
        if (!rst_n) begin
            dout <= {DW{1'b0}};
        end else if (en) begin
            if (BYPASS != 0)     dout <= din;
            else if (ovf)        dout <= ysh[ACW-1] ? V_MIN : V_MAX;
            else                 dout <= ylo;
        end
    end

endmodule
