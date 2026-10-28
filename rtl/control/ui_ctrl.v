//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    ui_ctrl
// Module Name:    ui_ctrl
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    ui_ctrl.v - 统一配置寄存器组
// Dependencies:   disp_cfg.vh
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


`include "disp_cfg.vh"

module ui_ctrl #(
    parameter integer NREG        = 8,
    parameter integer AUTO_PERIOD = 48_000_000 * 4,     // 自动切换间隔（4 秒）
    // SD 卡里实际写了多少张图（由 scripts/sdcard/mkimage.py 决定）
    parameter integer IMG_COUNT   = 3
) (
    input  wire        clk,
    input  wire        rst_n,

    //--------------------- 统一写端口 ---------------------
    input  wire        wr_en,
    input  wire [3:0]  wr_addr,
    input  wire [7:0]  wr_data,

    //--------------------- 便捷操作 ---------------------
    input  wire        next_view,    // 1 拍脉冲：切到下一个视图预设 (VIEW 按钮)

    // 步进
    input  wire        step_en,         // 1 拍脉冲：对 step_addr 指向的字段 +1
    input  wire [3:0]  step_addr,

    //--------------------- 配置输出 ---------------------
    output reg  [7:0]  cfg_view,
    // 面板弃用，UART 保留
    output reg  [7:0]  cfg_style,
    // 喇叭静音：1 = 静音（面板 SPK 键切换）
    output reg         cfg_spk_mute,
    output reg  [7:0]  cfg_hue_spd,
    output reg  [7:0]  cfg_wave_gain,
    output reg  [7:0]  cfg_bg_mode,
    output reg  [7:0]  cfg_auto,
    output reg  [7:0]  cfg_demo,        // 演示/自检图案选择
    // 音频输入源：0=话筒 1=线路输入
    output reg  [7:0]  cfg_src,
    // SD 卡切图：每次按下面板的 SD 按钮，这个计数器加 1
    output reg  [7:0]  cfg_img_idx,
    // 背景来源：0 = BG 程序化背景 1 = SD 卡图片（BG 与 SD 并列触发）
    output reg         cfg_bg_src,
    output reg  [3:0]  view_idx         // 当前预设编号（观测用）
);

    localparam integer NPRESET = 6;

    //=========================================================================
    // 视图预设表
    //=========================================================================
    reg [7:0] preset [0:NPRESET-1];

    initial begin
        preset[0] = 8'b0000_0101;       // 柱状 + 波形  <- 上电默认
        preset[1] = 8'b0000_0110;       // 极坐标 + 波形
        preset[2] = 8'b0000_0111;       // 三个全开
        preset[3] = 8'b0000_0001;       // 只柱状
        preset[4] = 8'b0000_0010;       // 只极坐标
        preset[5] = 8'b0000_0100;       // 只波形
    end

    wire [3:0] nxt_idx = (view_idx == NPRESET - 1) ? 4'd0 : view_idx + 1'b1;

    //=========================================================================
    // 自动循环计时
    //=========================================================================
    reg [31:0] auto_cnt;
    wire       auto_tick = cfg_auto[0] && (auto_cnt == AUTO_PERIOD[31:0] - 1);

    always @(posedge clk) begin
        if (!rst_n)
            auto_cnt <= 32'd0;
        else if (!cfg_auto[0])
            auto_cnt <= 32'd0;
        else if (auto_cnt == AUTO_PERIOD[31:0] - 1)
            auto_cnt <= 32'd0;
        else
            auto_cnt <= auto_cnt + 1'b1;
    end

    //=========================================================================
    // 寄存器组：三个写源共用一个写端口
    //   优先级：显式写（UART/触摸） > 切视图（按键/自动）
    //=========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            cfg_view      <= 8'b0000_0101;      // 柱状 + 波形（= preset[0]）
            cfg_style     <= 8'd0;
            cfg_hue_spd   <= 8'd6;              // 每 2^(8-6) = 4 帧滚一级
            cfg_wave_gain <= 8'd4;              // G 是【指数】：波形增益 = 2^G
            cfg_bg_mode   <= 8'd0;
            cfg_auto      <= 8'd0;
            cfg_demo      <= 8'd0;              // 上电关（走真实音频）
            cfg_src       <= 8'd0;              // 输入源：默认话筒
            cfg_img_idx   <= 8'd0;              // SD 背景图序号
            cfg_bg_src    <= 1'b0;              // 默认程序化背景
            cfg_spk_mute  <= 1'b0;              // 默认不静音
            view_idx      <= 4'd0;              // 对应 preset[0]
        end else if (wr_en) begin
            case (wr_addr)
                4'h0: cfg_view      <= wr_data;
                4'h1: cfg_spk_mute  <= wr_data[0];   // UART 写 1 = 静音
                4'h2: cfg_hue_spd   <= wr_data;
                4'h3: cfg_wave_gain <= wr_data;
                4'h4: cfg_bg_mode   <= wr_data;
                4'h5: cfg_auto      <= wr_data;
                4'h6: cfg_demo      <= wr_data;
                // I 命令：只保留最低位（0=话筒 1=线路）
                4'h7: cfg_src       <= {7'd0, wr_data[0]};
                4'h8: begin
                    cfg_img_idx <= wr_data;         // UART 直接指定第几张图
                    cfg_bg_src  <= 1'b1;            // 同时切到图片背景
                end
                default: ;                      // 未定义的地址忽略
            endcase
            // 直接写 VIEW 时让预设编号跟着对齐（否则下一次按键会跳）
            if (wr_addr == 4'h0) begin
                if      (wr_data[2:0] == 3'b101) view_idx <= 4'd0;
                else if (wr_data[2:0] == 3'b110) view_idx <= 4'd1;
                else if (wr_data[2:0] == 3'b111) view_idx <= 4'd2;
                else if (wr_data[2:0] == 3'b001) view_idx <= 4'd3;
                else if (wr_data[2:0] == 3'b010) view_idx <= 4'd4;
                else if (wr_data[2:0] == 3'b100) view_idx <= 4'd5;
            end
        end else if (step_en) begin
            // 旋钮式步进：按字段各自的有效范围递增
            case (step_addr)
                // VIEW 用预设轮转（和 KEY1 同一个动作），不走这里

                // SPK 喇叭静音开关
                4'h1: cfg_spk_mute  <= ~cfg_spk_mute;
                // HUESPD 0..7，0 = 停住
                4'h2: cfg_hue_spd   <= (cfg_hue_spd[3:0] >= 4'd7) ? 8'd0
                                                                 : cfg_hue_spd + 1'b1;
                // WAVEG 0..8（指数：增益 = 2^G，×1 ~ ×256）
                4'h3: cfg_wave_gain <= (cfg_wave_gain[3:0] >= 4'd8) ? 8'd0
                                                                    : cfg_wave_gain + 1'b1;
                // BGMODE 0..1
                4'h4: begin
                    // BG：切回【程序化背景】，并保留原有的 0/1 循环
                    cfg_bg_src  <= 1'b0;
                    cfg_bg_mode <= (cfg_bg_mode[3:0] >= 4'd1) ? 8'd0
                                                              : cfg_bg_mode + 1'b1;
                end
                // DEMO 0..3
                4'h6: cfg_demo      <= (cfg_demo[1:0] >= 2'd3) ? 8'd0
                                                               : cfg_demo + 1'b1;
                // IN 输入源 0..1（话筒 / 线路输入）
                4'h7: cfg_src <= (cfg_src[0]) ? 8'd0 : 8'd1;
                // SD：切到【图片背景】，同时图序号递增（按 IMG_COUNT 循环）
                4'h8: begin
                    cfg_bg_src  <= 1'b1;
                    if (cfg_img_idx >= (IMG_COUNT - 1))
                        cfg_img_idx <= 8'd0;
                    else
                        cfg_img_idx <= cfg_img_idx + 8'd1;
                end
                default: ;          // 其它地址不步进
            endcase
        end else if (next_view || auto_tick) begin
            cfg_view <= preset[nxt_idx];
            view_idx <= nxt_idx;
        end
    end

endmodule
