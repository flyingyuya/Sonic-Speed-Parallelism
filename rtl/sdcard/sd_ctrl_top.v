//=============================================================================
// sd_ctrl_top.v  ——  SD 卡子系统顶层
//=============================================================================
//   【它做什么】
//     把 sd_init（初始化）和 sd_read（读数据块）组合成"一根 SPI 总线"，
//     并负责：
//       ① 初始化阶段的低速时钟（sd_init 内部产生，200 kHz）
//       ② 工作阶段的高速时钟（本模块产生，clk/4）
//       ③ CS / MOSI 的归属切换
//       ④ 用户侧 start 脉冲从 clk 域跨到 SPI 时钟域的同步
//
//   【时钟切换的安全性 —— 为什么这个 mux 是安全的】
//     两个时钟都来自 clk_sys 分频（同源），切换只发生在 init_done 拉高时。
//     那一刻 sd_cs 一定是高电平（卡空闲）⟹ SD 卡在 CS 高电平时忽略一切时钟
//     ⟹ 即使 mux 输出出现一个 21 ns 的窄脉冲也无害。
//     ⚠️ 前提：切换时刻 sd_cs 必须为高。本模块保证只有 init_done 为 1
//        （= 初始化完全结束、CS 已拉高）才会切。
//
//   【为什么不彻底改成"单时钟 + 使能"】
//     那样要重构两个已验证模块（sd_init / sd_read 都要改内部时钟结构），
//     改动面和"时钟 mux"的风险相当，但工作量大一个数量级。
//     如果以后要接更多 SPI 从设备，再统一重构。
//=============================================================================

`timescale 1ns / 1ps

module sd_ctrl_top #(
    parameter integer CLK_HZ        = 48_000_000,
    parameter integer FAST_DIV      = 4,        // 高速档分频：48M/4 = 12 MHz
    parameter integer INIT_HZ       = 200_000,  // 初始化阶段 SPI 时钟
    parameter integer POWER_ON_NUM  = 5000,     // 上电等待拍数（200kHz 下约 25 ms）
    parameter integer OVER_TIME_NUM = 25000,    // 命令超时拍数
    // 一次读多少块（512 字节/块）
    //   480x272x2 = 261120 字节 = 510 块
    //   TB 里设成 1 让仿真跑得快
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
    // ① 高速 SPI 时钟：clk 的 FAST_DIV 分频（寄存输出，无毛刺）
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
    // ② 初始化模块（内部自己产生 200 kHz 的 sd_clk）
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
    // ③ 读模块（工作在高速 SPI 时钟域 sd_clk_fast）
    //-------------------------------------------------------------------------
    wire rd_cs;
    wire rd_mosi;
    wire rd_busy_i;
    wire rd_valid_i;
    wire [7:0] rd_data_i;
    wire rd_start_sd;      // 同步到 sd_clk_fast 域后的 start 脉冲

    // start 的跨域：clk_sys ⟶ sd_clk_fast
    //   用"电平翻转 + 双打 + 边沿检测"，比单拍脉冲 + 双打可靠
    //   （单拍脉冲如果窄于目标时钟周期，会被完全漏掉）
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
    //   读数据是"每次 valid 伴随一个字节"，用 valid 做使能、数据直接取即可
    //   （sd_clk_fast 是 clk 的 1/4，数据在 valid 期间至少稳定 2 个 clk 周期）
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
    // ④ SPI 引脚归属
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
