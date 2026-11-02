//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    key_ui
// Module Name:    key_ui
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    key_ui.v - 按键子系统的完整封装：消抖 + 手势 → 光标 → 动作码
// Dependencies:   key_debounce.v  key_gesture.v  cdc_sync.v
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module key_ui #(
    parameter integer CLK_HZ    = 48_000_000,   // clk 频率
    parameter integer KEY_DB_MS = 20,           // 消抖时长（ms）
    parameter integer KEY_WIN_MS= 300           // 双击判定窗（ms）
) (
    input  wire        clk,                     // clk_sys
    input  wire        rst_n,

    //----------------------- 板载按键（低有效）-----------------------
    input  wire        key1_n,
    input  wire        key2_n,

    //----------------------- 面板状态（来自 clk_pix 域）-----------------------
    //   面板收起时，单击左右移动无效（避免误触）
    input  wire        panel_open,

    //----------------------- 输出：光标与动作码（给 ui_ctrl）-----------------------
    output reg  [2:0]  sel_idx,                 // 光标位置 0..7
    output wire [3:0]  sel_act,                 // 光标对应的按钮动作码

    //----------------------- 输出：事件（给上层的跨域与逻辑）-----------------------
    output reg         panel_tog,               // 面板开/关请求（电平翻转）
    output reg         key_act_tog,             // 按键活动（电平翻转，给空闲计时）
    output wire        key_view,                // KEY2 双击且光标在 VIEW -> 切视图
    output wire        key_step,                // KEY2 双击且光标不在 VIEW -> 步进
    output wire        sel_is_last              // 光标在最后一项（给 LED / 调试用）
);

    //=========================================================================
    // 光标项数与范围
    //=========================================================================
    //   0=VIEW 1=SPK 2=HUE 3=GAIN 4=BG 5=DEMO 6=IN 7=SD
    localparam [3:0] SEL_N   = 4'd8;
    localparam [2:0] SEL_MAX = SEL_N[2:0] - 3'd1;      // 7

    //=========================================================================
    // 消抖：两路按键各自过一遍
    //=========================================================================
    wire k1_press, k2_press;
    wire k1_state, k2_state;

    key_debounce #(.CLK_HZ(CLK_HZ), .MS(KEY_DB_MS)) u_key1 (
        .clk(clk), .rst_n(rst_n), .key_n(key1_n),
        .key_pressed(k1_state), .press(k1_press)
    );

    key_debounce #(.CLK_HZ(CLK_HZ), .MS(KEY_DB_MS)) u_key2 (
        .clk(clk), .rst_n(rst_n), .key_n(key2_n),
        .key_pressed(k2_state), .press(k2_press)
    );

    //=========================================================================
    // 手势：单击 / 双击
    //=========================================================================
    //   KEY1 单击 = 光标左移   KEY1 双击 = 面板 开/关
    //   KEY2 单击 = 光标右移   KEY2 双击 = 确认（执行光标所在项）
    wire k1_single, k1_dbl, k2_single, k2_dbl;

    key_gesture #(.CLK_HZ(CLK_HZ), .WIN_MS(KEY_WIN_MS)) u_gest1 (
        .clk(clk), .rst_n(rst_n), .press(k1_press),
        .single(k1_single), .dbl(k1_dbl)
    );

    key_gesture #(.CLK_HZ(CLK_HZ), .WIN_MS(KEY_WIN_MS)) u_gest2 (
        .clk(clk), .rst_n(rst_n), .press(k2_press),
        .single(k2_single), .dbl(k2_dbl)
    );

    //=========================================================================
    // 光标移动：只在面板展开时生效
    //=========================================================================
    wire keys_en = panel_open;

    always @(posedge clk) begin
        if (!rst_n) begin
            sel_idx <= 3'd0;
        end else if (keys_en && k1_single) begin
            sel_idx <= (sel_idx == 3'd0) ? SEL_MAX : sel_idx - 3'd1;   // 左移，回绕
        end else if (keys_en && k2_single) begin
            sel_idx <= (sel_idx == SEL_MAX) ? 3'd0 : sel_idx + 3'd1;   // 右移，回绕
        end
    end

    assign sel_is_last = (sel_idx == SEL_MAX);

    //=========================================================================
    // 光标 -> 按钮动作码
    //=========================================================================
    //   光标 0..4 ⟹ 动作码 0..4（VIEW / SPK / HUE / GAIN / BG，数字连续）
    //   光标 5    ⟹ 4'h6（DEMO）
    //   光标 6    ⟹ 4'h7（IN）
    //   光标 7    ⟹ 4'h8（SD）
    assign sel_act = (sel_idx == 3'd7) ? 4'h8 :
                     (sel_idx == 3'd6) ? 4'h7 :
                     (sel_idx == 3'd5) ? 4'h6 : {1'b0, sel_idx};

    //=========================================================================
    // 面板开/关：KEY1 双击翻转一个电平（上层再跨域到 clk_pix）
    //=========================================================================
    always @(posedge clk) begin
        if (!rst_n) panel_tog <= 1'b0;
        else if (k1_dbl) panel_tog <= ~panel_tog;
    end

    //=========================================================================
    // 按键活动标志：任何手势都算"用户操作"（给面板空闲收起计时用）
    //=========================================================================
    wire key_act = k1_single | k1_dbl | k2_single | k2_dbl;

    always @(posedge clk) begin
        if (!rst_n) key_act_tog <= 1'b0;
        else if (key_act) key_act_tog <= ~key_act_tog;
    end

    //=========================================================================
    // 确认（KEY2 双击）：光标在 VIEW 时切视图，否则步进当前项
    //=========================================================================
    assign key_view = k2_dbl & keys_en & (sel_idx == 3'd0);
    assign key_step = k2_dbl & keys_en & (sel_idx != 3'd0);

endmodule
