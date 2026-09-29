//=============================================================================
// WM8960_init_table.v - WM8960 初始化寄存器表
//-----------------------------------------------------------------------------
// ⚠️ 本文件由 scripts/golden/gen_wm8960_table.py 自动生成，请勿手工修改。
//    要改寄存器值请编辑脚本里的 SPEC 表然后重新生成。
//
// 数据来源：docs/WM8960模块/WM8960_v4.2.pdf
//   Table 39/40/41/44/45 + 寄存器位域表（P57~61）
//   推导过程见 docs/09-wm8960-module.md §2.5
//
// 表项格式：{7 位寄存器地址, 9 位数据}
//   WM8960 的 2-wire 协议是 16 位字：[15:9]=寄存器地址，[8:0]=数据。
//   I2C 按字节发，所以高字节 = {reg[6:0], data[8]}、低字节 = data[7:0]。
//   这就是 WM8960_init.v 里 `addr = lut[15:8]` / `wrdata = lut[7:0]` 的由来 ——
//   9 位数据的最高位藏在 addr 的 bit0 里，不是被截断。
//
// 【本表在做什么】
//   R15  软复位（必须第一条）
//   R25  PWRMGMT1：VMIDSEL=11(快速启动) + VREF/AINL/AINR/ADCL/ADCR 上电
//   R47  PWRMGMT3：LOMIX/ROMIX（播放混音器）
//   R26  PWRMGMT2：DACL/DACR/LOUT1/ROUT1 上电（此刻 PLLEN 还是 0）
//   R8   CLOCKING2：BCLKDIV=0100 -> BCLK = SYSCLK/4
//   R7   IFACE1：MS=1（WM8960 当 I2S 主）、WL=24bit、I2S 格式
//   R52~R55 PLL：PRESCALE=1(24MHz/2=12MHz 进 PLL)、SDM=1(分数模式)、
//           N=8、K=0x3126E9  ->  f2=98.304MHz，SYSCLK=12.288MHz
//   R26  再写一次，加上 PLLEN=1  <-- PLL 从这里开始锁定
//   R2/R3/R21/R22/R45/R46/R43/R44  各路音量与混音，顺便等 PLL 锁好
//   R4   CLOCKING1：SYSCLKDIV=/2 + CLKSEL=1  <-- 最后一步才切到 PLL
//
// 【顺序不能随便改】：
//   · 软复位必须第一条
//   · PLL 配置(K/N/PRESCALE)必须在 PLLEN 之前
//   · CLKSEL=1 必须最后 —— 切过去之前要给 PLL 留够锁定时间
//     （由 WM8960_init.v 的 DLY_MS 参数保证，每条之间留 1 ms）
//=============================================================================
`timescale 1ns/1ps

module WM8960_init_table #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 5          // 装得下 20 条即可
) (
    input      [(ADDR_WIDTH-1):0] addr,
    input                         clk,
    output reg [(DATA_WIDTH-1):0] q
);

    localparam LUT_SIZE = 20;
    reg [DATA_WIDTH-1:0] rom [0:(2**ADDR_WIDTH)-1];

    initial begin
        rom[ 0] = {7'h0f, 9'b0_0000_0000};  // software reset (must be 1st)
        rom[ 1] = {7'h19, 9'b1_1111_1100};  // PWRMGMT1: VMIDSEL=11 VREF AINL AINR
        rom[ 2] = {7'h2f, 9'b0_0000_1100};  // PWRMGMT3: LOMIX ROMIX
        rom[ 3] = {7'h1a, 9'b1_1110_0000};  // PWRMGMT2: DACL DACR LOUT1 ROUT1
        rom[ 4] = {7'h08, 9'b1_1100_0100};  // CLOCKING2: BCLKDIV=0100 (/4)
        rom[ 5] = {7'h07, 9'b0_0100_1010};  // IFACE1: MS=1 I2S 24bit
        rom[ 6] = {7'h34, 9'b0_0011_1000};  // PLL N: PRESCALE=1 SDM=1 N=8
        rom[ 7] = {7'h35, 9'b0_0011_0001};  // PLL K[23:16]
        rom[ 8] = {7'h36, 9'b0_0010_0110};  // PLL K[15:8]
        rom[ 9] = {7'h37, 9'b0_1110_1001};  // PLL K[7:0] -> K=0x3126E9
        rom[10] = {7'h1a, 9'b1_1110_0001};  // PWRMGMT2 + PLLEN=1 -> PLL ON
        rom[11] = {7'h02, 9'b1_1111_1001};  // LOUT1 vol +0dB
        rom[12] = {7'h03, 9'b1_1111_1001};  // ROUT1 vol +0dB
        rom[13] = {7'h15, 9'b1_1100_0011};  // L ADC vol 0dB
        rom[14] = {7'h16, 9'b1_1100_0011};  // R ADC vol 0dB
        rom[15] = {7'h2d, 9'b0_1000_0000};  // L mixer bypass 0dB
        rom[16] = {7'h2e, 9'b0_1000_0000};  // R mixer bypass 0dB
        rom[17] = {7'h2b, 9'b1_0101_0000};  // L input boost LIN3 = 0dB
        rom[18] = {7'h2c, 9'b0_0000_1010};  // R input boost RIN2 = 0dB
        rom[19] = {7'h04, 9'b0_0000_0101};  // CLOCKING1: SYSCLKDIV=/2 CLKSEL=PLL
    end

    // 读端口（综合成分布式 ROM）
    always @(posedge clk) begin
        q <= rom[addr];
    end

endmodule
