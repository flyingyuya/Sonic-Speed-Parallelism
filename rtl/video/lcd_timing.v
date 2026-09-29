//=============================================================================
// lcd_timing.v - 480x272 液晶屏时序发生器
//-----------------------------------------------------------------------------
// 屏幕特性（璞致 4.3 寸，PCBA 子卡 0 欧姆把 LCD_DE 直接拉高，所以没有 DE 脚）：
//   · 分辨率 480 x 272
//   · RGB888（24 位，不是 RGB565）
//   · HSYNC / VSYNC 都是【低有效】（同步脉冲期间为低）
//   · 没有 DE 输出脚 —— 面板控制器靠 HS/VS + 固定时序自己推算有效区
//   · 像素时钟 12.5 MHz  ->  帧率 = 12.5e6 / (525 x 286) = 83.25 Hz
//
// 时序参数（与璞致官方例程 3_16_PZ_LCD 逐字一致，已实测可用）：
//
//         |<------------------------- H_TOTAL = 525 ------------------------->|
//         |<->|<->|<-------------- H_DISP = 480 -------------->|<->|
//   HSYNC ─┐   :   :                                          :   :
//           └───┘   :                                          :   :
//        H_SYNC=41  :                                          :   :
//              H_BACK=2                                        :   :
//                                                         H_FRONT=2
//
//   光栅同理：V_TOTAL=286, V_SYNC=10, V_BACK=2, V_DISP=272, V_FRONT=2
//
// 【输出为什么要打一拍】
//   调用方要拿到 x/y 之后才能算出这一像素的颜色，所以 x/y 必须是【当拍】可用
//   （组合输出）。而 LCD 的 hsync/vsync/de/rgb 必须是互相严格对齐的一组信号，
//   于是把它们一起寄存在输出级。整帧因此整体平移一个像素时钟，
//   相对关系完全不变（同步脉冲也跟着平移）。
//
//   调用方的用法：
//       lcd_timing u_timing(
//           .rgb_in (my_color_from_xy),      // 用当拍的 x/y 组合算出
//           .rgb_out(lcd_rgb), .hsync(...), .vsync(...), .de(...),
//           .x(x), .y(y), .sof(sof));
//=============================================================================
`timescale 1ns/1ps

module lcd_timing #(
    parameter integer H_SYNC  = 41,
    parameter integer H_BACK  = 2,
    parameter integer H_DISP  = 480,
    parameter integer H_FRONT = 2,
    parameter integer V_SYNC  = 10,
    parameter integer V_BACK  = 2,
    parameter integer V_DISP  = 272,
    parameter integer V_FRONT = 2,
    // 计数器位宽。必须写在参数表里（而不是模块体内的 localparam）：
    // 端口声明的位宽要在解析模块头时就确定，而 localparam 在它后面。
    // Verilog-2001 允许后面的 parameter 引用前面的 parameter，所以可以这样算。
    parameter integer HW = $clog2(H_SYNC + H_BACK + H_DISP + H_FRONT),
    parameter integer VW = $clog2(V_SYNC + V_BACK + V_DISP + V_FRONT)
) (
    input  wire                     clk,        // 像素时钟 12.5 MHz
    input  wire                     rst_n,

    input  wire [23:0]              rgb_in,     // 由调用方按当拍 x/y 算出的颜色

    output reg  [23:0]              rgb_out,
    output reg                      hsync,      // 低有效
    output reg                      vsync,      // 低有效
    output reg                      de,         // 有效像素区（本工程不引出到管脚）

    output wire [HW-1:0]            x,          // 当前像素横坐标 0..H_DISP-1
    output wire [VW-1:0]            y,          // 当前像素纵坐标 0..V_DISP-1
    output reg                      sof         // 帧起始，1 拍脉冲
);

    //-------------------------------------------------------------------------
    // 派生常量
    //-------------------------------------------------------------------------
    localparam integer H_TOTAL  = H_SYNC + H_BACK + H_DISP + H_FRONT;
    localparam integer V_TOTAL  = V_SYNC + V_BACK + V_DISP + V_FRONT;
    localparam integer H_ACT_0  = H_SYNC + H_BACK;              // 有效区起点
    localparam integer H_ACT_1  = H_SYNC + H_BACK + H_DISP;     // 有效区终点(不含)
    localparam integer V_ACT_0  = V_SYNC + V_BACK;
    localparam integer V_ACT_1  = V_SYNC + V_BACK + V_DISP;

    reg [HW-1:0] hcnt;
    reg [VW-1:0] vcnt;

    //-------------------------------------------------------------------------
    // 行 / 场计数器
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            hcnt <= {HW{1'b0}};
            vcnt <= {VW{1'b0}};
        end else if (hcnt == H_TOTAL - 1) begin
            hcnt <= {HW{1'b0}};
            if (vcnt == V_TOTAL - 1)
                vcnt <= {VW{1'b0}};
            else
                vcnt <= vcnt + 1'b1;
        end else begin
            hcnt <= hcnt + 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // 当拍坐标（组合）—— 调用方用它算 rgb_in
    //-------------------------------------------------------------------------
    wire in_h = (hcnt >= H_ACT_0) && (hcnt < H_ACT_1);
    wire in_v = (vcnt >= V_ACT_0) && (vcnt < V_ACT_1);
    wire in_active = in_h && in_v;

    assign x = in_h ? (hcnt - H_ACT_0) : {HW{1'b0}};
    assign y = in_v ? (vcnt - V_ACT_0) : {VW{1'b0}};

    //-------------------------------------------------------------------------
    // 输出级：hsync / vsync / de / rgb 一起寄存，保证严格对齐
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (!rst_n) begin
            hsync   <= 1'b1;
            vsync   <= 1'b1;
            de      <= 1'b0;
            rgb_out <= 24'd0;
            sof     <= 1'b0;
        end else begin
            hsync   <= (hcnt >= H_SYNC);     // 低有效：同步脉冲期间为 0
            vsync   <= (vcnt >= V_SYNC);
            de      <= in_active;
            rgb_out <= in_active ? rgb_in : 24'd0;
            // 帧起始：新的一帧第一个行同步开始那一刻
            sof     <= (hcnt == H_SYNC) && (vcnt == V_SYNC);
        end
    end

endmodule
