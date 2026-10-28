//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    disp_mix
// Module Name:    disp_mix
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    disp_mix.v - 背景 + 极坐标频谱 + 波形 + 柱状频谱 合成（纯组合）
// Dependencies:   disp_cfg.vh
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


`include "disp_cfg.vh"

module disp_mix #(
    // 参数默认值
    parameter integer HDISP    = `DISP_HDISP,
    parameter integer VDISP    = `DISP_VDISP,
    parameter integer NBARS    = `DISP_NBARS,
    parameter integer HW       = 9,

    // 坐标位宽
    parameter integer XW       = 10,
    parameter integer YW       = 9,

    // 每根柱占多少像素 = 2^BAR_SH
    parameter integer BAR_SH   = 3,
    // 显示用多少根柱（决定每根柱占多少像素）
    parameter integer NBARS_DISP = 60,

    // ---- 柱状频谱区 ----
    parameter integer BARS_Y0  = `DISP_BARS_Y0,
    parameter integer BARS_H   = `DISP_BARS_H,
    parameter integer BAR_GAP  = `DISP_BAR_GAP,

    // ---- 极坐标区 ----
    parameter integer POL_CX   = `DISP_POL_CX,
    parameter integer POL_CY   = `DISP_POL_CY,
    parameter integer POL_RIN  = `DISP_POL_RIN,
    parameter integer POL_RMAX = `DISP_POL_RMAX,

    // ---- 波形区 ----
    parameter integer WAVE_CY  = `DISP_WAVE_CY,
    parameter integer WAVE_AMP = `DISP_WAVE_AMP,   // 上限必须 <= 2^(24-SH)-1
    parameter integer WAVE_TH  = `DISP_WAVE_TH
) (
    input  wire [XW-1:0]        x,
    input  wire [YW-1:0]        y,
    input  wire [23:0]          bg_rgb,
    input  wire [NBARS*HW-1:0]  bars,
    input  wire [6:0]           hue_off,  // 色相滚动偏移（0..127 循环）
    input  wire signed [23:0]   wave,     // 本列对应的音频采样
    input  wire [2:0]           view_en,  // [0]柱状 [1]极坐标 [2]波形
    input  wire [3:0]           mode,     // 柱体风格（0=实心 1=半透明）

    //-------------------------------------------------------------------------
    // 视图“存在度”（来自 ui_anim，0..128）
    //-------------------------------------------------------------------------
    input  wire [7:0]           pres_bar,
    input  wire [7:0]           pres_pol,
    input  wire [7:0]           pres_wav,

    //-------------------------------------------------------------------------
    // 文字叠加（来自 text_buf）
    //   hit = 该像素落在文本框内（用来画底板）
    //   lit = 该像素是一个字形像素
    //-------------------------------------------------------------------------
    input  wire                 text_hit,
    input  wire                 text_lit,

    //-------------------------------------------------------------------------
    // UI 按钮层（来自 ui_layer）
    //   画在【柱状/极坐标之上、文字之下】
    //-------------------------------------------------------------------------
    input  wire                 ui_draw,
    input  wire [23:0]          ui_rgb,
    output reg  [23:0]          rgb
);

    localparam integer AW     = $clog2(NBARS);       // 柱号位宽（60 -> 6）

    // 常量做成长度匹配的字面值，避免各处写死位宽
    localparam [YW-1:0] VDISP_L = VDISP;
    localparam [YW-1:0] CY_L    = WAVE_CY;
    localparam [YW-1:0] Y0_L    = BARS_Y0;
    localparam [YW-1:0] TH_L    = WAVE_TH;

    //=========================================================================
    // 柱状频谱
    //=========================================================================
    // 柱号：把屏幕列映射到"第几根柱"
    localparam integer AW_D = $clog2(NBARS_DISP);
    wire [AW_D-1:0] dbar = x[BAR_SH+AW_D-1 : BAR_SH];

    wire [AW-1:0] bbar;
    generate
        if (NBARS_DISP == NBARS) begin : g_ident
            // LCD 路径
            assign bbar = dbar[AW-1:0];
        end else begin : g_scale
            // HDMI 路径
            assign bbar = (dbar * NBARS) / NBARS_DISP;
        end
    endgenerate
    wire [HW-1:0] bbh  = bars[bbar*HW +: HW];

    // 柱高 pres_bar/128（右移 7 位）
    wire [HW+7:0] bbh_s = bbh * pres_bar;            // 9+8 = 17 位，最大 511*128
    wire [HW-1:0] bbh_a = bbh_s[HW+6 : 7];           // /128

    // 柱高 0..511 -> 像素 0..BARS_H-1
    wire [YW-1:0] bhpx = bbh_a[HW-1:1];              // /2 -> 0..255（= BARS_H-1）

    wire [YW-1:0] b_from_bot = VDISP_L - 1'b1 - y;
    wire          b_area     = (y >= Y0_L);
    wire          b_col      = (x[BAR_SH-1:0] >= BAR_GAP[BAR_SH-1:0]);  // 柱内左侧空隙
    wire          b_hit      = b_area && (b_from_bot < bhpx) && b_col;
    wire          b_lit      = b_hit && view_en[0];

    //=========================================================================
    // 极坐标频谱
    //=========================================================================
    wire          p_in_disc, p_lit;
    wire [5:0]    p_bar;
    wire [7:0]    p_r;

    polar_map #(
        .NBARS(NBARS), .HW(HW),
        .CX(POL_CX), .CY(POL_CY), .R_IN(POL_RIN), .R_MAX(POL_RMAX),
        .XW(XW), .YW(YW)
    ) u_polar (
        .x       (x),
        .y       (y),
        .bars    (bars),
        .in_disc (p_in_disc),
        .lit     (p_lit),
        .bar_idx (p_bar),
        .r_out   (p_r),
        .pres    (pres_pol)          // 圆盘整体缩放
    );

    // 内圆画一圈淡环，让"圆心"可见
    wire p_core = view_en[1] && p_in_disc && (p_r >= POL_RIN - 3) && (p_r < POL_RIN);
    wire p_lit_g = view_en[1] && p_lit;

    //=========================================================================
    // 波形（中心线固定，向左右展开）
    //=========================================================================
    wire [24:0] wabs = wave[23] ? ({1'b0, ~wave} + 1'b1) : {1'b0, wave};
    wire [6:0]  wraw = wabs[23:`DISP_WAVE_SH];       // SH=17 -> 0..127
    wire [6:0]  wclamp = (wraw > WAVE_AMP[6:0]) ? WAVE_AMP[6:0] : wraw;

    // 显示前放大 1.5 倍（× 3 / 2）
    wire [7:0]  wclamp_3 = {wclamp, 1'b0} + wclamp;    // ×3
    wire [6:0]  wclamp_x = (wclamp_3[7:1] > WAVE_AMP[6:0])
                         ? WAVE_AMP[6:0] : wclamp_3[7:1];   // /2 再钳位

    // pres_wav/128（右移 7 位）
    wire [14:0] wamp_s = wclamp_x * pres_wav;    // 7+8 = 15 位，最大 127*128=16256
    wire [7:0]  wamp   = wamp_s[14:7];           // /128 ⟹ 0..127

    wire [YW-1:0] wamp_y = wamp;                     // 零扩展到位宽

    // 正负方向：正值朝上
    wire [YW-1:0] w_y  = wave[23] ? (CY_L + wamp_y) : (CY_L - wamp_y);

    // 线宽：|y - w_y| <= WAVE_TH
    wire [YW-1:0] w_dy = (y > w_y) ? (y - w_y) : (w_y - y);
    wire        w_line = view_en[2] && (w_dy <= TH_L);
    // 波形关掉时，画一条很淡的中线提示"这里本来是波形区"
    // wire        w_axis = !view_en[2] && (y == CY_L);

    //=========================================================================
    // 颜色
    //=========================================================================
    wire [6:0]  hue_bar = {bbar[4:0], 2'b00} + hue_off;  // 60 根 x 4 -> 取模 128 循环
    wire [6:0]  hue_pol = {p_bar[4:0], 2'b00} + hue_off;

    wire [23:0] rb_bar, rb_pol;
    rainbow_rom u_rb_bar (.addr(hue_bar), .rgb(rb_bar));
    rainbow_rom u_rb_pol (.addr(hue_pol), .rgb(rb_pol));

    localparam [23:0] AXIS_RGB = 24'h20_38_50;       // 波形中线：暗青
    localparam [23:0] CORE_RGB = 24'h40_50_60;       // 圆心环：淡灰蓝
    localparam [23:0] TEXT_RGB = 24'hF0_F0_F0;       // 文字：近白

    // 文字底板：把背景压到 1/4 亮度
    wire [23:0] TEXT_BG = {2'b00, bg_rgb[23:18],
                           2'b00, bg_rgb[15:10],
                           2'b00, bg_rgb[7:2]};

    //=========================================================================
    // 合成
    //=========================================================================
    always @(*) begin
        // 底层：背景
        rgb = bg_rgb;

        // 柱状频谱
        if (b_lit)
            rgb = rb_bar;

        // 波形（画在柱状之上，这样底部区也能看到波形）
        if (w_line)
            rgb = rb_pol;
        // else if (w_axis)
        //     rgb = AXIS_RGB;

        // 极坐标
        if (p_lit_g)
            rgb = rb_pol;
        else if (p_core)
            rgb = CORE_RGB;

        // UI 按钮层（盖住它下面的柱状/极坐标）
        if (ui_draw)
            rgb = ui_rgb;

        // 文字在最上层（底板 + 字形）
        if (text_lit)
            rgb = TEXT_RGB;
        else if (text_hit)
            rgb = TEXT_BG;
    end

endmodule
