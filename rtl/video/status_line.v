//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    status_line
// Module Name:    status_line
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    status_line.v - 状态行生成器
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module status_line #(
    parameter integer NLEN = 17,       // 【每行】字符数（共 3 行 = NLEN*3 个）
    parameter integer NC   = 20,       // text_buf 每行能放多少字符
    // 实际写多少行
    parameter integer NROW = 8
) (
    input  wire        clk,
    input  wire        rst_n,

    //--------------------- 要显示的配置 ---------------------
    input  wire [7:0]  cfg_view,
    // 喇叭静音（面板 SPK 键 / UART 4'h1），显示在第 2 行
    input  wire        cfg_spk_mute,
    // 输入源（0=话筒 1=线路）显示在第 7 行；SD 图序号显示在第 8 行
    input  wire        cfg_src,
    input  wire [7:0]  cfg_img_idx,
    input  wire [7:0]  cfg_hue_spd,
    input  wire [7:0]  cfg_wave_gain,
    input  wire [7:0]  cfg_bg_mode,
    input  wire [7:0]  cfg_demo,
    //--------------------- 以下为弃用保留 -------------------------
    input  wire [7:0]  cfg_style,
    input  wire [11:0] tp_x,            // 触摸屏原始 X（用于上板验证管脚）
    input  wire [11:0] tp_y,
    input  wire [11:0] tp_edges,        // 诊断：最近一次转换 DOUT 跳变次数
    input  wire        tp_low,          // 诊断：DOUT 是否出现过低电平
    input  wire [23:0] dbg_adc,
    input  wire [63:0] dbg_sd_bytes,

    //--------------------- 写 text_buf ---------------------
    output reg         we,
    output reg  [15:0] waddr,
    output reg  [7:0]  wdata
);

    //=========================================================================
    // 配置变化检测
    //=========================================================================
    reg [7:0]  v_d, s_d, h_d, g_d, b_d, m_d;
    reg [11:0] tx_d, ty_d;
    reg [11:0] te_d;
    reg        tl_d;
    reg [23:0] ad_d;
    reg [63:0] sb_d;

    wire changed = (cfg_view      != v_d) || (cfg_style     != s_d) ||
                   (cfg_hue_spd   != h_d) || (cfg_wave_gain != g_d) ||
                   (cfg_bg_mode   != b_d) || (cfg_demo      != m_d) ||
                   (tp_x != tx_d) || (tp_y != ty_d) ||
                   (tp_edges != te_d) || (tp_low != tl_d) ||
                   (dbg_adc != ad_d) || (dbg_sd_bytes != sb_d);

    //=========================================================================
    // 逐字符写入
    //=========================================================================
    reg [7:0] cnt;      // 0..NLEN*NROW-1（NROW 行）
    reg       busy;

    // 十六进制数字 -> ASCII（'0'..'9' / 'A'..'F'）
    function [7:0] hexc;
        input [3:0] v;
        begin
            hexc = (v < 4'd10) ? ("0" + v) : ("A" + v - 4'd10);
        end
    endfunction

    // 12 位值 -> 4 位十进制 ASCII
    function [7:0] dec4;
        input [11:0] v;
        input [2:0]  d;          // 0=千位 1=百位 2=十位 3=个位
        reg [11:0]   t;
        begin
            case (d)
                3'd0:    t = (v / 1000) % 10;
                3'd1:    t = (v / 100) % 10;
                3'd2:    t = (v / 10) % 10;
                default: t = v % 10;
            endcase
            dec4 = "0" + t[7:0];
        end
    endfunction

    //-------------------------------------------------------------------------
    // 字符表：6 行可读标签 + 2 行触摸诊断（cnt = 行*NLEN + 列）
    //-------------------------------------------------------------------------
    // 字段名表：第 i 行前 5 个字符
    reg [7:0] nm [0:6*5-1];      // 6 行 x 5 字符
    initial begin
        //        01234
        nm[ 0]="V"; nm[ 1]="I"; nm[ 2]="E"; nm[ 3]="W"; nm[ 4]=" ";
        nm[ 5]="S"; nm[ 6]="P"; nm[ 7]="K"; nm[ 8]=" "; nm[ 9]=" ";
        nm[10]="H"; nm[11]="U"; nm[12]="E"; nm[13]=" "; nm[14]=" ";
        nm[15]="G"; nm[16]="A"; nm[17]="I"; nm[18]="N"; nm[19]=" ";
        nm[20]="B"; nm[21]="G"; nm[22]=" "; nm[23]=" "; nm[24]=" ";
        nm[25]="D"; nm[26]="E"; nm[27]="M"; nm[28]="O"; nm[29]=" ";
    end

    reg [2:0] li;       // 行号 0..7（下面那个按行选值的块要用）
    reg [4:0] ci;       // 列号 0..NLEN-1
    reg [7:0] ch;

    // 当前行对应的配置值
    reg [7:0] vrow;
    always @(li or cfg_view or cfg_style or cfg_hue_spd or
             cfg_wave_gain or cfg_bg_mode or cfg_demo or cfg_spk_mute) begin
        case (li)
            3'd0:    vrow = cfg_view;
            3'd1:    vrow = {7'd0, cfg_spk_mute};   // SPK：0=开 1=静音
            3'd2:    vrow = cfg_hue_spd;
            3'd3:    vrow = cfg_wave_gain;
            3'd4:    vrow = cfg_bg_mode;
            default: vrow = cfg_demo;
        endcase
    end

    // 敏感列表写全：数组（nm）不能进列表，所以只能用显式清单
    always @(cnt or li or ci or vrow or dbg_adc or dbg_sd_bytes or tp_x or tp_edges or tp_low or
             cfg_view or cfg_style or cfg_hue_spd or cfg_wave_gain or
             cfg_bg_mode or cfg_demo or cfg_spk_mute or cfg_src or cfg_img_idx) begin
        li = cnt / NLEN;        // 0..7
        ci = cnt % NLEN;        // 0..16

        ch = " ";
        if (li < 6) begin
            // ---- 配置行 "VIEW   7" ----
            if (ci < 5)
                ch = nm[li*5 + ci];
            else if (ci == 5)
                ch = " ";
            else if (ci == 6)
                ch = hexc(vrow[3:0]);
        end else if (li == 6) begin
            // ---- 第 7 行：音频输入通道----
            if (ci == 0)      ch = "I";
            else if (ci == 1) ch = "N";
            else if (ci == 6) ch = cfg_src ? "1" : "0";
        end else begin
            // ---- 第 8 行：SD 图序号 ----
            if (ci == 0)      ch = "S";
            else if (ci == 1) ch = "D";
            else if (ci == 6) ch = hexc(cfg_img_idx[7:4]);
            else if (ci == 7) ch = hexc(cfg_img_idx[3:0]);
        end
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            v_d <= 8'hFF; s_d <= 8'hFF; h_d <= 8'hFF;
            g_d <= 8'hFF; b_d <= 8'hFF; m_d <= 8'hFF;   // 上电必触发一次
            tx_d <= 12'hFFF; ty_d <= 12'hFFF;
            te_d <= 12'hFFF; tl_d <= 1'b1; ad_d <= 24'hFFFFFF;
            sb_d <= 64'hFFFF_FFFF_FFFF_FFFF;   // 上电必触发一次
            cnt <= 8'd0;
            busy <= 1'b0;
            we <= 1'b0;
            waddr <= 16'd0;
            wdata <= 8'h20;
        end else begin
            we <= 1'b0;

            if (!busy) begin
                // 配置变了就启动一次重写
                if (changed) begin
                    busy <= 1'b1;
                    cnt  <= 8'd0;
                end
            end else begin
                we    <= 1'b1;
                waddr <= {11'd0, (cnt / NLEN) * NC + (cnt % NLEN)};
                wdata <= ch;
                // NROW 行一起写：cnt 从 0 数到 NLEN*NROW-1
                if (cnt == NLEN*NROW - 1) begin
                    busy <= 1'b0;
                    // 记下这次写的是什么配置，下次只有再变才重写
                    v_d <= cfg_view;      s_d <= cfg_style;
                    h_d <= cfg_hue_spd;   g_d <= cfg_wave_gain;
                    b_d <= cfg_bg_mode;   m_d <= cfg_demo;
                    tx_d <= tp_x;         ty_d <= tp_y;
                    sb_d <= dbg_sd_bytes;
                    te_d <= tp_edges;     tl_d <= tp_low;
                    ad_d <= dbg_adc;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

endmodule
