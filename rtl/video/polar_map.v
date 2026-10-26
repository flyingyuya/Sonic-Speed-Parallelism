//////////////////////////////////////////////////////////////////////////////////
// Company:        个人项目 / SonicTwin-Engine
// Engineer:       flyingyu
//
// Create Date:    2026-10-26
// Design Name:    polar_map
// Module Name:    polar_map
// Project Name:   音速双擎（SonicTwin-Engine）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    polar_map.v - 极坐标（径向）频谱的坐标变换（纯组合）
//                 对每个像素 (x, y)，算出：
//                 ① r       —— 到圆心的近似距离
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module polar_map #(
    parameter integer NBARS = 60,
    parameter integer HW    = 9,
    parameter integer CX    = 120,      // 圆心 x
    parameter integer CY    = 104,      // 圆心 y
    parameter integer R_IN  = 20,       // 内圆半径（辐条从这里开始长）
    parameter integer R_MAX = 96,       // 最大半径（超出不画）

    //-------------------------------------------------------------------------
    // 位宽（P1-3a）
    //-----------------------------------------------------------------------------
    // 必须写在【参数表里】（端口声明要更早确定，见账本第 24 条）。
    //   CW   : 相对圆心的有符号偏移。x/y 相减，多留 1 位符号。
    //          ★ 必须按 max(XW,YW) 算：只看其中一个会在另一个更大时溢出。
    //   RADW : 真实半径位宽（R_MAX=62 -> 6）。原来是写死的 [8:0]，偏大但结果一样。
    //   RW   : r_out 调试观测位宽（维持 8 位不变）。
    //-------------------------------------------------------------------------
    parameter integer XW   = 10,
    parameter integer YW   = 9,
    parameter integer CW   = ((XW > YW) ? XW : YW) + 1,
    parameter integer RADW = $clog2(R_MAX + 1),
    parameter integer RW   = 8
) (
    input  wire [XW-1:0]        x,
    input  wire [YW-1:0]        y,
    input  wire [NBARS*HW-1:0]  bars,
    output wire                 in_disc,    // 该像素落在圆盘内
    output wire                 lit,        // 该像素应点亮
    output wire [5:0]           bar_idx,    // 属于哪根柱（NBARS 最多 64）
    output wire [7:0]           r_out,      // 到圆心的近似半径（调试用）

    //-------------------------------------------------------------------------
    // 存在度（来自 ui_anim，0..128）。圆盘【整体】按它缩放：
    //   128 = 满尺寸，0 = 完全不显示。切换视图时圆盘平滑地长出来 / 缩回去。
    //
    // ⚠️ 它必须是【运行时输入】，不能当 parameter：
    //    一开始写成 parameter，结果 disp_mix 传 pres_pol（一根 wire）进去就报
    //    "A reference to a net or variable is not allowed in a constant expression"。
    //    参数是【编译期】常量，而存在度是每帧变的。
    //-------------------------------------------------------------------------
    input  wire [7:0]           pres
);

    localparam integer AW = $clog2(NBARS);

    // 常量做成长度匹配的字面值，避免各处写死位宽
    localparam signed [CW-1:0] CX_L = CX;
    localparam signed [CW-1:0] CY_L = CY;

    // 按 pres/128 缩放后的实际半径（128 -> 原值，0 -> 0）
    //   同时缩 R_IN 和 R_MAX，所以是【整体缩放】而不是“只缩短辐条”。
    //   缩到 0 时 rmax2 = 0，d2 < 0 永远不成立 -> 整个圆盘不显示，符合预期。
    localparam [RADW-1:0] RIN_C  = R_IN;
    localparam [RADW-1:0] RMAX_C = R_MAX;

    wire [RADW+7:0] rin_s  = RIN_C  * pres;          // <= 62*128 = 7936
    wire [RADW+7:0] rmax_s = RMAX_C * pres;
    wire [RADW-1:0] RIN_L  = rin_s [RADW+6 : 7];     // /128
    wire [RADW-1:0] RMAX_L = rmax_s[RADW+6 : 7];

    //=========================================================================
    // 1. 相对圆心的有符号偏移
    //=========================================================================
    // 先把 x/y 零扩展（坐标非负，最高位为 0）到 CW 位再相减 ——
    // 直接写 $signed({1'b0, x}) 的话，当 YW > XW 时这一侧只有 XW+1 位，
    // 减法会在不够宽的位上做，结果就错了。
    wire signed [CW-1:0] x_s = x;
    wire signed [CW-1:0] y_s = y;

    wire signed [CW-1:0] dx = x_s - CX_L;
    wire signed [CW-1:0] dy = y_s - CY_L;

    wire [CW-1:0] ax = dx[CW-1] ? (~dx + 1'b1) : dx;   // |dx|
    wire [CW-1:0] ay = dy[CW-1] ? (~dy + 1'b1) : dy;   // |dy|

    wire dx_neg = dx[CW-1];
    wire dy_neg = dy[CW-1];

    wire diag = (ay > ax);                          // 更靠近 y 轴

    wire [CW-1:0] big = diag ? ay : ax;
    wire [CW-1:0] sml = diag ? ax : ay;

    //=========================================================================
    // 2. 半径的平方（精确，避开开方）
    //=========================================================================
    wire [2*CW-1:0] ax2 = ax * ax;
    wire [2*CW-1:0] ay2 = ay * ay;
    wire [2*CW:0]   d2  = {1'b0, ax2} + {1'b0, ay2};   // dx^2 + dy^2

    // r 的平方：半径 <= R_MAX，所以 2*RADW 位就够
    wire [2*RADW-1:0] rmax2 = RMAX_L * RMAX_L;
    wire [2*RADW-1:0] rmin2 = RIN_L  * RIN_L;

    // 零扩展到 d2 的宽度后再比，不能写 {5'b0, ...} 这种写死的拼接
    wire [2*CW:0] rmax2_e = rmax2;
    wire [2*CW:0] rmin2_e = rmin2;
    // r_out 仅供调试观测，用便宜的 alpha-max-beta-min（有 ~9% 误差，别当真值用）
    //   ⚠️ 钳位上限是 {RW{1'b1}}（RW=8 时 = 255）。
    //      一开始写成 {CW+2-RW{1'b1}}，CW=11 时只有 5 位 = 31，
    //      把大半径全钳成 31，TB 里的相对误差从 29% 爆到 763%。
    wire [CW+2:0]     sml7  = (sml << 3) - sml;           // sml * 7
    wire [CW+1:0]     rad   = big + (sml7 >> 4);
    localparam [CW+1:0] ROUT_MAX = {RW{1'b1}};
    assign r_out = (rad > ROUT_MAX) ? {RW{1'b1}} : rad[RW-1:0];

    //=========================================================================
    // 3. 八分圆编号（0..7，逆时针从 +x 轴起）
    //    dy＞0 当成"向上"（屏幕上就是向下，只影响镜像，不影响观感）
    //
    //    ⚠️ 四个象限的编号顺序不能凭直觉写：
    //       00 是第 1 象限（0~90°）  -> 0,1
    //       10 是第 2 象限（90~180°） -> 2,3
    //       11 是第 3 象限（180~270°）-> 4,5
    //       01 是第 4 象限（270~360°）-> 6,7
    //    写成 00/01/10/11 顺序（即 0,1 / 2,3 / 4,5 / 6,7）是错的 ——
    //    那样会把第 4 象限当成第 2 象限，辐条顺序整个乱掉。
    //=========================================================================
    reg [2:0] oct;

    always @(*) begin
        case ({dx_neg, dy_neg})
            2'b00: oct = diag ? 3'd1 : 3'd0;        // dx>=0, dy>=0   0..90
            2'b10: oct = diag ? 3'd2 : 3'd3;        // dx< 0, dy>=0  90..180
            2'b11: oct = diag ? 3'd5 : 3'd4;        // dx< 0, dy< 0 180..270
            default: oct = diag ? 3'd6 : 3'd7;      // dx>=0, dy< 0 270..360
        endcase
    end

    //=========================================================================
    // 4. 八分圆内再分 8 段 -> 共 64 个扇区
    //    七条边界的正切值用 /64 的整数近似：6、13、19、26、34、43、52
    // =========================================================================
    wire [CW+5:0] t64 = sml * 64'd64;               // sml * 64
    // 七条边界的正切值（乘 64 取整）：6、13、19、26、34、43、52
    wire [CW+5:0] e0  = (big << 2) + (big << 1);                   // big * 6
    wire [CW+5:0] e1  = (big << 3) + (big << 2) + big;             // big * 13
    wire [CW+5:0] e2  = (big << 4) + (big << 1) + big;             // big * 19
    wire [CW+5:0] e3  = (big << 4) + (big << 3) + (big << 1);      // big * 26
    wire [CW+5:0] e4  = (big << 5) + (big << 1);                   // big * 34
    wire [CW+5:0] e5  = (big << 5) + (big << 3) + (big << 1) + big;// big * 43
    wire [CW+5:0] e6  = (big << 5) + (big << 4) + (big << 2);      // big * 52

    // ⚠️ 8 段只需要 3 位！写成 4 位会让 sector={oct,sub} 变成 7 位被截断，
    //    高半个圆全被压到柱 0（这个 bug 是 TB 穷举出来才发现的）。
    wire [2:0] fsub = {2'b00, (t64 > e0)} + {2'b00, (t64 > e1)}
                    + {2'b00, (t64 > e2)} + {2'b00, (t64 > e3)}
                    + {2'b00, (t64 > e4)} + {2'b00, (t64 > e5)}
                    + {2'b00, (t64 > e6)};

    // 奇数八分圆里 t 随角度【减小】，所以段号要反过来
    wire [2:0] sub = oct[0] ? (~fsub) : fsub;

    // 64 个扇区
    wire [5:0]     sector = {oct, sub};

    //=========================================================================
    // 5. 64 扇区 -> NBARS 根柱：bar = sector * NBARS / 64
    //    NBARS 是常数，综合时就是一个常数乘法（移位加法），不需要 DSP。
    //    NBARS=60 时每个柱约分到 1.07 个扇区，所以极坐标的辐条比柱状图略粗 ——
    //    这是 360/64 = 5.625° 的固有粒度决定的。
    // =========================================================================
    wire [6+AW-1:0] sN   = sector * NBARS[AW-1:0];   // <= 63*60 = 3780
    wire [AW-1:0]   bar  = sN[6+AW-1:6];             // / 64
    wire [AW-1:0]   bar_safe = (bar >= NBARS[AW-1:0]) ? (NBARS-1) : bar;

    assign bar_idx = bar_safe;

    //=========================================================================
    // 6. 点亮判定：R_IN^2 <= dx^2+dy^2 < (R_IN + 柱高像素)^2
    //=========================================================================
    wire [HW-1:0] bh  = bars[bar_safe*HW +: HW];   // 0..511

    // 柱高(0..511) 映射到半径增量。
    //   ⚠️ 必须按【实际可用半径跨度】缩放，不能想当然右移几位：
    //      跨度 = R_MAX - R_IN = 58，所以系数取 58/512 ≈ 29/256。
    //      最初写的 bh>>2（=bh/4）会让 bh>232 的柱全部被钳到 R_MAX，
    //      画出来是一整块实心圆盘，完全看不出频谱形状。
    //   29/256 = 32/256 - 2/256 - 1/256 -> (bh<<5) - (bh<<1) - bh，再右移 8
    wire [HW+4:0] bhm   = (bh << 5) - (bh << 1) - bh;  // bh * 29
    wire [RADW-1:0] bh2 = bhm[HW+4:8];                 // /256 -> 0..57

    // ⚠️ r_hi 要比 RADW 【宽 1 位】：
    //   RADW 是按 R_MAX 定的（62 -> 6 位），但 r_hi = R_IN + bh2 = 16 + 57 = 73，
    //   已经超了 6 位（最大 63）—— 溢出后 73 变成 9，于是 "9 > 62" 为假，
    //   钳位失效，柱高为 0 的辐条也会被点亮。
    //   这个 bug 单独跑 tb_polar_map 【测不到】：那个 TB 用默认 R_MAX=96/R_IN=20，
    //   RADW=7 位刚好装得下 20+76=96 —— 只有 disp_mix 用 R_MAX=62 实例化时才暴露。
    //   这也正是 tb_disp_top 这类【集成测试】存在的意义。
    wire [RADW:0] r_hi  = RIN_L + bh2;
    wire [RADW:0] r_lim = (r_hi > {1'b0, RMAX_L}) ? {1'b0, RMAX_L} : r_hi;
    wire [2*RADW+1:0] rlim2 = r_lim * r_lim;           // 钳位后 <= R_MAX，位宽仍留余量

    // 零扩展到 d2 的宽度后再比
    wire [2*CW:0] rlim2_e = rlim2;

    assign in_disc = (d2 < rmax2_e);
    assign lit     = (d2 >= rmin2_e) && (d2 < rlim2_e);

endmodule
