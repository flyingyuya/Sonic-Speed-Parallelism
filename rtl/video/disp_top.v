//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    disp_top
// Module Name:    disp_top
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    disp_top.v - 显示链顶层
// Dependencies:   disp_cfg.vh   lcd_timing.v   cdc_sync.v  ui_anim.v
//                 bg_src.v   wave_buf.v    status_line.v   text_buf.v
//                 ui_layer.v   disp_mix.v
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


`include "disp_cfg.vh"

module disp_top #(
    // 参数默认值
    parameter integer HDISP      = `DISP_HDISP,
    parameter integer VDISP      = `DISP_VDISP,
    parameter integer NBARS      = `DISP_NBARS,
    parameter integer HW         = 9,
    parameter integer BARS_Y0    = `DISP_BARS_Y0,
    parameter integer BARS_H     = `DISP_BARS_H,
    parameter integer BAR_GAP    = `DISP_BAR_GAP,
    parameter integer POL_CX     = `DISP_POL_CX,
    parameter integer POL_CY     = `DISP_POL_CY,
    parameter integer POL_RIN    = `DISP_POL_RIN,
    parameter integer POL_RMAX   = `DISP_POL_RMAX,
    //-------------------------------------------------------------------------
    parameter integer FB_SW      = 320,
    parameter integer FB_SH      = 180,
    parameter integer FB_W       = 320,
    parameter integer FB_H       = 180,
    parameter integer FB_X0      = 0,
    parameter integer FB_Y0      = 0,
    parameter integer SHIFT      = 0,

    parameter integer FB_CX      = 0,
    parameter integer FB_CY      = 0,
    parameter integer WAVE_AW    = 10,
    parameter integer NBARS_DISP = 60,
    parameter integer WITH_UI    = 1,
    parameter integer WITH_TEXT  = 1,

    parameter integer WAVE_CY    = `DISP_WAVE_CY,
    parameter integer WAVE_AMP   = `DISP_WAVE_AMP,
    parameter integer WAVE_TH    = `DISP_WAVE_TH,
    parameter integer SCROLL_DIV = 5,       // 每多少帧色相滚动一级

    //-------------------------------------------------------------------------
    // 时序（从例化处提到参数表，双输出时每路一套）
    parameter integer H_SYNC     = 41,
    parameter integer H_BACK     = 2,
    parameter integer H_FRONT    = 2,
    parameter integer V_SYNC     = 10,
    parameter integer V_BACK     = 2,
    parameter integer V_FRONT    = 2,

    //-------------------------------------------------------------------------
    // 坐标位宽
    parameter integer XW = $clog2(H_SYNC + H_BACK + HDISP + H_FRONT),
    parameter integer YW = $clog2(V_SYNC + V_BACK + VDISP + V_FRONT),

    //-------------------------------------------------------------------------
    // 属性插值器的满值 / 每帧步进
    parameter integer ANIM_FULL = 128,
    parameter integer ANIM_STEP = 4,

    //-------------------------------------------------------------------------
    // UI 按钮带
    //-------------------------------------------------------------------------
    parameter integer NB_UI  = `DISP_UI_NB,
    parameter integer UI_BX0 = 0,
    parameter integer UI_BY0 = `DISP_UI_BY0,
    parameter integer UI_BW  = `DISP_UI_BW,
    parameter integer UI_BH  = `DISP_UI_BH,
    parameter integer UI_GAP = `DISP_UI_GAP,

    //-------------------------------------------------------------------------
    // 像素时钟频率（Hz）
    parameter integer PIX_HZ = 12_500_000,

    parameter integer TAB_X  = `DISP_TAB_X,
    parameter integer TAB_Y  = `DISP_TAB_Y,
    parameter integer TAB_W  = `DISP_TAB_W,
    parameter integer TAB_H  = `DISP_TAB_H
) (
    //--------------------- 音频域（clk_sys）---------------------
    input  wire                  clk_sys,
    input  wire                  rst_sys_n,
    input  wire                  spec_wr,       // = spectrum.frame_done
    input  wire [NBARS*HW-1:0]   spec_din,      // = spectrum.bar_flat

    //--------------------- 显示域（clk_pix）---------------------
    input  wire                  clk_pix,
    input  wire                  rst_pix_n,
    input  wire [3:0]            ui_mode,       // 来自 ui_ctrl：背景模式
    input  wire [3:0]            ui_style,      // 来自 ui_ctrl：柱体风格（已弃用）
    input  wire                  ui_spk_mute,   // 来自 ui_ctrl：喇叭静音（状态栏显示）
    input  wire                  ui_src,        // 来自 ui_ctrl：输入源（状态栏显示）
    input  wire [7:0]            ui_img_idx,    // 来自 ui_ctrl：SD 图序号
    input  wire [2:0]            ui_view,       // 来自 ui_ctrl：视图使能
    input  wire [7:0]            ui_hue_spd,    // 来自 ui_ctrl：色相滚动速度

    //--------------------- 波形数据（clk_sys 域）---------------------
    input  wire signed [23:0]    wave_din,      // = audio_top 的 rx_l
    input  wire                  wave_we,       // = audio_top 的 rx_valid
    input  wire signed [23:0]    wave_th,      // 自适应触发门限（来自 env_track）
    input  wire [23:0]           dbg_adc,      // 诊断值（直通显示）
    input  wire [63:0]           dbg_sd_bytes, // SD 卡前 8 字节（直通显示）

    // SD 图片背景：cfg_bg_src=1 时背景取帧缓冲
    input  wire                  cfg_bg_src,
    input  wire [15:0]           fb_rgb,
    output wire [18:0]           fb_addr,

    // 面板开/关（来自 clk_sys 的按键手势）
    input  wire                  panel_tog,

    // 按键活动（用来重置空闲计时）
    input  wire                  key_act,

    // 按键光标（用来画方框高亮）
    input  wire [3:0]            ui_sel,

    // 面板是否展开（送回 clk_sys 判断动作是否有效）
    output wire                  panel_open,

    input  wire [7:0]            ui_wave_gain,  // 来自 ui_ctrl：波形增益（G 命令）
    input  wire [7:0]            ui_demo,       // 来自 ui_ctrl：演示图案（T 命令）

    // 触摸原始读数（clk_sys 域）
    input  wire [11:0]           tp_x,
    input  wire [11:0]           tp_y,
    input  wire [11:0]           tp_edges,      // 诊断：DOUT 跳变次数
    input  wire                  tp_low,        // 诊断：DOUT 是否出现过低电平

    output wire [3:0]            ui_btn_act,    // 液晶输出
    output wire                  ui_btn_press,  // 按钮命中（送回 clk_sys 改配置）

    output wire [23:0]           lcd_rgb,
    output wire                  lcd_hs,
    output wire                  lcd_vs,
    // 数据有效（有效像素区，TMDS 编码用 de 区分"像素数据期"和"控制码期"）
    output wire                  lcd_de,
    output wire                  lcd_clk
);

    //=========================================================================
    // 时序发生器
    //=========================================================================
    wire [XW-1:0] x;
    wire [YW-1:0] y;
    wire        de;
    wire        sof;
    wire [23:0] rgb_in;                        // 由 disp_mix 组合算出

    lcd_timing #(
        .H_SYNC(H_SYNC), .H_BACK(H_BACK), .H_DISP(HDISP), .H_FRONT(H_FRONT),
        .V_SYNC(V_SYNC), .V_BACK(V_BACK), .V_DISP(VDISP), .V_FRONT(V_FRONT),
        // 显式传入，避免和 lcd_timing 内部的公式各自算一遍而错开
        .HW(XW), .VW(YW)
    ) u_timing (
        .clk     (clk_pix),
        .rst_n   (rst_pix_n),
        .rgb_in  (rgb_in),
        .rgb_out (lcd_rgb),
        .hsync   (lcd_hs),
        .vsync   (lcd_vs),
        .de      (de),
        .x       (x),
        .y       (y),
        .sof     (sof)
    );

    assign lcd_de = de;

    // 像素时钟直连输出脚
    assign lcd_clk = clk_pix;

    //=========================================================================
    // 配置位的跨时钟域同步
    //=========================================================================
    wire [3:0] ui_mode_s, ui_style_s;
    wire [2:0] ui_view_s;
    wire [7:0] ui_hue_spd_s, ui_wave_gain_s, ui_demo_s;

    cdc_sync #(.WIDTH(4), .RESET_VAL(4'd0)) u_sync_mode (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(ui_mode), .dout(ui_mode_s));
    cdc_sync #(.WIDTH(4), .RESET_VAL(4'd0)) u_sync_style (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(ui_style), .dout(ui_style_s));

    // 喇叭静音（单 bit，用 cdc_sync 过到 clk_pix 域）
    wire ui_spk_mute_s;
    cdc_sync u_spk_sync (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(ui_spk_mute), .dout(ui_spk_mute_s));

    wire       ui_src_s;
    wire [7:0] ui_img_idx_s;
    cdc_sync u_src_sync (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(ui_src), .dout(ui_src_s));

    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : g_img_sync
            cdc_sync u_img_sync (
                .clk(clk_pix), .rst_n(rst_pix_n),
                .din(ui_img_idx[gi]), .dout(ui_img_idx_s[gi]));
        end
    endgenerate
    // 复位值必须和 ui_ctrl 的上电默认一致
    cdc_sync #(.WIDTH(3), .RESET_VAL(3'b101)) u_sync_view (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(ui_view), .dout(ui_view_s));
    cdc_sync #(.WIDTH(8), .RESET_VAL(8'd6)) u_sync_hue (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(ui_hue_spd), .dout(ui_hue_spd_s));
    cdc_sync #(.WIDTH(8), .RESET_VAL(8'd0)) u_sync_wg (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(ui_wave_gain), .dout(ui_wave_gain_s));
    cdc_sync #(.WIDTH(8), .RESET_VAL(8'd0)) u_sync_demo (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(ui_demo), .dout(ui_demo_s));

    // 触摸原始读数也要跨过来
    wire [11:0] tp_x_s, tp_y_s;
    wire [11:0] tp_edges_s;
    wire        tp_low_s;
    cdc_sync #(.WIDTH(12), .RESET_VAL(12'd0)) u_sync_tpx (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(tp_x), .dout(tp_x_s));
    cdc_sync #(.WIDTH(12), .RESET_VAL(12'd0)) u_sync_tpy (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(tp_y), .dout(tp_y_s));
    cdc_sync #(.WIDTH(12), .RESET_VAL(12'd0)) u_sync_tpe (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(tp_edges), .dout(tp_edges_s));
    cdc_sync #(.WIDTH(1), .RESET_VAL(1'b0)) u_sync_tpl (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(tp_low), .dout(tp_low_s));

    //=========================================================================
    // 色相滚动
    //=========================================================================
    reg [7:0] frame_cnt;
    reg [6:0] hue_off;

    //-------------------------------------------------------------------------
    // 滚动节拍：H 越大越快，H=0 停住
    //-------------------------------------------------------------------------
    wire [3:0] hue_spd   = (ui_hue_spd_s > 8'd7) ? 4'd7 : ui_hue_spd_s[3:0];
    wire       hue_run   = (hue_spd != 4'd0);
    wire [7:0] tick_mask = (8'd1 << (4'd8 - hue_spd)) - 8'd1;

    always @(posedge clk_pix) begin
        if (!rst_pix_n) begin
            frame_cnt <= 8'd0;
            hue_off   <= 7'd0;
        end else if (sof) begin
            frame_cnt <= frame_cnt + 1'b1;
            // ⚠️ 必须写成 (cnt & mask) == mask，不能写成 cnt == mask ——
            //    后者 256 帧才命中一次（frame_cnt 是 8 位），色相几乎不动。
            if (hue_run && ((frame_cnt & tick_mask) == tick_mask)) begin
                hue_off <= hue_off + 1'b1;
            end
        end
    end

    //=========================================================================
    // 跨时钟域快照
    //=========================================================================
    wire [NBARS*HW-1:0] bars;

    spec_sync #(.NBARS(NBARS), .HW(HW)) u_sync (
        .wclk   (clk_sys),
        .wrst_n (rst_sys_n),
        .wr_en  (spec_wr),
        .din    (spec_din),
        .full   (),
        .rclk   (clk_pix),
        .rrst_n (rst_pix_n),
        .sof    (sof),
        .bars   (bars)
    );

    //=========================================================================
    // 触摸坐标：原始 ADC -> 屏幕坐标（或者演示扫描）
    //=========================================================================
    wire demo_touch = (ui_demo_s[3:0] == 4'd4);

    wire [9:0] tch_x_raw = tp_x_s[11:3];
    wire [8:0] tch_y_raw = tp_y_s[11:4];

    wire       tch_down  = (tp_x_s > 12'd16) && (tp_x_s < 12'd4080) &&
                           (tp_y_s > 12'd16) && (tp_y_s < 12'd4080);

    localparam integer SW_HOLD = 4_000_000;     // @12.5MHz 约 0.32 s
    localparam integer SW_PUSH = 2_000_000;     // 按下持续约 0.16 s（远大于轮询周期）

    reg [22:0] sw_cnt;
    reg [2:0]  sw_idx;

    always @(posedge clk_pix) begin
        if (!rst_pix_n) begin
            sw_cnt <= 23'd0;
            sw_idx <= 3'd0;
        end else if (demo_touch) begin
            if (sw_cnt == SW_HOLD - 1) begin
                sw_cnt <= 23'd0;
                sw_idx <= (sw_idx == NB_UI - 1) ? 3'd0 : sw_idx + 1'b1;
            end else begin
                sw_cnt <= sw_cnt + 1'b1;
            end
        end else begin
            sw_cnt <= 23'd0;
            sw_idx <= 3'd0;
        end
    end

    // 光标停在按钮 sw_idx 的中心
    wire [XW-1:0] sw_x = UI_BX0 + sw_idx*(UI_BW+UI_GAP) + UI_BW/2;
    wire [YW-1:0] sw_y = UI_BY0 + UI_BH/2;
    wire          sw_down = demo_touch && (sw_cnt < SW_PUSH);

    wire [XW-1:0] tx_scr = demo_touch ? sw_x : tch_x_raw;
    wire [YW-1:0] ty_scr = demo_touch ? sw_y : tch_y_raw;
    wire          td_scr = demo_touch ? sw_down : tch_down;


    //=========================================================================
    // 属性插值器：三个视图各自的“存在度”（0..128）
    //=========================================================================
    wire [4*8-1:0] ui_level;      // 4 个通道：柱状/极坐标/波形/面板

    // 操作面板的展开/收起时间
    localparam integer TAB_MS  = `DISP_UI_IDLE_MS;       // 空闲多久自动收起
    localparam integer TAB_CNT = (PIX_HZ / 1000) * TAB_MS;   // 按实际像素时钟换算
    localparam integer TAB_CW  = $clog2(TAB_CNT + 1);

    reg  [TAB_CW-1:0] idle_cnt;
    reg         ui_open;
    wire        panel_target = demo_touch | ui_open;

    ui_anim #(.NCH(4), .FULL(ANIM_FULL), .STEP(ANIM_STEP)) u_anim (
        .clk    (clk_pix),
        .rst_n  (rst_pix_n),
        .frame  (sof),          // 帧起始，每帧只走一步
        .target ({panel_target, ui_view_s}),   // [3]=面板 [2:0]=三个视图
        .level  (ui_level)
    );

    wire [7:0] pres_bar = ui_level[0*8 +: 8];   // 柱状
    wire [7:0] pres_pol = ui_level[1*8 +: 8];   // 极坐标
    wire [7:0] pres_wav = ui_level[2*8 +: 8];   // 波形
    wire [7:0] pres_panel = ui_level[3*8 +: 8];   // 操作面板

    // 动画后的实际 y：收起时整条移到屏幕下边缘之外
    //   level=128 -> y = BY0；level=0 -> y = VDISP（看不见）
    localparam [9:0] UI_BH_L = UI_BH[9:0];   // 用参数
    wire [YW+7:0] by0_mul = {6'b0, UI_BH_L} * pres_panel[7:0];
    wire [YW-1:0] ui_by0  = VDISP[YW-1:0] - by0_mul[YW+6:7];

    //=========================================================================
    // 背景生成
    //=========================================================================
    wire [23:0] bg_rgb;

    wire [23:0] fb_rgb888 = {fb_rgb[4:0],  3'b000,   // B5 -> 高 8 位（实测）
                             fb_rgb[10:5], 2'b00,
                             fb_rgb[15:11],3'b000};  // R5 -> 低 8 位

    //-------------------------------------------------------------------------
    // 图片区域判定（区域外回落到程序化背景）
    //-------------------------------------------------------------------------
    localparam [18:0] FB_SW_U   = FB_SW;
    localparam [XW-1:0] FB_X0_U = FB_X0;
    localparam [YW-1:0] FB_Y0_U = FB_Y0;

    wire fb_in_x   = (x >= FB_X0_U) && (x < (FB_X0_U + FB_W[XW-1:0]));
    wire fb_in_y   = (y >= FB_Y0_U) && (y < (FB_Y0_U + FB_H[YW-1:0]));
    wire fb_inside = fb_in_x && fb_in_y;

    wire [XW-1:0] fb_lx = fb_in_x ? (x - FB_X0_U) : {XW{1'b0}};
    wire [YW-1:0] fb_ly = fb_in_y ? (y - FB_Y0_U) : {YW{1'b0}};

    // 放大：显示坐标 >> SHIFT 得到存储坐标（2 倍放大 -> 右移 1 位）
    // 先缩放（右移 SHIFT）再平移裁剪偏移（FB_CX/FB_CY）
    wire [XW-1:0] fb_sx = (fb_lx >> SHIFT) + FB_CX[XW-1:0];
    wire [YW-1:0] fb_sy = (fb_ly >> SHIFT) + FB_CY[YW-1:0];

    // +1 是"提前一个像素"的预取（BRAM 有 1 拍延迟）
    assign fb_addr = (fb_sy * FB_SW_U) + fb_sx + 19'd1;

    wire [23:0] bg_rgb_sel = (cfg_bg_src && fb_inside) ? fb_rgb888 : bg_rgb;

    bg_src #(.HDISP(HDISP), .VDISP(VDISP), .XW(XW), .YW(YW)) u_bg (
        .x    (x),
        .y    (y),
        .mode (ui_mode_s),
        .rgb  (bg_rgb)
    );

    //=========================================================================
    // 波形缓冲（跨时钟域）
    //=========================================================================
    wire signed [23:0] wave_sample;

    //-------------------------------------------------------------------------
    // 触发迟滞门限：把 env_track 送来的自适应值【夹在上下限之间】
    //-------------------------------------------------------------------------
    wire signed [23:0] th_lo = 24'sd32768;
    wire signed [23:0] th_hi = 24'sd131072;
    wire signed [23:0] wave_th_clamped = (wave_th < th_lo) ? th_lo
                                       : (wave_th > th_hi) ? th_hi
                                       : wave_th;

    // HOLD_SHIFT=2：每 4 次采集换一屏显示（约 25 屏/秒）
    //     1 -> 50 屏/秒   会重叠
    //     2 -> 25 屏/秒   ← 当前：够流畅，也不重叠
    //     3 -> 12.5 屏/秒 不重叠但明显卡顿
    wave_buf #(.DW(24), .AW(WAVE_AW), .SPAN(HDISP), .XW(XW), .ADAPT(1),
               .HOLD_SHIFT(2)) u_wave (
        .wclk   (clk_sys),
        .wrst_n (rst_sys_n),
        .we     (wave_we),
        .din    (wave_din),
        .rclk   (clk_pix),
        .rrst_n (rst_pix_n),
        .sof    (sof),
        .x      (x),
        .dout   (wave_sample),
        .th_in  (wave_th_clamped),
        // 调试/测试用的观测点，显示链不用
        .trig_pulse(),
        .done_pulse()
    );

    //=========================================================================
    // 波形增益（G 命令）
    //=========================================================================
    // 指数上限 8（= ×256），再大对 24 位数据就没意义了
    wire [3:0] gsh = (ui_wave_gain_s[3:0] > 4'd8) ? 4'd8 : ui_wave_gain_s[3:0];

    // 先符号扩展到 32 位再左移，避免"移出去又被截回来"
    wire signed [31:0] wave_ext = {{8{wave_sample[23]}}, wave_sample};
    wire signed [31:0] wave_sh  = wave_ext <<< gsh;

    localparam signed [31:0] WG_MAX32 =  32'sd8388607;    //  2^23-1
    localparam signed [31:0] WG_MIN32 = -32'sd8388608;    // -2^23

    wire signed [23:0] wave_adj = (wave_sh > WG_MAX32) ?  24'sh7FFFFF
                                : (wave_sh < WG_MIN32) ? -24'sh800000
                                : wave_sh[23:0];

    //=========================================================================
    // 状态行文字
    //=========================================================================
    wire        text_we;
    wire [15:0] text_waddr;
    wire [7:0]  text_wdata;
    wire        text_hit, text_lit;

    status_line #(.NLEN(`DISP_TXT_NLEN), .NC(`DISP_TXT_NLEN),
                  .NROW(`DISP_TXT_NL)) u_status (
        .clk           (clk_pix),
        .rst_n         (rst_pix_n),
        .cfg_view      ({5'b0, ui_view_s}),
        .cfg_style     ({4'b0, ui_style_s}),
        .cfg_spk_mute  (ui_spk_mute_s),
        .cfg_src       (ui_src_s),
        .cfg_img_idx   (ui_img_idx_s),
        .cfg_hue_spd   (ui_hue_spd_s),
        .cfg_wave_gain (ui_wave_gain_s),
        .cfg_bg_mode   ({4'b0, ui_mode_s}),
        .cfg_demo      (ui_demo_s),
        .tp_x          (tp_x_s),
        .tp_y          (tp_y_s),
        .tp_edges      (tp_edges_s),
        .dbg_adc  (dbg_adc),
        .dbg_sd_bytes (dbg_sd_bytes),
        .tp_low        (tp_low_s),
        .we            (text_we),
        .waddr         (text_waddr),
        .wdata         (text_wdata)
    );

    // NC=20：每行 20 字符 = 160 px 宽
    // NL=8 ：6 行配置标签 + 2 行触摸诊断
    text_buf #(.NC(`DISP_TXT_NLEN), .NL(`DISP_TXT_NL), .XW(XW), .YW(YW),
               // 文本框放到【右侧】：宽 = NLEN*8 = 80px，右边留 4px
               .TX0(HDISP-80-4), .TY0(2)) u_text (
        .clk   (clk_pix),
        .we    (text_we),
        .waddr (text_waddr),
        .wdata (text_wdata),
        .x     (x),
        .y     (y),
        .hit   (text_hit),
        .lit   (text_lit)
    );

    //=========================================================================
    // UI 按钮层
    //=========================================================================
    wire        ui_draw;
    wire [23:0] ui_rgb;
    wire [2:0]  ui_hit_k;
    wire        tab_hit_w;
    reg         tab_hit_d;

    // 把手按下的边沿检测（tab_hit_w 是电平，切成单拍脉冲给 ui_open 用）
    always @(posedge clk_pix) begin
        if (!rst_pix_n) tab_hit_d <= 1'b0;
        else            tab_hit_d <= tab_hit_w;
    end
    wire tab_press = tab_hit_w & ~tab_hit_d;

    // 按键手势过来的"翻转标志"：两级同步 + 边沿检测（同 tab_press 的用法）
    reg [2:0] panel_tog_sync;
    always @(posedge clk_pix) begin
        if (!rst_pix_n) panel_tog_sync <= 3'b000;
        else            panel_tog_sync <= {panel_tog_sync[1:0], panel_tog};
    end
    wire panel_tog_pix = panel_tog_sync[2] ^ panel_tog_sync[1];

    // 按键活动：同样两级同步 + 边沿检测
    reg [2:0] key_act_sync;
    always @(posedge clk_pix) begin
        if (!rst_pix_n) key_act_sync <= 3'b000;
        else            key_act_sync <= {key_act_sync[1:0], key_act};
    end
    wire key_act_pix = key_act_sync[2] ^ key_act_sync[1];


    wire [3:0] ui_active;

    ui_layer #(
        .NB(NB_UI), .XW(XW), .YW(YW),
        .BX0(UI_BX0), .BY0(UI_BY0), .BW(UI_BW), .BH(UI_BH), .GAP(UI_GAP),
        .TX(TAB_X), .TY(TAB_Y), .TW(TAB_W), .TH(TAB_H)
    ) u_ui (
        .x        (x),
        .y        (y),
        .tx       (tx_scr),
        .ty       (ty_scr),
        .pressed  (td_scr),
        .ui_by0   (ui_by0),
        .ui_open  (panel_target),
        .active   (ui_active),
        .draw     (ui_draw),
        .rgb      (ui_rgb),
        .hit_k    (ui_hit_k),
        .hit      (),
        .hit_act  (ui_btn_act),
        .tab_hit  (tab_hit_w)
    );

    // 高亮：锁存"最近一次按下的按钮"，松开后保持
    reg [21:0] hl_cnt;
    reg        td_scr_d;
    reg [3:0]  hl_act;                      // 触摸锁存下来的动作码
    wire       press_now = td_scr & ~td_scr_d;

    always @(posedge clk_pix) begin
        if (!rst_pix_n) begin
            td_scr_d <= 1'b0;
            hl_act   <= 4'hF;
            hl_cnt   <= 22'h3FFFFF;
        end else begin
            td_scr_d <= td_scr;
            if (press_now) begin
                hl_act <= ui_btn_act;       // 按下时锁存动作码
                hl_cnt <= 22'd0;
            end else if (hl_cnt != 22'h3FFFFF) begin
                hl_cnt <= hl_cnt + 1'b1;    // 保持一段时间后自动过期
            end
        end
    end

    // 高亮的来源，优先级：触摸刚按下的（0.3s 内） > 按键光标
    wire        touch_hl = (hl_cnt != 22'h3FFFFF);
    assign      ui_active = touch_hl ? hl_act : ui_sel;

    //=========================================================================
    // 面板展开/收起的驱动
    //=========================================================================
    always @(posedge clk_pix) begin
        if (!rst_pix_n) begin
            ui_open  <= 1'b0;
            idle_cnt <= 24'd0;
        end else begin
            //  两者互斥
            if (tab_press || panel_tog_pix) begin
                ui_open  <= ~ui_open;       // 点把手 / KEY1 双击 -> 切换
                idle_cnt <= {TAB_CW{1'b0}}; // 切换即视为"刚活动过"
            end else begin
                // 任何【用户动作】都算活动，重置空闲计时
                if (td_scr || key_act_pix) idle_cnt <= {TAB_CW{1'b0}};
                else if (idle_cnt != TAB_CNT[TAB_CW-1:0])
                    idle_cnt <= idle_cnt + 1'b1;

                if (idle_cnt == TAB_CNT[TAB_CW-1:0])  // 空闲超时 -> 自动收起
                    ui_open <= 1'b0;
            end
        end
    end

    assign panel_open   = ui_open;
    assign ui_btn_press = press_now;

    //=========================================================================
    // 混合
    //=========================================================================
    disp_mix #(
        .HDISP(HDISP), .VDISP(VDISP), .NBARS(NBARS),
        .NBARS_DISP(NBARS_DISP), .HW(HW),
        .XW(XW), .YW(YW),
        .BARS_Y0(BARS_Y0), .BARS_H(BARS_H), .BAR_GAP(BAR_GAP),
        .POL_CX(POL_CX), .POL_CY(POL_CY), .POL_RIN(POL_RIN), .POL_RMAX(POL_RMAX),
        .WAVE_CY(WAVE_CY), .WAVE_AMP(WAVE_AMP), .WAVE_TH(WAVE_TH)
    ) u_mix (
        .x       (x),
        .y       (y),
        .bg_rgb  (bg_rgb_sel),
        .bars    (bars),
        .hue_off (hue_off),
        .wave    (wave_adj),
        .view_en (ui_view_s),
        .mode    (ui_style_s),
        .pres_bar(pres_bar),
        .pres_pol(pres_pol),
        .pres_wav(pres_wav),
        // WITH_TEXT=0 不把状态行的命中/点亮传给混色器（等于不画）
        .text_hit(WITH_TEXT ? text_hit : 1'b0),
        .text_lit(WITH_TEXT ? text_lit : 1'b0),
        // WITH_UI=0 不画面板
        .ui_draw (WITH_UI ? ui_draw : 1'b0),
        .ui_rgb  (ui_rgb),
        .rgb     (rgb_in)
    );

endmodule
