//////////////////////////////////////////////////////////////////////////////////
// Company:        个人项目 / SonicTwin-Engine
// Engineer:       flyingyu
//
// Create Date:    2026-10-26
// Design Name:    async_fifo
// Module Name:    async_fifo
// Project Name:   音速双擎（SonicTwin-Engine）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    async_fifo.v - 异步 FIFO（双时钟，格雷码指针，show-ahead 输出）
//                 用途：本工程有两处必须跨时钟域传数据
//                 ① BCLK 域（WM8960 输出的 3.072 MHz）→ clk_sys 域（48 MHz）
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module async_fifo #(
    parameter integer DW    = 24,       // 数据宽度
    parameter integer DEPTH = 16        // 深度（建议取 2 的幂）
) (
    //------------------------ 写侧（写时钟域）------------------------
    input  wire                     wclk,
    input  wire                     wrst_n,
    input  wire                     wr_en,
    input  wire [DW-1:0]            din,
    output wire                     full,
    output wire [$clog2(DEPTH):0]   wr_level,   // 写侧看到的占用数
    output wire [7:0]               wr_drop,    // 写满被丢弃的次数（诊断用）

    //------------------------ 读侧（读时钟域）------------------------
    input  wire                     rclk,
    input  wire                     rrst_n,
    input  wire                     rd_en,
    output wire [DW-1:0]            dout,       // show-ahead：!empty 当拍即有效
    output wire                     empty,
    output wire [$clog2(DEPTH):0]   rd_level
);

    localparam integer AW = $clog2(DEPTH);      // 地址位宽
    localparam integer PW = AW + 1;             // 指针位宽（多一位用来判满）

    //-------------------------------------------------------------------------
    // 存储体：分布式 RAM，组合读端口
    //   不加复位 —— 复位存储体会综合出 DEPTH x DW 个带复位端的触发器，
    //   白白增加扇出、恶化时序，而且 FIFO 只要能保证"写过的位置才可能被读"
    //   就够了（由指针同步保证），不需要清零。
    //-------------------------------------------------------------------------
    (* ram_style = "distributed" *) reg [DW-1:0] mem [0:DEPTH-1];

    //-------------------------------------------------------------------------
    // 格雷码 <-> 二进制转换
    //   bin2gray:  g = b ^ (b >> 1)
    //   gray2bin: 从最高位往下逐位异或（组合逻辑，PW 级）
    //-------------------------------------------------------------------------
    // 非 ANSI 风格参数声明 —— Verible 的 explicit-function-task-parameter-type
    // 规则只对 ANSI 风格 (input [N:0] x) 报错，本工程统一用这种写法
    function [PW-1:0] bin2gray;
        input [PW-1:0] b;
        begin
            bin2gray = b ^ (b >> 1);
        end
    endfunction

    function [PW-1:0] gray2bin;
        input [PW-1:0] g;
        integer i;
        begin
            gray2bin[PW-1] = g[PW-1];
            for (i = PW - 2; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    //-------------------------------------------------------------------------
    // 指针与同步器声明（写域和读域各一套）
    //
    // ASYNC_REG = "TRUE" 是给工具看的标记，作用有三个：
    //   ① 把这两级触发器紧挨着放（缩短第一级的布线延迟，提高 MTBF）
    //   ② 禁止工具对它们做 retiming / 复制 / 优化掉
    //   ③ Vivado 的 report_cdc 会因为打了这个标记才判定为"安全同步器"
    // 养成习惯：所有跨时钟域的同步器触发器都要打这个属性。
    //-------------------------------------------------------------------------
    reg  [PW-1:0] wbin,  wgray;         // 写指针（写域）
    reg  [PW-1:0] rbin,  rgray;         // 读指针（读域）

    (* ASYNC_REG = "TRUE" *) reg [PW-1:0] rgray_w1, rgray_w2;  // 读指针 -> 写域
    (* ASYNC_REG = "TRUE" *) reg [PW-1:0] wgray_r1, wgray_r2;  // 写指针 -> 读域

    //=========================================================================
    //                              写时钟域
    //=========================================================================

    // 读指针（格雷码）同步到写域
    always @(posedge wclk) begin
        if (!wrst_n) begin
            rgray_w1 <= {PW{1'b0}};
            rgray_w2 <= {PW{1'b0}};
        end else begin
            rgray_w1 <= rgray;
            rgray_w2 <= rgray_w1;
        end
    end

    wire [PW-1:0] rbin_w = gray2bin(rgray_w2);

    // 写指针推进
    always @(posedge wclk) begin
        if (!wrst_n) begin
            wbin  <= {PW{1'b0}};
            wgray <= {PW{1'b0}};
        end else if (wr_en && !full) begin
            wbin  <= wbin + 1'b1;
            wgray <= bin2gray(wbin + 1'b1);
        end
    end

    // 写存储体（同一 always 块内同时更新指针和数据，避免多驱动）
    always @(posedge wclk) begin
        if (wr_en && !full)
            mem[wbin[AW-1:0]] <= din;
    end

    // 满：占用数正好等于 DEPTH。
    //   用【当前】的 wbin 算，不用 wbin_nxt —— 避免 wbin -> wbin_nxt -> full
    //   -> 写使能 这条路径被综合工具当成组合环（之前 audio_fifo 踩过）。
    assign wr_level = wbin - rbin_w;
    assign full     = (wr_level == DEPTH);

    // 写满被丢弃计数（正常工作时应当恒为 0）
    reg [7:0] wr_drop_r;
    always @(posedge wclk) begin
        if (!wrst_n)
            wr_drop_r <= 8'd0;
        else if (wr_en && full)
            wr_drop_r <= wr_drop_r + 1'b1;
    end
    assign wr_drop = wr_drop_r;

    //=========================================================================
    //                              读时钟域
    //=========================================================================

    // 写指针（格雷码）同步到读域
    always @(posedge rclk) begin
        if (!rrst_n) begin
            wgray_r1 <= {PW{1'b0}};
            wgray_r2 <= {PW{1'b0}};
        end else begin
            wgray_r1 <= wgray;
            wgray_r2 <= wgray_r1;
        end
    end

    // 读指针推进
    always @(posedge rclk) begin
        if (!rrst_n) begin
            rbin  <= {PW{1'b0}};
            rgray <= {PW{1'b0}};
        end else if (rd_en && !empty) begin
            rbin  <= rbin + 1'b1;
            rgray <= bin2gray(rbin + 1'b1);
        end
    end

    // 空：两个格雷码指针相等 —— 纯比较，不需要转二进制
    assign empty = (rgray == wgray_r2);

    assign rd_level = gray2bin(wgray_r2) - rbin;

    // show-ahead 输出：组合读，永远显示队首，rd_en 只负责"弹出"
    assign dout = mem[rbin[AW-1:0]];

endmodule
