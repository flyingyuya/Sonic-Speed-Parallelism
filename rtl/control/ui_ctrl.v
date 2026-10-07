//=============================================================================
// ui_ctrl.v - 统一配置寄存器组（扩展点 ②）
//-----------------------------------------------------------------------------
// 设计意图：**按键、触摸、UART 三个输入源最终都写同一组寄存器，显示链只读它。**
//
//   按键 ─┐
//   触摸 ─┼─▶ [统一写端口] ─▶ 寄存器组 ─▶ 显示链
//   UART ─┘
//
// 这样做的好处：
//   · 显示链完全不知道"是谁改的"，加一个新输入源不用动显示逻辑
//   · 上电默认值、边界钳位只在一个地方处理
//   · 用 UART 就能把全部功能测一遍，不必等按键焊好
//
// 【寄存器映射】
//   0x0 VIEW     [2:0] 视图使能   bit0=柱状 bit1=极坐标 bit2=波形
//   0x1 STYLE    [3:0] 柱体风格   0=实心 1=半透明
//   0x2 HUESPD   [7:0] 色相滚动速度
//                        H=0 停住，1..7 有效【越大越快】，>7 当 7
//                        实际周期 = 2^(8-H) 帧 -> H=6（默认）每 4 帧滚一级
//   0x3 WAVEG    [3:0] 波形增益
//                        G=8 是 1.0 倍（默认），1..15 有效，0 当 8
//                        实现是带饱和的 wave*G/8，见 disp_top.v
//   0x4 BGMODE   [3:0] 背景模式
//   0x5 AUTO     [0]   自动循环视图
//   0x6 DEMO     [1:0] 演示/自检图案（见 rtl/video/demo_src.v）
//                        0=关（用真实音频） 1=斜坡 2=棋盘 3=移动包络
//
// 【视图预设】
//   next_view 脉冲会在下面 PRESET 表里轮转，把常见组合串起来，
//   按键只按一个就能看完所有效果。
//=============================================================================
`timescale 1ns/1ps

`include "disp_cfg.vh"

module ui_ctrl #(
    parameter integer NREG        = 8,
    parameter integer AUTO_PERIOD = 48_000_000 * 4      // 自动切换间隔（4 秒）
) (
    input  wire        clk,
    input  wire        rst_n,

    //--------------------- 统一写端口 ---------------------
    input  wire        wr_en,
    input  wire [3:0]  wr_addr,
    input  wire [7:0]  wr_data,

    //--------------------- 便捷操作 ---------------------
    input  wire        next_view,       // 1 拍脉冲：切到下一个视图预设 (VIEW 按钮)

    //-------------------------------------------------------------------------
    // 步进（P1-1 工控屏的旋钮式调节）
    //-----------------------------------------------------------------------------
    //   按钮/UART 想"把某个寄存器 +1"时用这个。放在这里而不是放上层，是因为
    //   "当前值是多少"只有本模块知道 —— 上层如果自己读出来再写回去，
    //   就得把 6 个寄存器的输出全接上去，还要处理回写冲突。
    //   这里只给一个地址，本模块自己查表递增，代价是一个 case。
    //
    //   每个字段的有效范围不同（比如色相速度是 0..7、背景只有 0..1），
    //   所以"回绕点"按字段分别定，不能统一用 8 位回绕。
    //   为 0 的字段：该字段不可步进（避免出现非法值）。
    //-------------------------------------------------------------------------
    input  wire        step_en,         // 1 拍脉冲：对 step_addr 指向的字段 +1
    input  wire [3:0]  step_addr,

    //--------------------- 配置输出 ---------------------
    output reg  [7:0]  cfg_view,
    output reg  [7:0]  cfg_style,
    output reg  [7:0]  cfg_hue_spd,
    output reg  [7:0]  cfg_wave_gain,
    output reg  [7:0]  cfg_bg_mode,
    output reg  [7:0]  cfg_auto,
    output reg  [7:0]  cfg_demo,        // 演示/自检图案选择
    output reg  [3:0]  view_idx         // 当前预设编号（观测用）
);

    localparam integer NPRESET = 6;

    //=========================================================================
    // 视图预设表
    //=========================================================================
    reg [7:0] preset [0:NPRESET-1];

    initial begin
        preset[0] = 8'b0000_0101;       // 柱状 + 波形
        preset[1] = 8'b0000_0110;       // 极坐标 + 波形
        preset[2] = 8'b0000_0111;       // 三个全开
        preset[3] = 8'b0000_0001;       // 只柱状
        preset[4] = 8'b0000_0010;       // 只极坐标
        preset[5] = 8'b0000_0100;       // 只波形
    end

    wire [3:0] nxt_idx = (view_idx == NPRESET - 1) ? 4'd0 : view_idx + 1'b1;

    //=========================================================================
    // 自动循环计时
    //=========================================================================
    reg [31:0] auto_cnt;
    wire       auto_tick = cfg_auto[0] && (auto_cnt == AUTO_PERIOD[31:0] - 1);

    always @(posedge clk) begin
        if (!rst_n)
            auto_cnt <= 32'd0;
        else if (!cfg_auto[0])
            auto_cnt <= 32'd0;
        else if (auto_cnt == AUTO_PERIOD[31:0] - 1)
            auto_cnt <= 32'd0;
        else
            auto_cnt <= auto_cnt + 1'b1;
    end

    //=========================================================================
    // 寄存器组：三个写源共用一个写端口
    //   优先级：显式写（UART/触摸） > 切视图（按键/自动）
    //=========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            cfg_view      <= 8'b0000_0111;      // 上电三个视图全开
            cfg_style     <= 8'd0;
            cfg_hue_spd   <= 8'd6;              // 每 2^(8-6) = 4 帧滚一级
                                                // （等价于旧映射的 H=2，见 disp_top.v）
            cfg_wave_gain <= 8'd8;              // 8 = 1.0 倍（G 原来是死控件，
                                                // 所以改成 8 不会改变画面）
            cfg_bg_mode   <= 8'd0;
            cfg_auto      <= 8'd0;
            cfg_demo      <= 8'd0;              // 上电关（走真实音频）
            view_idx      <= 4'd2;              // 对应 preset[2]（全开）
        end else if (wr_en) begin
            case (wr_addr)
                4'h0: cfg_view      <= wr_data;
                4'h1: cfg_style     <= wr_data;
                4'h2: cfg_hue_spd   <= wr_data;
                4'h3: cfg_wave_gain <= wr_data;
                4'h4: cfg_bg_mode   <= wr_data;
                4'h5: cfg_auto      <= wr_data;
                4'h6: cfg_demo      <= wr_data;
                default: ;                      // 未定义的地址忽略
            endcase
            // 直接写 VIEW 时让预设编号跟着对齐（否则下一次按键会跳）
            if (wr_addr == 4'h0) begin
                if      (wr_data[2:0] == 3'b101) view_idx <= 4'd0;
                else if (wr_data[2:0] == 3'b110) view_idx <= 4'd1;
                else if (wr_data[2:0] == 3'b111) view_idx <= 4'd2;
                else if (wr_data[2:0] == 3'b001) view_idx <= 4'd3;
                else if (wr_data[2:0] == 3'b010) view_idx <= 4'd4;
                else if (wr_data[2:0] == 3'b100) view_idx <= 4'd5;
            end
        end else if (step_en) begin
            // 旋钮式步进：按字段各自的有效范围递增
            case (step_addr)
                // VIEW 用预设轮转（和 KEY1 同一个动作），不走这里

                // STYLE 0..1（实心 / 半透明）
                4'h1: cfg_style     <= (cfg_style[3:0] >= 4'd1) ? 8'd0
                                                                 : cfg_style + 1'b1;
                // HUESPD 0..7，0 = 停住
                4'h2: cfg_hue_spd   <= (cfg_hue_spd[3:0] >= 4'd7) ? 8'd0
                                                                 : cfg_hue_spd + 1'b1;
                // WAVEG 1..15（0 会被当成 8，干脆跳过，免得看着像没反应）
                4'h3: cfg_wave_gain <= (cfg_wave_gain[3:0] >= 4'd15) ? 8'd1
                                                                     : cfg_wave_gain + 1'b1;
                // BGMODE 0..1
                4'h4: cfg_bg_mode   <= (cfg_bg_mode[3:0] >= 4'd1) ? 8'd0
                                                                  : cfg_bg_mode + 1'b1;
                // DEMO 0..3
                4'h6: cfg_demo      <= (cfg_demo[1:0] >= 2'd3) ? 8'd0
                                                               : cfg_demo + 1'b1;
                default: ;          // 其它地址不步进
            endcase
        end else if (next_view || auto_tick) begin
            cfg_view <= preset[nxt_idx];
            view_idx <= nxt_idx;
        end
    end

endmodule
