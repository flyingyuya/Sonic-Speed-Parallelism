//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    lcd_timing
// Module Name:    lcd_timing
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    lcd_timing.v - 480x272 液晶屏时序发生器
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
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
