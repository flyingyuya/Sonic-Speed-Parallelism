//////////////////////////////////////////////////////////////////////////////////
// Company:        个人项目 / SonicTwin-Engine
// Engineer:       flyingyu
//
// Create Date:    2026-10-26
// Design Name:    status_line
// Module Name:    status_line
// Project Name:   音速双擎（SonicTwin-Engine）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    status_line.v - 状态行生成器
//                 【干什么】
//                 把当前配置拼成一行文字，写进 text_buf：
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module status_line #(
    parameter integer NLEN = 17,       // 【每行】字符数（共 3 行 = NLEN*3 个）
    parameter integer NC   = 20,       // text_buf 每行能放多少字符（地址换算用）
    // 实际写多少行（6 行配置 + 1 行 ADC 诊断 = 7）
    //   原来是 8（多一行 SD 字节诊断 ✗ 那行已经去掉）
    parameter integer NROW = 8
) (
    input  wire        clk,
    input  wire        rst_n,

    //--------------------- 要显示的配置 ---------------------
    input  wire [7:0]  cfg_view,
    input  wire [7:0]  cfg_style,
    // 喇叭静音（面板 SPK 键 / UART 4'h1）。状态栏第 2 行显示它的值。
    input  wire        cfg_spk_mute,
    // 输入源（0=话筒 1=线路）显示在第 7 行；SD 图序号显示在第 8 行
    input  wire        cfg_src,
    input  wire [7:0]  cfg_img_idx,
    input  wire [7:0]  cfg_hue_spd,
    input  wire [7:0]  cfg_wave_gain,
    input  wire [7:0]  cfg_bg_mode,
    input  wire [7:0]  cfg_demo,
    input  wire [11:0] tp_x,            // 触摸屏原始 X（用于上板验证管脚）
    input  wire [11:0] tp_y,
    input  wire [11:0] tp_edges,        // 诊断：最近一次转换 DOUT 跳变次数
    input  wire        tp_low,          // 诊断：DOUT 是否出现过低电平

    // 诊断：原始 ADC 采样值（**直接从 audio_top 的 rx_l 引过来，不经任何处理**）
    //   显示成 6 位十六进制，占满原来 "TX4095" 那 6 个字符的位置 ——
    //   【故意做成长度不变的】，因为 status_line 的 TB 用定长 68 字符的
    //   期望串比较；一改长度整串就错位，会报几十处假失败（已经栽过一次）。
    input  wire [23:0] dbg_adc,
    // SD 卡读到的前 8 个字节（十六进制显示在第 8 行）
    //   用途：上板时一眼看出"卡里到底读到了什么"——
    //     全 00/全 FF ⟹ 没读到数据或数据线有问题
    //     有变化          ⟹ 读通路是通的
    input  wire [63:0] dbg_sd_bytes,

    //--------------------- 写 text_buf ---------------------
    output reg         we,
    output reg  [15:0] waddr,
    output reg  [7:0]  wdata
);

    //=========================================================================
    // 1. 配置变化检测
    //=========================================================================
    reg [7:0]  v_d, s_d, h_d, g_d, b_d, m_d;
    reg [11:0] tx_d, ty_d;
    reg [11:0] te_d;
    reg        tl_d;
    reg [23:0] ad_d;
    reg [63:0] sb_d;

    // ⚠️ 必须用 != 而不是 !==。
    //   `!==` 是【仿真专用】运算符（会比较 X/Z），**不可综合** ——
    //   综合器会自动替换成 != 并报 [Synth 8-589] 警告。
    //   这里用 != 是安全的：复位时 *_d 都被初始化成 8'hFF，不会出现 X。
    //   （TB 里用 ===/!== 没问题，因为 TB 不综合；RTL 里一律不要用。）
    wire changed = (cfg_view      != v_d) || (cfg_style     != s_d) ||
                   (cfg_hue_spd   != h_d) || (cfg_wave_gain != g_d) ||
                   (cfg_bg_mode   != b_d) || (cfg_demo      != m_d) ||
                   (tp_x != tx_d) || (tp_y != ty_d) ||
                   (tp_edges != te_d) || (tp_low != tl_d) ||
                   (dbg_adc != ad_d) || (dbg_sd_bytes != sb_d);

    //=========================================================================
    // 2. 逐字符写入
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
    //   ⚠️ 必须是 4 位！12 位最大 4095，3 位装不下。
    //   第一版写的是"百位 = v/100"，v=4095 时算出 40，再 "0"+40 得到
    //   码 88 也就是字母 'X' —— 屏幕上显示出 "TXX95"，
    //   看起来像乱码，其实是在告诉你"读回来是 0xFFF"。
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
    //
    //   为什么从 "V7 S0 H6 G8 B0 D0" 改成这种写法：
    //     前者是给 UART 回读用的紧凑格式，屏幕上根本没人看得懂。
    //     字母表已经有了（5x7 字库），直接写完整的字段名更直观。
    //
    //   第 1~6 行 (0..101)   : "VIEW   7" 这类，每行 8 个字符有意义，其余留空
    //   第 7~8 行 (102..135) : "TX4095" / "E0000 L0" 触摸诊断
    //
    //   ⚠️ 值一律用【十六进制】还是【十进制】：
    //     配置字段都是小整数（0..15），十六进制一位就够，和 UART 回执一致；
    //     触摸读数是 12 位（0..4095），十进制 4 位才装得下，
    //     而且十进制看"手指往右移动数字变大"更直观。
    //-------------------------------------------------------------------------
    // 字段名表：第 i 行前 5 个字符
    reg [7:0] nm [0:6*5-1];      // 6 行 x 5 字符
    initial begin
        //        01234
        // ⚠️ 这张表是【从 0 开始】的，第一行第一列就是 index 0。
        //   第一版在这里写了个 '#' 当占位符（想表示空格），结果把 'V' 挤掉了，
        //   整张表右移一位：屏幕上第一行变成 "#VIEW 7"。
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

    // 当前行对应的配置值。写成函数而不是数组：
    //   数组放在 always @(*) 的敏感列表里会让 iverilog 抱怨
    //   "@* is sensitive to all N words in array"，所以直接按行号选。
    // 当前行对应的配置值（按行号选，避免"数组进敏感列表"的警告）
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
            // ---- 第 7 行：原始 ADC 值的 6 位十六进制（**不是十进制**）----
            //   例：01F2C4 表示 rx_l = 0x1F2C4（Q1.23 有符号，补码）
            //       FF8000 表示一个不大的负值（高 6 位全 1 = 符号扩展）
            //
            //   怎么看：
            //     数字完全不动          -> 没数据 / 顶死在某个电平
            //     只在最低几位随机跳     -> 幅度极小，基本是量化噪声
            //     说话时高几位明显变化   -> 通路是好的，问题在显示链
            // 对齐：名字占 ci 0..4，ci==5 留空，ci==6 是值（和前 6 行一致）
            if (ci == 0)      ch = "I";
            else if (ci == 1) ch = "N";
            else if (ci == 6) ch = cfg_src ? "1" : "0";
        end else begin
            // ---- 第 8 行：SD 图序号 ----
            // 对齐同上：ci==6、7 放两位十六进制
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
                // ⚠️ text_buf 的地址是【行*NC + 列】，不是线性字符号。
                //   一开始直接发 cnt，第二行（cnt 17..33）就被写到了
                //   "第一行的第 17~33 列"，屏幕上第二行永远是空的。
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
