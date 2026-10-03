//=============================================================================
// bg_src.v - 背景像素源（扩展点 ①）
//-----------------------------------------------------------------------------
// 接口刻意做成【纯组合】：(x, y, mode) -> rgb
//
// 这样显示混合逻辑只要"扫描到哪算到哪"，不需要渲染状态机、不需要行缓存。
// 将来换成 SD 卡 / QSPI Flash 的背景图时，具体实现要换成流式取像素
// （需要行缓冲，见 docs/12 §5.3），但调用方看到的接口形状不变 ——
// 这就是为什么现在把它单独拆成一个模块。
//
// 背景模式（mode）约定：
//   0 = 深色底 + 网格        <- 当前实现
//   1 = 纯竖直渐变
//   其他 = 预留给背景图
//=============================================================================
`timescale 1ns/1ps

module bg_src #(
    parameter integer HDISP = 480,
    parameter integer VDISP = 272,
    parameter integer GRID  = 32,        // 网格间距（像素）
    // 坐标位宽（P1-3a）：默认 10/9 对应 480x272，与原写死的 [9:0]/[8:0] 一致
    parameter integer XW    = 10,
    parameter integer YW    = 9
) (
    input  wire [XW-1:0] x,
    input  wire [YW-1:0] y,
    input  wire [3:0]   mode,
    output reg  [23:0]  rgb              // {R[7:0], G[7:0], B[7:0]}
);

    localparam integer GW = $clog2(GRID);

    // 网格线：每 GRID 像素一条
    wire grid_x = (x[GW-1:0] == {GW{1'b0}});
    wire grid_y = (y[GW-1:0] == {GW{1'b0}});
    wire grid   = grid_x | grid_y;

    // 竖直渐变：顶部更暗，底部略亮（这样频谱柱从底部升起来更自然）
    //   y[8:3] 是 0..33，直接当作亮度增量
    wire [5:0] t  = y[8:3];
    wire [7:0] gr = 8'd6  + {2'b00, t};
    wire [7:0] gg = 8'd7  + {2'b00, t};
    wire [7:0] gb = 8'd22 + {2'b00, t};

    // 网格线在这个基础上再加一点亮度
    wire [7:0] add = grid ? 8'd16 : 8'd0;

    always @(*) begin
        if (mode == 4'd1) begin
            // 模式 1：不要网格，只有渐变
            rgb = {gr, gg, gb};
        end else begin
            // 模式 0（以及其他未定义值）：渐变 + 网格
            rgb = {gr + add, gg + add, gb + add};
        end
    end

endmodule
