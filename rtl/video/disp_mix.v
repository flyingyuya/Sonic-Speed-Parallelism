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

    //-------------------------------------------------------------------------
    // 坐标位宽（P1-3a）
    //   x/y 从时序计数器的 hcnt/vcnt 减出来，位宽要和那边一致。
    //   默认 10/9 对应 480x272（= 原来写死的 [9:0] / [8:0]），本次重构逐位不变。
    //-------------------------------------------------------------------------
    parameter integer XW       = 10,
    parameter integer YW       = 9,

    //-------------------------------------------------------------------------
    // 每根柱占多少像素 = 2^BAR_SH
    //   原来写死 `x[8:3]`（8 px/柱，因 480/60 = 8 恰好是 2 的幂）—— 零成本。
    //   但 1280/60 = 21.33 不是整数，也不是 2 的幂，所以换分辨率时
    //   【不能只改参数就算完】，必须重新考虑柱映射（改柱数或用小 ROM 除法）。
    //   这里把移位量提出来，至少让当前这套能参数化。
    //-------------------------------------------------------------------------
    parameter integer BAR_SH   = 3,

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
    //-----------------------------------------------------------------------------
    //   128 = 完全展开。显示侧把几何量乘以 pres/128（就是右移 7 位）。
    //   这样切换视图预设时是“长出来 / 缩回去”，而不是硬跳。
    //   保留 view_en 作为“该视图要不要显示”的粗开关：pres 还会跟着它收敛，
    //   但两者不同步的中间帧靠 pres 保证平滑。
    //-------------------------------------------------------------------------
    input  wire [7:0]           pres_bar,
    input  wire [7:0]           pres_pol,
    input  wire [7:0]           pres_wav,

    //-------------------------------------------------------------------------
    // 文字叠加（来自 text_buf）
    //   hit = 该像素落在文本框内（用来画底板）
    //   lit = 该像素是一个字形像素
    //   文字画在【最上层】，所以放在输出级最后处理。
    //-------------------------------------------------------------------------
    input  wire                 text_hit,
    input  wire                 text_lit,
    output reg  [23:0]          rgb
);

    localparam integer BARS_H = VDISP - BARS_Y0;     // 96
    localparam integer AW     = $clog2(NBARS);       // 柱号位宽（60 -> 6）

    // 常量做成长度匹配的字面值，避免各处写死位宽
    localparam [YW-1:0] VDISP_L = VDISP;
    localparam [YW-1:0] CY_L    = WAVE_CY;
    localparam [YW-1:0] Y0_L    = BARS_Y0;
    localparam [YW-1:0] TH_L    = WAVE_TH;

    //=========================================================================
    // 1. 柱状频谱
    //=========================================================================
    wire [AW-1:0] bbar = x[BAR_SH+AW-1 : BAR_SH];    // 每根柱 2^BAR_SH 像素
    wire [HW-1:0] bbh  = bars[bbar*HW +: HW];

    // 柱高 × pres_bar/128（右移 7 位，零成本）—— 切换视图时柱子在“长/缩”
    wire [HW+7:0] bbh_s = bbh * pres_bar;            // 9+8 = 17 位，最大 511*128
    wire [HW-1:0] bbh_a = bbh_s[HW+6 : 7];           // /128

    // 柱高 0..511 -> 像素 0..95： h = bh * 3 / 16
    //   ⚠️ 这个 3/16 是按【当前布局】算出来的：BARS_H=96 像素、bh 满量程 512
    //      （96*16/3 ≈ 512）。换布局必须重算，不能只改参数。
    wire [HW+1:0] bmul = (bbh_a << 1) + bbh_a;       // bh * 3
    wire [YW-1:0] bhpx = bmul[HW+1 : 4];             // /16 -> 0..95

    wire [YW-1:0] b_from_bot = VDISP_L - 1'b1 - y;
    wire          b_area     = (y >= Y0_L);
    wire          b_col      = (x[BAR_SH-1:0] >= BAR_GAP[BAR_SH-1:0]);  // 柱内左侧空隙
    wire          b_hit      = b_area && (b_from_bot < bhpx) && b_col;
    wire          b_lit      = b_hit && view_en[0];

    //=========================================================================
    // 2. 极坐标频谱
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
    wire [5:0]  wclamp = (wraw > WAVE_AMP[5:0]) ? WAVE_AMP[5:0] : wraw;

    // × pres_wav/128（右移 7 位）—— 切换波形视图时振幅平滑地长出来
    wire [12:0] wamp_s = wclamp * pres_wav;          // 6+8 = 14? 实际最大 22*128=2816
    wire [5:0]  wamp   = wamp_s[12:7];               // /128

    wire [YW-1:0] wamp_y = wamp;                     // 零扩展到位宽
    wire [YW-1:0] w_y  = wave[23] ? (CY_L - wamp_y) : (CY_L + wamp_y);

    // 线宽：|y - w_y| <= WAVE_TH
    wire [YW-1:0] w_dy = (y > w_y) ? (y - w_y) : (w_y - y);
    wire        w_line = view_en[2] && (w_dy <= TH_L);
    // 波形关掉时，画一条很淡的中线提示"这里本来是波形区"
    wire        w_axis = !view_en[2] && (y == CY_L);

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
    localparam [23:0] TEXT_RGB = 24'hF0_F0_F0;       // 文字：近白

    // 文字底板：把背景压到 1/4 亮度，而不是盖一块死黑。
    //   这样文字在亮背景和暗背景上都读得清，又不会完全挡住后面的画面 ——
    //   「半透明底板」比「实心黑框」看着专业，代价只是一次右移。
    //   三个通道各右移 2 位：R(23:16)>>2 放回 23:18、G(15:8)>>2 放回 15:10、
    //   B(7:0)>>2 放回 7:2，每段高位补 0。写成拼接比拼回去的移位清楚得多。
    wire [23:0] TEXT_BG = {2'b00, bg_rgb[23:18],
                           2'b00, bg_rgb[15:10],
                           2'b00, bg_rgb[7:2]};

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

        // 极坐标
        if (p_lit_g)
            rgb = rb_pol;
        else if (p_core)
            rgb = CORE_RGB;

        // 文字在最上层（底板 + 字形）
        if (text_lit)
            rgb = TEXT_RGB;
        else if (text_hit)
            rgb = TEXT_BG;
    end

endmodule
