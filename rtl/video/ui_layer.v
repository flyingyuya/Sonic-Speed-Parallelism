//=============================================================================
// ui_layer.v - 按钮层（UI 三件套之「图层表驱动」）
//-----------------------------------------------------------------------------
// 【在"扫描到哪算到哪"的架构里怎么做按钮】
//   本工程没有 framebuffer，每个像素是组合算出来的。按钮也一样：
//     (x,y) -> 落不落在某个按钮框里 -> 在的话画按钮色；被按下的那个换个颜色
//     (tx,ty) + pressed -> 落在哪个按钮里 -> 输出那个按钮的编号
//   全程组合，不引入流水线，不会让画面错位。
//
// 【为什么用"表"而不是一堆 if】
//   按钮的位置/尺寸/归属字段都放在 GLUT（一个常量数组）里。
//   加按钮、挪位置、改大小，只动表，不动判断逻辑。
//   综合时 for 循环会展开，每个按钮一套比较器，成本约 15 LUT/个。
//
// 【两个输出要分清楚】
//   draw/rgb : 【渲染】—— 这个像素属不属于按钮，是什么颜色
//   hit/hit_k: 【交互】—— 触摸点落在哪个按钮上（与渲染完全独立）
//   二者共用同一张表，所以"看到的"和"点到的"永远一致 ——
//   这一点很重要：如果分开写，很容易出现"框画在这里、热区在那里"的经典 bug。
//
// 【按钮怎么表达"我要改什么"】
//   每个按钮带一个 4 位的「动作码」act：
//     0..5  = 直接写 ui_ctrl 的某个寄存器地址（和 UART 命令同一个写法）
//     6..15  = 保留给"切换类"动作（代码里再解释）
//   这样上层的接线（uic_wr_addr = act）非常短，也不需要为每个按钮单独开线。
//=============================================================================
`timescale 1ns/1ps

module ui_layer #(
    parameter integer NB    = 6,        // 按钮个数
    parameter integer XW    = 10,       // 坐标位宽（与时序发生器一致）
    parameter integer YW    = 9,

    //--------------------- 按钮带的位置 ---------------------
    parameter integer BX0   = 0,        // 左上角
    parameter integer BY0   = 234,
    parameter integer BW    = 78,       // 每个按钮宽
    parameter integer BH    = 38,       // 高
    parameter integer GAP   = 0,        // 按钮之间的空隙

    //--------------------- 配色 ---------------------
    parameter [23:0] C_FACE  = 24'h20_40_60,   // 按钮底面
    parameter [23:0] C_EDGE  = 24'h60_A0_C0,   // 边框
    parameter [23:0] C_PRESS = 24'hC0_E0_FF,   // 被按下时的底面
    parameter [23:0] C_ACT   = 24'h30_60_90    // 当前生效的那个按钮的底面
) (
    //--------------------- 扫描位置（组合） ---------------------
    input  wire [XW-1:0]  x,
    input  wire [YW-1:0]  y,

    //--------------------- 触摸状态 ---------------------
    //   tx/ty 是【屏幕坐标】（已经过校准换算），不是原始 ADC 值
    input  wire [XW-1:0]  tx,
    input  wire [YW-1:0]  ty,
    input  wire           pressed,      // 手指正按着

    //--------------------- 当前生效的按钮（用来画高亮） ---------------------
    input  wire [3:0]     active,       // 与某个按钮的 act 相同则高亮；其它值无高亮

    //--------------------- 渲染输出 ---------------------
    output reg            draw,         // 该像素属于按钮带（要盖住背景）
    output reg  [23:0]    rgb,

    //--------------------- 交互输出 ---------------------
    output reg  [2:0]     hit_k,        // 被按下的按钮编号（0..NB-1）
    output reg            hit,          // 有按钮被按下
    output wire [3:0]     hit_act       // 被按下按钮的动作码
);

    //=========================================================================
    // 按钮表
    //   name 只是给人看的，不参与逻辑；位置在 for 循环里用下标算。
    //   布局：底部一条，从左到右。
    //=========================================================================
    //   编号  动作码(act)  含义（由上层解释）
    //    0      0x0        VIEW   切换视图预设
    //    1      0x1        STYLE  柱体风格
    //    2      0x2        HUESPD 色相速度
    //    3      0x3        WAVEG  波形增益
    //    4      0x4        BGMODE 背景模式
    //    5      0x6        DEMO   演示图案
    reg [3:0] act_tab [0:NB-1];

    integer i;
    initial begin
        for (i = 0; i < NB; i = i + 1) act_tab[i] = i[3:0];
        if (NB > 5) act_tab[5] = 4'h6;      // 第 6 个按钮对应 DEMO 寄存器
    end

    //=========================================================================
    // 1. 渲染：这个像素属不属于按钮带，属于的话是什么颜色
    //=========================================================================
    reg in_band;
    reg [2:0] bx;               // 像素落在第几个按钮里

    always @(*) begin
        in_band = 1'b0;
        bx      = 3'd0;

        // 先判有没有落在整条带子里（省掉大部分比较）
        //   ⚠️ x 和 y 都要判！第一版只判了 y，结果最后一个按钮右边
        //      一直到屏幕右边缘都被当成"在带子里"，画出一条多余的色带。
        //      TB 的 [1] 抓到了（它专门扫了带子右侧）。
        if (y >= BY0[YW-1:0] && y < (BY0 + BH) &&
            x >= BX0[XW-1:0] && x < (BX0 + NB*(BW+GAP) - GAP))
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
    wire [YW-1:0] oy  = y - BY0[YW-1:0];

    wire is_edge = in_band &&
                   ((off < 2) || (off >= (BW-2)) ||
                    (oy  < 2) || (oy  >= (BH-2)));

    // 这个按钮当前是不是"生效中"（active 与它的动作码相同）
    wire is_active = (act_tab[bx] == active[3:0]);

    // 这个按钮当前是不是"被手指按着"
    wire is_pressed = pressed && hit && (hit_k == bx);

    always @(*) begin
        if (!in_band) begin
            draw = 1'b0;
            rgb  = 24'h000000;
        end else begin
            draw = 1'b1;
            if (is_edge)
                rgb = C_EDGE;
            else if (is_pressed)
                rgb = C_PRESS;
            else if (is_active)
                rgb = C_ACT;
            else
                rgb = C_FACE;
        end
    end

    //=========================================================================
    // 2. 交互：触摸点落在哪个按钮上
    //   注意用的是 tx/ty，和渲染用的 x/y 是两回事 ——
    //   但共用同一张表的同一套边界判断（下面的 in_rect 函数）。
    //=========================================================================
    function in_rect;
        input [XW-1:0] px;
        input [YW-1:0] py;
        input integer  k;
        reg   [XW-1:0] x0;
        begin
            x0 = BX0 + k*(BW+GAP);
            in_rect = (px >= x0) && (px < (x0 + BW)) &&
                      (py >= BY0[YW-1:0]) && (py < (BY0 + BH));
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

    // 写成连续赋值而不是放进 always @(*)：
    //   数组下标读取会让 iverilog 抱怨
    //   "@* is sensitive to all 6 words in array 'act_tab'"（功能上没错）。
    assign hit_act = act_tab[tk];

endmodule
