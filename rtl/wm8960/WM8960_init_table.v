//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    WM8960_init_table
// Module Name:    WM8960_init_table
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    WM8960_init_table.v - WM8960 初始化寄存器表
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module WM8960_init_table #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 6          // 装得下 33 条即可
) (
    input      [(ADDR_WIDTH-1):0] addr,
    input                         clk,
    output reg [(DATA_WIDTH-1):0] q
);

    localparam LUT_SIZE = 33;
    // ⚠️ 强制分布式 RAM（LUTRAM），不要 BRAM。
    //   表只有 33 条 x 16bit，用 BRAM 是浪费；而且一旦推断成 BRAM，
    //   ADDRARDADDR/ENARDEN 就会被带异步复位的寄存器驱动 -> [DRC REQP-1840]。
    //   （条目 31->33 时地址位 5->6，Vivado 突然改推 BRAM，警告就是这么冒出来的。）
    (* rom_style = "distributed" *) reg [DATA_WIDTH-1:0] rom [0:(2**ADDR_WIDTH)-1];

    initial begin
        rom[ 0] = {7'h0f, 9'b0_0000_0000};  // software reset (must be 1st)
        rom[ 1] = {7'h19, 9'b0_1111_1110};  // PWRMGMT1: VMIDSEL=01 VREF AINL AINR ADCL ADCR MICB=1
        rom[ 2] = {7'h2f, 9'b0_0011_1100};  // PWRMGMT3: LOMIX ROMIX LMIC RMIC
        rom[ 3] = {7'h22, 9'b1_0000_0000};  // L out mixer: LD2LO=1 (DAC -> L mixer)
        rom[ 4] = {7'h25, 9'b1_0000_0000};  // R out mixer: RD2RO=1 (DAC -> R mixer)
        rom[ 5] = {7'h1a, 9'b1_1110_0000};  // PWRMGMT2: DACL DACR LOUT1 ROUT1 SPKL SPKR
        rom[ 6] = {7'h08, 9'b1_1100_0100};  // CLOCKING2: BCLKDIV=0100 (/4)
        rom[ 7] = {7'h07, 9'b0_0100_1010};  // IFACE1: MS=1 I2S 24bit
        rom[ 8] = {7'h34, 9'b0_0011_1000};  // PLL N: PRESCALE=1 SDM=1 N=8
        rom[ 9] = {7'h35, 9'b0_0011_0001};  // PLL K[23:16]
        rom[10] = {7'h36, 9'b0_0010_0110};  // PLL K[15:8]
        rom[11] = {7'h37, 9'b0_1110_1001};  // PLL K[7:0] -> K=0x3126E9
        rom[12] = {7'h1a, 9'b1_1111_1001};  // PWRMGMT2 + PLLEN=1 -> PLL ON (SPKL/SPKR kept)
        rom[13] = {7'h20, 9'b1_0001_1000};  // ADCL path: LINPUT1 + LMIC2B=1 + PGA boost 13dB
        rom[14] = {7'h21, 9'b0_0000_0000};  // ADCR path: off (mono mic, DATSEL copies L to R)
        rom[15] = {7'h17, 9'b1_1100_0100};  // R23: TSDEN=1, DATSEL=01 (left ADC -> L and R)
        rom[16] = {7'h00, 9'b1_0010_0111};  // L in PGA: IPVU=1 LINMUTE=0 LINVOL +12dB
        rom[17] = {7'h01, 9'b1_0010_0111};  // R in PGA: IPVU=1 RINMUTE=0 RINVOL +12dB
        rom[18] = {7'h2b, 9'b0_0000_0000};  // L input boost: 0dB
        rom[19] = {7'h2c, 9'b0_0000_0000};  // R input boost: 0dB
        rom[20] = {7'h05, 9'b0_0000_0000};  // R5: DACMU=0 (unmute DAC!), ADCHPD=0 (ADC HPF on)
        rom[21] = {7'h15, 9'b1_1100_0011};  // L ADC digital vol 0dB
        rom[22] = {7'h16, 9'b1_1100_0011};  // R ADC digital vol 0dB
        rom[23] = {7'h0a, 9'b1_1111_1111};  // L DAC digital vol 0dB (update)
        rom[24] = {7'h0b, 9'b1_1111_1111};  // R DAC digital vol 0dB (update)
        rom[25] = {7'h02, 9'b1_1111_1001};  // LOUT1 vol +0dB
        rom[26] = {7'h03, 9'b1_1111_1001};  // ROUT1 vol +0dB
        // ⚠️⚠️ 这两条必须【关掉】（0 = -78.75dB ≈ 静音）
        //   原来它们把【模拟旁路】打开了 0 dB：
        //       LINPUT1 ──(模拟直通)──► LOUT1 / 喇叭
        //       RINPUT1 ──(模拟直通)──► ROUT1
        //   ⟹ 音频完全【绕过了 DAC、EQ、音量控制】，直接送到喇叭
        //   上板实测到的三个怪现象全都由此而来：
        //     ① 按 SPK 静音无效（我们清零的是 DAC 数据 ✗ 旁路不经过 DAC）
        //     ② 话筒只有【左】喇叭响（LINPUT1 只通 LOUT1）
        //     ③ 线路只有【右】喇叭响（RINPUT1 只通 ROUT1）
        //   ⟹ 关掉旁路，让信号走 ADC → FPGA(EQ/FFT) → DAC → 喇叭 ✓
        rom[27] = {7'h2d, 9'b0_0000_0000};  // L mixer bypass: OFF
        rom[28] = {7'h2e, 9'b0_0000_0000};  // R mixer bypass: OFF
        rom[29] = {7'h31, 9'b0_1111_0111};  // ClassD ctl: enable speakers
        rom[30] = {7'h28, 9'b1_0111_1111};  // L spk vol: SPKVU=1 +6dB (rst=MUTE)
        rom[31] = {7'h29, 9'b1_0111_1111};  // R spk vol: SPKVU=1 +6dB (rst=MUTE)
        rom[32] = {7'h04, 9'b0_0000_0101};  // CLOCKING1: SYSCLKDIV=/2 CLKSEL=PLL
    end

    // 读端口（综合成分布式 ROM）
    always @(posedge clk) begin
        q <= rom[addr];
    end

endmodule
