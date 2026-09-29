//=============================================================================
// disp_mix.v - 背景 + 极坐标频谱 + 波形 + 柱状频谱 合成（纯组合）
//-----------------------------------------------------------------------------
// 【屏幕分区】（480x272）
//
//     y 20  ┌────────────────────────────────────┐
//           │            ╭──────────╮            │
//           │           (     ◉     )            │  极坐标：圆心 (240, 96)
//           │            ╰──────────╯            │  半径 18~76（直径 152）
//   y 110   │  ~~~~~~~~~~~~波形~~~~~~~~~~~~~~~~~  │  波形：中线 y = 136
//   y 136   │  ~~~~（屏幕垂直中心，左右展开）~~~~   │  振幅 ±26
//   y 162   │                                    │  ← 极坐标与波形【允许重叠】
//   y 176   ├────────────────────────────────────┤
//           │   ▁▃▅▇█▇▅▃▁   柱状频谱                │  柱状：y 176~271（96 px 高）
//   y 272   └────────────────────────────────────┘  60 根 x 8 px（全宽）
//
// 【绘制顺序】背景 -> 柱状 -> 波形 -> 极坐标
//   极坐标画在最上层。它只点亮辐条，所以波形会从辐条的空隙里透出来 ——
//   这正是"允许重叠"想要的效果。
//
// 【几何为什么还能免运算】
//   柱状 480/60 = 8   -> bar_idx = x[8:3]，一次移位
//   柱高 511 -> 96 px -> h_px = bh*3/16 = (bh*2 + bh) >> 4，全是移位加法
//   极坐标交给 polar_map（它内部也只有比较和移位加法）
//=============================================================================
`timescale 1ns/1ps

`include "disp_cfg.vh"

module disp_mix #(
    // 默认值全部来自 rtl/video/disp_cfg.vh —— 布局的唯一真相源
    parameter integer HDISP    = `DISP_HDISP,
    parameter integer VDISP    = `DISP_VDISP,
    parameter integer NBARS    = `DISP_NBARS,
    parameter integer HW       = 9,

    // ---- 柱状频谱区 ----
    parameter integer BARS_Y0  = `DISP_BARS_Y0,
    parameter integer BAR_GAP  = `DISP_BAR_GAP,

    // ---- 极坐标区 ----
    parameter integer POL_CX   = `DISP_POL_CX,
    parameter integer POL_CY   = `DISP_POL_CY,
    parameter integer POL_RIN  = `DISP_POL_RIN,
    parameter integer POL_RMAX = `DISP_POL_RMAX,

    // ---- 波形区 ----
    parameter integer WAVE_CY  = `DISP_WAVE_CY,
    parameter integer WAVE_AMP = `DISP_WAVE_AMP,
    parameter integer WAVE_TH  = `DISP_WAVE_TH
) (
    input  wire [9:0]           x,
    input  wire [8:0]           y,
    input  wire [23:0]          bg_rgb,
    input  wire [NBARS*HW-1:0]  bars,
    input  wire [6:0]           hue_off,  // 色相滚动偏移（0..127 循环）
    input  wire signed [23:0]   wave,     // 本列对应的音频采样
    input  wire [2:0]           view_en,  // [0]柱状 [1]极坐标 [2]波形
    input  wire [3:0]           mode,     // 柱体风格（0=实心 1=半透明）
    output reg  [23:0]          rgb
);

    localparam integer BARS_H = VDISP - BARS_Y0;     // 96

    //=========================================================================
    // 1. 柱状频谱
    //=========================================================================
    wire [5:0]    bbar = {1'b0, x[8:3]};             // 480/60 = 8
    wire [HW-1:0] bbh  = bars[bbar*HW +: HW];

    // 柱高 0..511 -> 像素 0..96： h = bh * 3 / 16
    wire [10:0]   bmul = (bbh << 1) + bbh;           // bh * 3
    wire [6:0]    bhpx = bmul[10:4];                 // / 16 -> 0..95

    wire [8:0]    b_from_bot = VDISP[8:0] - 9'd1 - y;
    wire          b_area     = (y >= BARS_Y0[8:0]);
    wire          b_col      = (x[2:0] >= BAR_GAP[2:0]);   // 每根柱 8 px，看低 3 位
    wire          b_hit      = b_area && (b_from_bot < {2'b00, bhpx}) && b_col;
    wire          b_lit      = b_hit && view_en[0];

    //=========================================================================
    // 2. 极坐标频谱
    //=========================================================================
    wire          p_in_disc, p_lit;
    wire [5:0]    p_bar;
    wire [7:0]    p_r;

    polar_map #(
        .NBARS(NBARS), .HW(HW),
        .CX(POL_CX), .CY(POL_CY), .R_IN(POL_RIN), .R_MAX(POL_RMAX)
    ) u_polar (
        .x       (x),
        .y       (y),
        .bars    (bars),
        .in_disc (p_in_disc),
        .lit     (p_lit),
        .bar_idx (p_bar),
        .r_out   (p_r)
    );

    // 内圆画一圈淡环，让"圆心"可见（与参考图一致的观感）
    wire p_core = view_en[1] && p_in_disc && (p_r >= POL_RIN - 3) && (p_r < POL_RIN);
    wire p_lit_g = view_en[1] && p_lit;

    //=========================================================================
    // 3. 波形（中心线固定，向左右展开）
    //=========================================================================
    // 采样是 24 bit 有符号（Q1.23）。映射到像素偏移：
    //   |s| >> 18 -> 0..31（满量程 2^23 >> 18 = 32），再钳到 WAVE_AMP
    //   ⚠️ 一开始写的是 >>20，满量程只剩 ±8 像素，波形几乎是一条直线。
    //      移位量要按"满量程映射到 WAVE_AMP"来算，不能凭感觉。
    wire [24:0] wabs = wave[23] ? ({1'b0, ~wave} + 1'b1) : {1'b0, wave};
    wire [5:0]  wraw = wabs[23:18];                  // 0..31
    wire [5:0]  wamp = (wraw > WAVE_AMP[5:0]) ? WAVE_AMP[5:0] : wraw;
    wire [8:0]  w_y  = wave[23] ? (WAVE_CY[8:0] - {3'b000, wamp})
                                : (WAVE_CY[8:0] + {3'b000, wamp});

    // 线宽：|y - w_y| <= WAVE_TH
    wire [8:0]  w_dy   = (y > w_y) ? (y - w_y) : (w_y - y);
    wire        w_line = view_en[2] && (w_dy <= WAVE_TH[8:0]);
    // 波形关掉时，画一条很淡的中线提示"这里本来是波形区"
    wire        w_axis = !view_en[2] && (y == WAVE_CY[8:0]);

    //=========================================================================
    // 4. 颜色
    //=========================================================================
    wire [6:0]  hue_bar = {bbar[4:0], 2'b00} + hue_off;  // 60 根 x 4 -> 取模 128 循环
    wire [6:0]  hue_pol = {p_bar[4:0], 2'b00} + hue_off;

    wire [23:0] rb_bar, rb_pol;
    rainbow_rom u_rb_bar (.addr(hue_bar), .rgb(rb_bar));
    rainbow_rom u_rb_pol (.addr(hue_pol), .rgb(rb_pol));

    localparam [23:0] AXIS_RGB = 24'h20_38_50;       // 波形中线：暗青
    localparam [23:0] CORE_RGB = 24'h40_50_60;       // 圆心环：淡灰蓝

    //=========================================================================
    // 5. 合成
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
        else if (w_axis)
            rgb = AXIS_RGB;

        // 极坐标在最上层
        if (p_lit_g)
            rgb = rb_pol;
        else if (p_core)
            rgb = CORE_RGB;
    end

endmodule
