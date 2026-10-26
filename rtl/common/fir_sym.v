//////////////////////////////////////////////////////////////////////////////////
// Company:        个人项目 / SonicTwin-Engine
// Engineer:       flyingyu
//
// Create Date:    2026-10-26
// Design Name:    fir_sym
// Module Name:    fir_sym
// Project Name:   音速双擎（SonicTwin-Engine）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    fir_sym.v - 对称（线性相位）FIR 低通，用于波形平滑
//                 【为什么需要它】
//                 波形显示的两个用途：
// Dependencies:   见文件内 `include
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module fir_sym #(
    parameter integer DW     = 24,
    // 系数的小数位数。**必须显式给，不能从位宽推** —— 见下面第 4 节的说明。
    //   本项目系数用 Q2.16：总共 18 位，其中 2 位整数、**16 位小数** -> CF = 16。
    //   而 CW（存储位宽）= 18。用 18 去移位会多移 2 位，也就是把结果缩小 4 倍。
    parameter integer CF     = 16,
    // 1 = 旁路（输出直接等于输入）。给测试做 A/B 用。
    parameter integer BYPASS = 0
) (
    input  wire                 clk,
    input  wire                 rst_n,      // 同步复位（本项目惯例）
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
    // 1. 延迟线：sr[0] = 最新采样，sr[N-1] = 最旧
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
    // 2. 对称配对求和：psum[k] = x[k] + x[N-1-k]
    //-----------------------------------------------------------------------------
    //   ⚠️ 位宽要 +1：两个 24 位有符号相加，结果可能是 25 位。
    //      不加这一位，-FS + -FS 就会回绕成正数（账本第 60 条同族：
    //      推导位宽要按【最大值】算）。
    //=========================================================================
    wire signed [DW:0] psum [0:FIR_M-1];

    genvar g;
    generate
        for (g = 0; g < FIR_M; g = g + 1) begin : gen_pair
            assign psum[g] = sr[g] + sr[FIR_N-1-g];
        end
    endgenerate

    //=========================================================================
    // 3. 卷积（纯组合，写成 generate 加法链）
    //-----------------------------------------------------------------------------
    //   ⚠️ 为什么不用 `always @(*)` + for 循环来做这个累加：
    //      iverilog 会对每次数组读都发一条
    //      "@* is sensitive to all N words in array 'xxx'" 警告。
    //      而本项目的要求是【零警告】（不是把警告压掉，是别写会招警告的写法）。
    //      改成 generate 链之后，既没有敏感度问题，
    //      结构也更直白 —— 就是 8 个抽头的依次累加。
    //
    //   fir_coef(k) 的 k 在 generate 里是常数 -> 综合器直接常量折叠，
    //   系数表一个 LUT 都不占。
    //=========================================================================
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

    //   ⚠️ generate 里的 if/else 也必须起名字：否则 Verilator 报
    //      GENUNNAMED（IEEE 1800-2023 27.6 要求 generate 块有名）。
    //      这是能修的，所以不放进豁免白名单。
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
    // 4. 取整 + 饱和
    //=========================================================================
    //   乘积累加是 Q1.23 的 2^16 倍，右移【CF = 16】位回来。
    //
    //   ⚠️ 移位数是【小数位数 CF】，不是【系数存储位宽 CW】！
    //      两者都是 18/16，差 2 —— 我第一次就是按 CW 移的，
    //      结果整个 FIR 的输出被缩小了 4 倍。
    //      换成别的格式（比如 Q1.17）时，CW 和 CF 不同，这个错更隐蔽。
    //      结论：**移位量要跟着"小数点在哪"走，不能跟着"存了几位"走。**
    //
    //   加 2^(CF-1) 做四舍五入（算术右移是向 -inf 取整的，不补这一下会有负向偏置，
    //   而我们刚花了一个 dc_block 去直流，这里再引入一个就太荒唐了）。
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
