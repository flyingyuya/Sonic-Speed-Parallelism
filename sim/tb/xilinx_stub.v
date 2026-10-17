//=============================================================================
// xilinx_stub.v - Xilinx 原语的仿真行为模型
//-----------------------------------------------------------------------------
// ⚠️ 本文件【仅供 iverilog 仿真】，绝对不要加进 Vivado 工程。
//    Vivado 自带真实的 unisims 库，用真实模型；iverilog 没有，
//    所以整机仿真必须自己提供一份最小行为模型。
//
//    （另一条路是用 Vivado 自带的 xsim，见 scripts/sim/run_xsim.sh，
//      那个能跑到真实的 MMCM 行为。日常快速冒烟用这里的 stub 更快。）
//
// 实现取舍：
//   MMCM 这里**忽略输入时钟**，直接按 CLKIN1_PERIOD / DIVCLK_DIVIDE /
//   CLKFBOUT_MULT_F / CLKOUTn_DIVIDE 算出输出周期后自由振荡。
//   整机冒烟只关心"两个时钟频率对不对、LOCKED 会不会拉高"，
//   不关心它和 200 MHz 的相位关系，所以够用。
//=============================================================================
`timescale 1ns/1ps

//-----------------------------------------------------------------------------
// 差分输入缓冲：只看正端
//-----------------------------------------------------------------------------
module IBUFDS #(
    parameter DIFF_TERM    = "FALSE",
    parameter IBUF_LOW_PWR = "TRUE",
    parameter IOSTANDARD   = "DEFAULT"
) (
    output wire O,
    input  wire I,
    input  wire IB
);
    assign O = I;
endmodule

//-----------------------------------------------------------------------------
// 全局时钟缓冲：直通
//-----------------------------------------------------------------------------
module BUFG (
    input  wire I,
    output wire O
);
    assign O = I;
endmodule

//-----------------------------------------------------------------------------
// MMCM：按分频比算出两个输出时钟，忽略输入
//-----------------------------------------------------------------------------
module MMCME2_BASE #(
    parameter BANDWIDTH          = "OPTIMIZED",
    parameter STARTUP_WAIT       = "FALSE",
    parameter real    CLKIN1_PERIOD    = 10.000,
    parameter integer DIVCLK_DIVIDE    = 1,
    parameter real    CLKFBOUT_MULT_F  = 10.000,
    parameter real    CLKFBOUT_PHASE   = 0.000,
    parameter real    CLKOUT0_DIVIDE_F = 10.000,
    parameter real    CLKOUT0_DUTY_CYCLE = 0.500,
    parameter real    CLKOUT0_PHASE    = 0.000,
    parameter integer CLKOUT1_DIVIDE   = 1,
    parameter real    CLKOUT1_DUTY_CYCLE = 0.500,
    parameter real    CLKOUT1_PHASE    = 0.000,
    // CLKOUT2/3 的分频比。默认给一个大数：没用到的输出就保持慢速翻转，
    // 避免默认值 1 时产生极快的时钟把仿真拖慢（第一版这里默认 1，很危险）。
    parameter integer CLKOUT2_DIVIDE   = 1000,
    parameter real    CLKOUT2_DUTY_CYCLE = 0.500,
    parameter real    CLKOUT2_PHASE    = 0.000,
    parameter integer CLKOUT3_DIVIDE   = 1000,
    parameter real    CLKOUT3_DUTY_CYCLE = 0.500,
    parameter real    CLKOUT3_PHASE    = 0.000,
    parameter real    REF_JITTER1      = 0.010
) (
    output wire CLKOUT0, CLKOUT1, CLKOUT2, CLKOUT3, CLKOUT4, CLKOUT5, CLKOUT6,
    output wire CLKOUT0B, CLKOUT1B, CLKOUT2B, CLKOUT3B,
    output wire CLKFBOUT, CLKFBOUTB,
    output wire LOCKED,
    input  wire CLKIN1, CLKFBIN, PWRDWN, RST
);
    // VCO 周期 = 输入周期 x DIVCLK / MULT
    localparam real VCO_P   = CLKIN1_PERIOD * DIVCLK_DIVIDE / CLKFBOUT_MULT_F;
    // 输出半周期 = VCO 周期 x 分频比 / 2
    localparam real C0_HALF = VCO_P * CLKOUT0_DIVIDE_F / 2.0;
    localparam real C1_HALF = VCO_P * CLKOUT1_DIVIDE   / 2.0;
    localparam real C2_HALF = VCO_P * CLKOUT2_DIVIDE   / 2.0;
    localparam real C3_HALF = VCO_P * CLKOUT3_DIVIDE   / 2.0;

    reg c0 = 1'b0;
    reg c1 = 1'b0;
    reg c2 = 1'b0;
    reg c3 = 1'b0;
    reg lk = 1'b0;

    always #(C0_HALF) c0 = ~c0;
    always #(C1_HALF) c1 = ~c1;
    always #(C2_HALF) c2 = ~c2;
    always #(C3_HALF) c3 = ~c3;

    // 等若干输入沿再给 LOCKED，模拟真实的锁相过程
    initial begin
        repeat (20) @(posedge CLKIN1);
        @(negedge CLKIN1) lk = 1'b1;
    end

    assign CLKOUT0  = c0;
    assign CLKOUT1  = c1;
    assign CLKOUT2  = c2;
    assign CLKOUT3  = c3;
    assign CLKOUT4  = 1'b0;
    assign CLKOUT5  = 1'b0;
    assign CLKOUT6  = 1'b0;
    assign CLKOUT0B = ~c0;
    assign CLKOUT1B = ~c1;
    assign CLKOUT2B = 1'b1;
    assign CLKOUT3B = 1'b1;
    assign CLKFBOUT = c0;
    assign CLKFBOUTB= ~c0;
    assign LOCKED   = lk;

endmodule

//=============================================================================
// OSERDESE2 —— 行为级模型（只给 iverilog 仿真用，综合时用 Xilinx 真原语）
//=============================================================================
// 【为什么需要它】OSERDESE2 是 Xilinx 原语，iverilog 不认识。
//
// 【模型做到什么程度】
//   做到了"真的串行化"：CLKDIV 上升沿装入并行数据，然后在 CLK 的上升沿和
//   下降沿依次吐出 bit0、bit1、……、bit9（DDR，5 个 CLK 周期吐 10 位）。
//   所以 TB 能验证【位序】—— 这是最容易搞错、也最影响画面的地方。
//   不做的部分：TQ/TBYTE 三态、OFB 反馈 —— 本项目用不到。
//
// 【级联关系（依据 A7_LITE 教程原文）】
//   MASTER 承接 10bit 数据的【低 8 位】：D1=din[0] ... D8=din[7]
//   SLAVE  的 D3/D4 承接【高 2 位】：D3=din[8], D4=din[9]
//   SLAVE 的 SHIFTOUT1/2 -> MASTER 的 SHIFTIN1/2
//   输出顺序：由低位到高位（TMDS 规定先发 din[0]）
//=============================================================================
module OSERDESE2 #(
    parameter         DATA_RATE_OQ   = "DDR",
    parameter         DATA_RATE_TQ   = "DDR",
    parameter integer DATA_WIDTH     = 10,
    parameter         INIT_OQ        = 1'b0,
    parameter         INIT_TQ        = 1'b0,
    parameter         SERDES_MODE    = "MASTER",
    parameter         SRVAL_OQ       = 1'b0,
    parameter         SRVAL_TQ       = 1'b0,
    parameter         TBYTE_CTL      = "FALSE",
    parameter         TBYTE_SRC      = "FALSE",
    parameter integer TRISTATE_WIDTH = 1
) (
    output wire OFB,
    output wire OQ,
    output wire SHIFTOUT1,
    output wire SHIFTOUT2,
    output wire TBYTEOUT,
    output wire TFB,
    output wire TQ,

    input  wire D1, D2, D3, D4, D5, D6, D7, D8,
    input  wire CLK,
    input  wire CLKDIV,
    input  wire SHIFTIN1,
    input  wire SHIFTIN2,
    input  wire T1, T2, T3, T4,
    input  wire TBYTEIN,
    input  wire TCE,
    input  wire RST
);

    // SLAVE 只把高 2 位"递"给 MASTER，自己不出数据
    assign SHIFTOUT1 = D3;          // din[8]
    assign SHIFTOUT2 = D4;          // din[9]

    reg [9:0] sr;                   // 待串行化的 10 位
    reg [3:0] bi;                   // 已经吐出几位
    reg       oq_r;

    wire is_master = (SERDES_MODE == "MASTER");

    initial begin
        sr   = 10'd0;
        bi   = 4'd0;
        oq_r = INIT_OQ;
    end

    // 装入：每个 CLKDIV 周期装一次
    always @(posedge CLKDIV) begin
        if (RST) begin
            sr <= 10'd0;
            bi <= 4'd0;
        end else begin
            // {高2位(来自SLAVE), 低8位(本地)}
            sr <= {SHIFTIN2, SHIFTIN1, D8, D7, D6, D5, D4, D3, D2, D1};
            bi <= 4'd0;
        end
    end

    // 吐出：DDR，上升沿和下降沿各吐一位。
    // ⚠️ bi 必须【在 10 以内回绕】：第一版直接 bi+1 / bi+2，
    //    数到 10 之后就读 sr[10]、sr[11]（越界）= X，
    //    串行流里就会夹着 x —— 这是被 tb_tmds_out 抓出来的（stub 自己的 bug）。
    wire [3:0] bi_lo = (bi >= 4'd10) ? (bi - 4'd10) : bi;           // 当前位
    wire [3:0] bi_nx1 = (bi_lo + 4'd1 >= 4'd10) ? (bi_lo + 4'd1 - 4'd10)
                                                : (bi_lo + 4'd1);   // 下一位
    wire [3:0] bi_nx2 = (bi_nx1 + 4'd1 >= 4'd10) ? (bi_nx1 + 4'd1 - 4'd10)
                                                 : (bi_nx1 + 4'd1); // 再下一位

    always @(posedge CLK) if (is_master && !RST) begin
        oq_r <= sr[bi_lo];
        bi   <= bi_nx1;
    end

    always @(negedge CLK) if (is_master && !RST) begin
        oq_r <= sr[bi_nx1];
        bi   <= bi_nx2;
    end

    assign OQ  = is_master ? oq_r : 1'b0;
    assign OFB = 1'b0;
    assign TBYTEOUT = 1'b0;
    assign TFB = 1'b0;
    assign TQ  = 1'b0;

endmodule

//=============================================================================
// OBUFDS —— 行为级模型（单端转差分）
//=============================================================================
module OBUFDS (
    output wire O,
    output wire OB,
    input  wire I,
    input  wire T
);
    assign O  = I;
    assign OB = ~I;
endmodule
