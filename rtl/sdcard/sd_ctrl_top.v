//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    sd_ctrl_top
// Module Name:    sd_ctrl_top
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    sd_ctrl_top.v  ——  SD 卡子系统顶层
// Dependencies:   sd_init.v   sd_read.v
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps


module sd_ctrl_top #(
    parameter integer CLK_HZ        = 48_000_000,
    parameter integer FAST_DIV      = 4,        // 高速档分频：48M/4 = 12 MHz
    parameter integer INIT_HZ       = 200_000,  // 初始化阶段 SPI 时钟
    parameter integer POWER_ON_NUM  = 5000,     // 上电等待拍数（200kHz 下约 25 ms）
    parameter integer OVER_TIME_NUM = 25000,    // 命令超时拍数
    // 一次读多少块（512 字节/块），480x272x2 = 261120 字节 = 510 块
    //   TB 里设成 1 可以让仿真跑得快
    parameter integer BLOCKS        = 510
) (
    input  wire        clk,             // clk_sys
    input  wire        rst_n,

    // SD 卡 SPI 引脚
    output wire        sd_clk,
    output reg         sd_cs,
    output reg         sd_mosi,
    input  wire        sd_miso,

    // 用户接口（clk 域）
    input  wire        rd_start,        // 单拍脉冲：开始读一个扇区
    input  wire [31:0] rd_sec_addr,     // 扇区地址
    output wire        rd_busy,
    output wire        rd_valid,        // 单拍，rd_data 有效
    output wire [7:0]  rd_data,

    output wire        init_done
);

    //-------------------------------------------------------------------------
    // 高速 SPI 时钟：clk 的 FAST_DIV 分频（寄存输出，无毛刺）
    //-------------------------------------------------------------------------
    reg [15:0] fast_cnt;
    reg        sd_clk_fast;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fast_cnt    <= 16'd0;
            sd_clk_fast <= 1'b0;
        end else if (fast_cnt == (FAST_DIV/2 - 1)) begin
            fast_cnt    <= 16'd0;
            sd_clk_fast <= ~sd_clk_fast;
        end else begin
            fast_cnt    <= fast_cnt + 16'd1;
        end
    end

    //-------------------------------------------------------------------------
    // 初始化模块（内部自己产生 200 kHz 的 sd_clk）
    //-------------------------------------------------------------------------
    wire sd_clk_init;
    wire init_cs;
    wire init_mosi;
    wire init_done_i;

    sd_init #(
        .CLK_HZ        (CLK_HZ),
        .DIV_FREQ      (CLK_HZ / INIT_HZ),   // 48M/240 = 200 kHz
        .POWER_ON_NUM  (POWER_ON_NUM),
        .OVER_TIME_NUM (OVER_TIME_NUM)
    ) u_init (
        .clk       (clk),
        .rst_n     (rst_n),
        .sd_miso   (sd_miso),
        .sd_clk    (sd_clk_init),
        .sd_cs     (init_cs),
        .sd_mosi   (init_mosi),
        .init_done (init_done_i)
    );

    assign init_done = init_done_i;

    //-------------------------------------------------------------------------
    // 读模块（工作在高速 SPI 时钟域 sd_clk_fast）
    //-------------------------------------------------------------------------
    wire rd_cs;
    wire rd_mosi;
    wire rd_busy_i;
    wire rd_valid_i;
    wire [7:0] rd_data_i;
    wire rd_start_sd;      // 同步到 sd_clk_fast 域后的 start 脉冲

    // start 的跨域：clk_sys ⟶ sd_clk_fast（电平翻转 + 双打 + 边沿检测）
    reg start_tog;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            start_tog <= 1'b0;
        else if (rd_start)
            start_tog <= ~start_tog;
    end

    reg [2:0] tog_sync;
    always @(posedge sd_clk_fast or negedge rst_n) begin
        if (!rst_n)
            tog_sync <= 3'd0;
        else
            tog_sync <= {tog_sync[1:0], start_tog};
    end

    assign rd_start_sd = tog_sync[2] ^ tog_sync[1];   // 检出一次翻转

    sd_read #(.BLOCKS(BLOCKS)) u_read (
        .sd_clk     (sd_clk_fast),
        .rst_n      (rst_n),
        .start      (rd_start_sd),
        .sec_addr   (rd_sec_addr),
        .busy       (rd_busy_i),
        .dout_valid (rd_valid_i),
        .dout_data  (rd_data_i),
        .sd_miso    (sd_miso),
        .sd_cs      (rd_cs),
        .sd_mosi    (rd_mosi)
    );

    // rd_valid / rd_data 从 sd_clk_fast 域送回 clk 域
    reg [2:0] vld_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            vld_sync <= 3'd0;
        else
            vld_sync <= {vld_sync[1:0], rd_valid_i};
    end

    assign rd_valid = vld_sync[2] & ~vld_sync[1];    // 上升沿
    assign rd_data  = rd_data_i;
    assign rd_busy  = rd_busy_i;

    //-------------------------------------------------------------------------
    // SPI 引脚归属
    //   初始化阶段：用 sd_init 的引脚和慢时钟
    //   初始化完成后：用 sd_read 的引脚和快时钟
    //-------------------------------------------------------------------------
    assign sd_clk = init_done_i ? sd_clk_fast : sd_clk_init;

    always @(*) begin
        if (!init_done_i) begin
            sd_cs   = init_cs;
            sd_mosi = init_mosi;
        end else begin
            sd_cs   = rd_cs;
            sd_mosi = rd_mosi;
        end
    end

endmodule
