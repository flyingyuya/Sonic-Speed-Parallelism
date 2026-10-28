//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    polar_map
// Module Name:    polar_map
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    polar_map.v - 极坐标（径向）频谱的坐标变换（纯组合）
// Dependencies:
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

    //---------------------- 位宽 ------------------------
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

    // 存在度（来自 ui_anim，0..128）。圆盘【整体】按它缩放：
    //   128 = 满尺寸，0 = 完全不显示
    input  wire [7:0]           pres
);

    localparam integer AW = $clog2(NBARS);

    // 常量做成长度匹配的字面值，避免各处写死位宽
    localparam signed [CW-1:0] CX_L = CX;
    localparam signed [CW-1:0] CY_L = CY;

    // 按 pres/128 缩放后的实际半径（128 -> 原值，0 -> 0）
    localparam [RADW-1:0] RIN_C  = R_IN;
    localparam [RADW-1:0] RMAX_C = R_MAX;

    wire [RADW+7:0] rin_s  = RIN_C  * pres;          // <= 62*128 = 7936
    wire [RADW+7:0] rmax_s = RMAX_C * pres;
    wire [RADW-1:0] RIN_L  = rin_s [RADW+6 : 7];     // /128
    wire [RADW-1:0] RMAX_L = rmax_s[RADW+6 : 7];

    //=========================================================================
    // 相对圆心的有符号偏移
    //=========================================================================
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
    // 半径的平方（精确，避开开方）
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
    // r_out 仅供调试观测（有 ~9% 误差，别当真值用）
    wire [CW+2:0]     sml7  = (sml << 3) - sml;           // sml * 7
    wire [CW+1:0]     rad   = big + (sml7 >> 4);
    localparam [CW+1:0] ROUT_MAX = {RW{1'b1}};
    assign r_out = (rad > ROUT_MAX) ? {RW{1'b1}} : rad[RW-1:0];

    //=========================================================================
    // 八分圆编号（0..7，逆时针从 +x 轴起）
    //    dy＞0 当成"向上"（屏幕上就是向下，只影响镜像，不影响观感）
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
    // 八分圆内再分 8 段 -> 共 64 个扇区
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

    wire [2:0] fsub = {2'b00, (t64 > e0)} + {2'b00, (t64 > e1)}
                    + {2'b00, (t64 > e2)} + {2'b00, (t64 > e3)}
                    + {2'b00, (t64 > e4)} + {2'b00, (t64 > e5)}
                    + {2'b00, (t64 > e6)};

    // 奇数八分圆里 t 随角度【减小】，所以段号要反过来
    wire [2:0] sub = oct[0] ? (~fsub) : fsub;

    // 64 个扇区
    wire [5:0]     sector = {oct, sub};

    //=========================================================================
    // 64 扇区 -> NBARS 根柱：bar = sector * NBARS / 64
    // =========================================================================
    wire [6+AW-1:0] sN   = sector * NBARS[AW-1:0];   // <= 63*60 = 3780
    wire [AW-1:0]   bar  = sN[6+AW-1:6];             // / 64
    wire [AW-1:0]   bar_safe = (bar >= NBARS[AW-1:0]) ? (NBARS-1) : bar;

    assign bar_idx = bar_safe;

    //=========================================================================
    // 点亮判定：R_IN^2 <= dx^2+dy^2 < (R_IN + 柱高像素)^2
    //=========================================================================
    wire [HW-1:0] bh  = bars[bar_safe*HW +: HW];   // 0..511

    // 柱高(0..511) 映射到半径增量
    //   29/256 = 32/256 - 2/256 - 1/256 -> (bh<<5) - (bh<<1) - bh，再右移 8
    wire [HW+4:0] bhm   = (bh << 5) - (bh << 1) - bh;  // bh * 29
    wire [RADW-1:0] bh2 = bhm[HW+4:8];                 // /256 -> 0..57

    wire [RADW:0] r_hi  = RIN_L + bh2;
    wire [RADW:0] r_lim = (r_hi > {1'b0, RMAX_L}) ? {1'b0, RMAX_L} : r_hi;
    wire [2*RADW+1:0] rlim2 = r_lim * r_lim;           // 钳位后 <= R_MAX，位宽仍留余量

    // 零扩展到 d2 的宽度后再比
    wire [2*CW:0] rlim2_e = rlim2;

    assign in_disc = (d2 < rmax2_e);
    assign lit     = (d2 >= rmin2_e) && (d2 < rlim2_e);

endmodule
