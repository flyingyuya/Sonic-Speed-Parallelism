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

    reg c0 = 1'b0;
    reg c1 = 1'b0;
    reg lk = 1'b0;

    always #(C0_HALF) c0 = ~c0;
    always #(C1_HALF) c1 = ~c1;

    // 等若干输入沿再给 LOCKED，模拟真实的锁相过程
    initial begin
        repeat (20) @(posedge CLKIN1);
        @(negedge CLKIN1) lk = 1'b1;
    end

    assign CLKOUT0  = c0;
    assign CLKOUT1  = c1;
    assign CLKOUT2  = 1'b0;
    assign CLKOUT3  = 1'b0;
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
