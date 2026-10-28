//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    ui_layer
// Module Name:    ui_layer
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    ui_layer.v - 按钮层（UI 三件套之「图层表驱动」）
// Dependencies:   disp_cfg.vh
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


// 布局常数（把手位置等）
`include "disp_cfg.vh"

module ui_layer #(
    parameter integer NB          = 7,        // 按钮个数
    parameter integer XW    = 10,       // 坐标位宽（与时序发生器一致）
    parameter integer YW    = 9,

    //--------------------- 按钮带的位置 ---------------------
    parameter integer BX0   = 0,        // 按钮带左上角（x 固定）
    parameter integer BY0   = 234,      // 按钮带【展开后】的 y（运行时由 ui_by0 覆盖）
    parameter integer BW    = 78,       // 每个按钮宽
    parameter integer BH    = 38,       // 高
    parameter integer GAP   = 0,        // 按钮之间的空隙

    //--------------------- 配色 ---------------------
    parameter [23:0] C_FACE  = 24'h20_40_60,   // 按钮底面
    parameter [23:0] C_EDGE  = 24'h60_A0_C0,   // 边框
    parameter [23:0] C_PRESS = 24'hC0_E0_FF,   // 被按下时的底面
    parameter [23:0] C_ACT   = 24'h30_60_90,   // 当前生效的那个按钮的底面
    parameter [23:0] C_TXT   = 24'hE0_F0_FF,   // 标签文字（底面之上）
    parameter [23:0] C_TXT_HI= 24'h10_20_30,   // 标签文字（按下/生效时用深色）

    //---- 展缩把手（侧边小三角）----
    parameter integer TX    = `DISP_TAB_X,
    parameter integer TY    = `DISP_TAB_Y,
    parameter integer TW    = `DISP_TAB_W,
    parameter integer TH    = `DISP_TAB_H,
    parameter [23:0] C_TAB  = 24'h38_78_A0     // 把手颜色
) (
    //--------------------- 扫描位置（组合） ---------------------
    input  wire [XW-1:0]  x,
    input  wire [YW-1:0]  y,

    //--------------------- 触摸状态 ---------------------
    //   tx/ty 是【屏幕坐标】，不是原始 ADC 值
    input  wire [XW-1:0]  tx,
    input  wire [YW-1:0]  ty,
    input  wire           pressed,      // 手指正按着

    //--------------------- 按钮带的实际 y（运行时） ---------------------
    //   展开/收起动画就是把它从「屏幕外」平滑移到 BY0
    input  wire [YW-1:0]  ui_by0,

    //--------------------- 面板是否展开（决定箭头方向） ---------------------
    input  wire           ui_open,

    //--------------------- 当前生效的按钮（用来画高亮） ---------------------
    input  wire [3:0]     active,       // 与某个按钮的 act 相同则高亮；其它值无高亮

    //--------------------- 渲染输出 ---------------------
    output reg            draw,         // 该像素属于按钮带（要盖住背景）
    output reg  [23:0]    rgb,

    //--------------------- 交互输出 ---------------------
    output reg  [2:0]     hit_k,        // 被按下的按钮编号（0..NB-1）
    output reg            hit,          // 有按钮被按下
    output wire [3:0]     hit_act,      // 被按下按钮的动作码

    //--------------------- 交互输出：把手 ---------------------
    output reg            tab_hit       // 手指正点在把手上
);

    //=========================================================================
    // 按钮表
    //=========================================================================
    //   编号  动作码(act)  含义（由上层解释）
    //    0      0x0        VIEW   切换视图预设
    //    1      0x1        SPK    喇叭静音开关（原 STYLE 已弃用）
    //    2      0x2        HUESPD 色相速度
    //    3      0x3        WAVEG  波形增益
    //    4      0x4        BGMODE 背景模式
    //    5      0x6        DEMO   演示图案
    //    6      0x7        IN     切换音频输入源（话筒 / 线路）
    //    7      0x8        SD     切换 SD 卡背景图
    reg [3:0] act_tab [0:NB-1];

    integer i;
    initial begin
        for (i = 0; i < NB; i = i + 1) act_tab[i] = i[3:0];
        if (NB > 5) act_tab[5] = 4'h6;      // 第 6 个按钮对应 DEMO 寄存器
        if (NB > 6) act_tab[6] = 4'h7;      // 第 7 个按钮：输入源 IN
        if (NB > 7) act_tab[7] = 4'h8;      // 第 8 个按钮：SD 卡切图
    end

    //=========================================================================
    // 按钮标签
    //=========================================================================
    localparam integer LBL_COL0 = 1;    // 标签从第几个字符格开始
    localparam integer LBL_NCH  = 6;    // 每个按钮放几个字符（7 个按钮，BW=66，6x8=48px 居中）
    localparam integer LBL_ROWOFF = 2;  // 标签从第几个字符行开始（垂直居中）

    reg [7:0] lbl [0:NB*LBL_NCH-1];

    function [8*LBL_NCH-1:0] lbl_of;
        input integer i;
        begin
            case (i)
                0: lbl_of = "VIEW  ";
                1: lbl_of = "SPK   ";
                2: lbl_of = "HUE   ";
                3: lbl_of = "GAIN  ";
                4: lbl_of = "BG    ";
                5: lbl_of = "DEMO  ";
                6: lbl_of = "IN    ";
                7: lbl_of = "SD    ";
                default: lbl_of = "      ";
            endcase
        end
    endfunction

    integer bi, bk;
    reg [8*LBL_NCH-1:0] lbl_tmp;

    initial begin
        for (bi = 0; bi < NB; bi = bi + 1) begin
            lbl_tmp = lbl_of(bi);
            for (bk = 0; bk < LBL_NCH; bk = bk + 1)
                // 字符串最左字符在最高字节，所以倒着取
                lbl[bi*LBL_NCH + bk] = lbl_tmp[8*(LBL_NCH-1-bk) +: 8];
        end
    end

    //=========================================================================
    // 渲染：这个像素属不属于按钮带，属于的话是什么颜色
    //=========================================================================
    reg in_band;
    reg [2:0] bx;               // 像素落在第几个按钮里

    always @(*) begin
        in_band = 1'b0;
        bx      = 3'd0;

        if (y >= ui_by0 && y < (ui_by0 + BH) &&
            ((x - BX0[XW-1:0]) < (NB*(BW+GAP) - GAP)))
            in_band = 1'b1;

        // 再算落在第几个按钮里
        for (i = 0; i < NB; i = i + 1) begin
            if (x >= (BX0 + i*(BW+GAP)) && x < (BX0 + i*(BW+GAP) + BW))
                bx = i[2:0];
        end
    end

    // 边框：离按钮边缘 2 像素以内算边
    wire [XW-1:0] bx0 = BX0 + bx*(BW+GAP);
    wire [XW-1:0] off = x - bx0[XW-1:0];
    wire [YW-1:0] oy  = y - ui_by0;

    // 这个像素对应哪个字符格的哪一行
    wire [XW-1:0] lx = (x - bx0[XW-1:0]) >> 3;   // 字符列（含 LBL_COL0 偏移）
    wire [YW-1:0] ly = (oy - (LBL_ROWOFF*8)) >> 3;   // 字符行

    // 行范围必须【正好】是 7 行（oy 在 [ROWOFF*8, ROWOFF*8+7]）
    wire        l_in  = in_band && (lx >= LBL_COL0[XW-1:0]) &&
                        (lx < (LBL_COL0 + LBL_NCH)) &&
                        (oy >= (LBL_ROWOFF*8)) && (oy < (LBL_ROWOFF*8 + 7));
    wire [2:0]  l_col = lx[2:0] - LBL_COL0[2:0];      // 0..7
    wire [7:0]  l_ch  = lbl[bx*LBL_NCH + l_col];

    // 查字库用的行号是【格内第几行】= oy[2:0]，不是 ly[2:0]
    wire [XW-1:0] l_off = x - bx0[XW-1:0];      // 相对按钮左边的像素偏移
    wire [2:0]    l_pxu = l_off[2:0];           // 格内像素列
    wire [YW-1:0] l_oy  = oy - (LBL_ROWOFF*8);  // 相对标签顶部的像素行
    wire [2:0]    l_oyu = l_oy[2:0];            // 格内像素行
    wire [7:0]  l_bits;
    font_rom #(.GW(5)) u_lbl_font (
        .ch  (l_ch),
        .row (l_oyu),                        // 格内像素行（相对标签顶部）
        .bits(l_bits)
    );

    // 字形取位：bit4 = 最左。格内列 = x[2:0]
    wire [7:0] l_shift = l_bits >> (4 - l_pxu);
    wire       l_pix   = l_in && (l_pxu < 5) && l_shift[0];

    wire is_edge = in_band &&
                   ((off < 2) || (off >= (BW-2)) ||
                    (oy  < 2) || (oy  >= (BH-2)));

    // 这个按钮当前是不是"生效中"（active 与它的动作码相同）
    wire is_active = (act_tab[bx] == active[3:0]);

    // 这个按钮当前是不是"被手指按着"
    wire is_pressed = pressed && hit && (hit_k == bx);

    //=========================================================================
    // 展缩把手（侧边小三角）
    //=========================================================================
    wire [XW-1:0] tx_off = x - TX[XW-1:0];
    wire [YW-1:0] ty_off = y - TY[YW-1:0];

    wire in_tab = (x >= TX[XW-1:0]) && (x < (TX + TW)) &&
                  (y >= TY[YW-1:0]) && (y < (TY + TH));

    // 三角形：把 (tx_off, ty_off) 映射到 5x7 的三角区域
    wire [XW-1:0] tri_x = tx_off - ((TW - 5) / 2);      // 水平居中
    wire [YW-1:0] tri_y = ty_off - ((TH - 7) / 2);      // 垂直居中
    wire [2:0]    tri_r = tri_y[2:0];
    wire [3:0]    tri_w = 4'd5 - ((tri_r > 3'd3) ? (tri_r - 3'd3) : (3'd3 - tri_r));
    // ▶：像素靠左（0 .. w-1）；◀：像素靠右（5-w .. 4）
    wire [3:0]    tri_lo = ui_open ? (4'd5 - tri_w) : 4'd0;
    wire [3:0]    tri_hi = ui_open ? 4'd4 : (tri_w - 1'b1);

    wire tri_pix = in_tab && (tri_y < 7) &&
                   (tri_x >= tri_lo) && (tri_x <= tri_hi) &&
                   (tri_r < 7);

    always @(*) begin
        if (tri_pix) begin
            draw = 1'b1;
            rgb  = C_TAB;
        end else if (in_tab) begin
            // 把手底板：压暗的背景，让三角看得清
            draw = 1'b1;
            rgb  = 24'h10_18_20;
        end else if (!in_band) begin
            draw = 1'b0;
            rgb  = 24'h000000;
        end else begin
            draw = 1'b1;
            if (is_edge)
                rgb = C_EDGE;
            else if (is_pressed)
                rgb = l_pix ? C_TXT_HI : C_PRESS;   // 按下时用深色字，对比强
            else if (is_active)
                rgb = l_pix ? C_TXT_HI : C_ACT;
            else
                rgb = l_pix ? C_TXT    : C_FACE;
        end
    end

    //=========================================================================
    // 交互：触摸点落在哪个按钮上
    //=========================================================================
    function in_rect;
        input [XW-1:0] px;
        input [YW-1:0] py;
        input integer  k;
        reg   [XW-1:0] x0;
        begin
            x0 = BX0 + k*(BW+GAP);
            // 同样用"先减再比"，避开"px >= 常数 0 恒真"的无符号警告
            in_rect = ((px - x0) < BW) &&
                      (py >= ui_by0) && (py < (ui_by0 + BH));
        end
    endfunction

    reg [2:0] tk;
    reg       tv;

    always @(*) begin
        tk = 3'd0;
        tv = 1'b0;
        for (i = 0; i < NB; i = i + 1) begin
            if (in_rect(tx, ty, i)) begin
                tk = i[2:0];
                tv = 1'b1;
            end
        end
    end

    always @(*) begin
        hit   = pressed && tv;
        hit_k = tk;
    end

    // 把手命中：和渲染共用同一套几何（TX/TY/TW/TH）
    always @(*) begin
        tab_hit = pressed &&
                  (tx >= TX[XW-1:0]) && (tx < (TX + TW)) &&
                  (ty >= TY[YW-1:0]) && (ty < (TY + TH));
    end

    // hit_act 的语义是【正在被按下的按钮】，不是"光标停在哪个按钮上"
    assign hit_act = hit ? act_tab[tk] : 4'hF;

endmodule
