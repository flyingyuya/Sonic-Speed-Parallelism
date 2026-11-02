//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    WM8960_init
// Module Name:    WM8960_init
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    WM8960_init.v - WM8960 上电初始化（通过 I2C 顺序写寄存器表）
// Dependencies:   wm8960_nreg.vh   i2c_control.v
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps


module WM8960_init #(
    parameter integer CLK_FREQ_HZ = 48_000_000,   // 本模块工作时钟频率
    parameter integer DLY_MS      = 1             // 每条寄存器之间插入的延时(ms)
) (
    input           Clk,
    input           Rst_n,

    input           Go,
    input [7:0]     device_id,     // I2C 7 位地址 + R/W 位（WM8960 = 0x34）

    //--------------------- 输入源选择 ---------------------
    //   0 = 话筒（LINPUT1）   1 = 线路输入（LINPUT3/INPUTR3）
    //   只影响 R32/R33/R0/R1 四条，其余完全一样
    //   话筒 0x118 = LMN1 + boost 01(+13dB) + LMIC2B
    //   线路 0x088 = LMP3 + boost 00( 0dB) + LMIC2B
    input           src_sel,
    output reg      Init_Done,

    output          i2c_sclk,
    inout           i2c_sdat
);

    //=========================================================================
    // 寄存器表（内容由 scripts/golden/gen_wm8960_table.py 生成）
    //=========================================================================
    `include "wm8960_nreg.vh"

    localparam integer LUT_SIZE = WM8960_NREG;     // 本表实际条数
    localparam integer TBL_AW   = $clog2(LUT_SIZE);// 恰好装得下 LUT_SIZE 的位宽
    localparam integer DLY_CNT  = CLK_FREQ_HZ / 1000 * DLY_MS;
    localparam        ADDR_MODE = 1'b0;

    wire [TBL_AW-1:0] tbl_addr;

    wire [15:0] lut_raw;                            // ROM 原始输出

    WM8960_init_table #(
        .ADDR_WIDTH (TBL_AW)
    ) WM8960_init_table (
        .addr (tbl_addr),
        .clk  (Clk),
        .q    (lut_raw)
    );

    //-------------------------------------------------------------------------
    // 输入源覆盖
    //-------------------------------------------------------------------------
    wire [6:0] lut_reg = lut_raw[15:9];
    wire [15:0] lut = !src_sel ? lut_raw  // 话筒模式【原样输出】
        // R32 输入信号路径 L：LINPUT3 + 0dB + LMIC2B
        : (lut_reg == 7'h20) ? {7'h20, 9'h088}
        // R33：线路模式下把【右路】接到 RINPUT1（bit8 = RMN1）
        : (lut_reg == 7'h21) ? {7'h21, 9'h108}
        : (lut_reg == 7'h00) ? {7'h00, 9'h117}   // R0  PGA 音量 L：0dB
        : (lut_reg == 7'h01) ? {7'h01, 9'h117}   // R1  PGA 音量 R：0dB
        // R23（0x17）：DATSEL 改成 11 = 【单声道混合 (L+R)/2 → 两路 DAC】
        : (lut_reg == 7'h17) ? {7'h17, 9'b1_1100_0111}
        // R45/R46：模拟旁路【只在线路模式下打开】
        : (lut_reg == 7'h2D) ? {7'h2D, 9'b0_1000_0000}   // L bypass ON（仅线路）
        : (lut_reg == 7'h2E) ? {7'h2E, 9'b0_1000_0000}   // R bypass ON（仅线路）
        : lut_raw;

    // lut = {7 位寄存器地址, 9 位数据}
    //   I2C 按字节发 16 位字：高字节 = {reg[6:0], data[8]}，低字节 = data[7:0]
    wire [7:0] addr   = lut[15:8];
    wire [7:0] wrdata = lut[7:0];

    reg  [7:0] cnt;                                // 表项计数器
    reg        wrreg_req;
    reg  [1:0] state;

    wire [7:0] rddata;
    wire       RW_Done;
    wire       ack;

    assign tbl_addr = cnt[TBL_AW-1:0];

    //-------------------------------------------------------------------------
    // I2C 字节级控制器
    //-------------------------------------------------------------------------
    i2c_control #(
        .SYS_CLOCK(CLK_FREQ_HZ),
        .SCL_CLOCK()
    ) i2c_control (
        .Clk         (Clk),
        .Rst_n       (Rst_n),

        .wrreg_req   (wrreg_req),
        .rdreg_req   (1'b0),          // 只写不读（显式 1 位，避免位宽告警）
        .addr        ({8'h00, addr}), // 8 位寄存器地址扩展到 16 位端口
        .addr_mode   (ADDR_MODE),
        .wrdata      (wrdata),
        .rddata      (rddata),
        .device_id   (device_id),
        .RW_Done     (RW_Done),
        .ack         (ack),

        .dly_cnt_max (DLY_CNT),       // 每条之间留出 PLL 锁定时间
        .i2c_sclk    (i2c_sclk),
        .i2c_sdat    (i2c_sdat)
    );

    //-------------------------------------------------------------------------
    // 表项计数器
    //-------------------------------------------------------------------------
    always @(posedge Clk or negedge Rst_n) begin
        if (!Rst_n)
            cnt <= 8'd0;
        else if (Go)
            cnt <= 8'd0;
        else if (cnt < LUT_SIZE) begin
            if (RW_Done && (!ack))
                cnt <= cnt + 1'b1;
            else
                cnt <= cnt;
        end else
            cnt <= cnt;                            // 保持，不回绕
    end

    //-------------------------------------------------------------------------
    // 完成标志：写完最后一条之后拉高并保持
    //-------------------------------------------------------------------------
    always @(posedge Clk or negedge Rst_n) begin
        if (!Rst_n)
            Init_Done <= 1'b0;
        else if (Go)
            Init_Done <= 1'b0;
        else if (cnt == LUT_SIZE)
            Init_Done <= 1'b1;
    end

    //-------------------------------------------------------------------------
    // 主状态机：0=空闲  1=发起一次写  2=等这次写完
    //-------------------------------------------------------------------------
    always @(posedge Clk or negedge Rst_n) begin
        if (!Rst_n) begin
            state     <= 2'd0;
            wrreg_req <= 1'b0;
        // 新增 Go 分支，【直接置 state=1】绕过门控
        end else if (Go) begin
            state     <= 2'd1;              // 直接发起第一条写
            wrreg_req <= 1'b0;
        end else if (cnt < LUT_SIZE) begin
            case (state)
                2'd0: begin
                    state <= 2'd0;          // Go 已在上面分支处理，这里只保持
                end

                2'd1: begin
                    wrreg_req <= 1'b1;
                    state     <= 2'd2;
                end

                2'd2: begin
                    wrreg_req <= 1'b0;
                    if (RW_Done)
                        state <= 2'd1;              // 继续写下一条
                    else
                        state <= 2'd2;
                end

                default: state <= 2'd0;
            endcase
        end else begin
            state     <= 2'd0;
            wrreg_req <= 1'b0;                      // 明确清零，不留悬空
        end
    end

endmodule

