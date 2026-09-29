//=============================================================================
// disp_top.v - 显示链顶层（把时序 / 跨域快照 / 背景 / 混合 串起来）
//-----------------------------------------------------------------------------
// 数据流：
//
//   clk_sys 域                       clk_pix 域（12.5 MHz）
//   ┌──────────────┐                 ┌───────────────────────────────────────┐
//   │ spectrum     │ 270 bit         │ lcd_timing ──(x,y)──┐                 │
//   │  .frame_done ├─▶ spec_sync ──▶ │                     ▼                 │
//   │  .bar_flat   │   (异步 FIFO)   │   bars        ┌──────────────┐        │
//   └──────────────┘                 │               │  disp_mix    ├──▶ rgb │
//                                    │   bg_src ───▶ │              │        │
//                                    │   (背景)      └──────────────┘        │
//                                    │       ▲              ▲                │
//                                    │       │              │                │
//                                    │   ui_mode        hue_off（帧计数）    │
//                                    └───────────────────────────────────────┘
//
// 【色相滚动】每 SCROLL_DIV 帧把 hue_off 加 1，128 帧走完一整圈彩虹。
//   参考工程 Music-Spectrum 是"每扫 5 列加 1"，这里用帧计数更简单，
//   视觉上都是"彩虹沿着横轴缓慢流动"。
//
// 【为什么 sof 才更新 bars】
//   帧中改变柱高会让同一屏里出现"上半屏旧值、下半屏新值"的撕裂。
//   在 sof 统一更新，整帧用同一份数据。
//=============================================================================
`timescale 1ns/1ps

`include "disp_cfg.vh"

module disp_top #(
    // 默认值全部来自 rtl/video/disp_cfg.vh —— 布局的唯一真相源
    parameter integer HDISP      = `DISP_HDISP,
    parameter integer VDISP      = `DISP_VDISP,
    parameter integer NBARS      = `DISP_NBARS,
    parameter integer HW         = 9,
    parameter integer BARS_Y0    = `DISP_BARS_Y0,
    parameter integer BAR_GAP    = `DISP_BAR_GAP,
    parameter integer POL_CX     = `DISP_POL_CX,
    parameter integer POL_CY     = `DISP_POL_CY,
    parameter integer POL_RIN    = `DISP_POL_RIN,
    parameter integer POL_RMAX   = `DISP_POL_RMAX,
    parameter integer WAVE_CY    = `DISP_WAVE_CY,
    parameter integer WAVE_AMP   = `DISP_WAVE_AMP,
    parameter integer WAVE_TH    = `DISP_WAVE_TH,
    parameter integer SCROLL_DIV = 5        // 每多少帧色相滚动一级
) (
    //--------------------- 音频域（clk_sys）---------------------
    input  wire                  clk_sys,
    input  wire                  rst_sys_n,
    input  wire                  spec_wr,       // = spectrum.frame_done
    input  wire [NBARS*HW-1:0]   spec_din,      // = spectrum.bar_flat

    //--------------------- 显示域（clk_pix）---------------------
    input  wire                  clk_pix,
    input  wire                  rst_pix_n,
    input  wire [3:0]            ui_mode,       // 来自 ui_ctrl：背景模式
    input  wire [3:0]            ui_style,      // 来自 ui_ctrl：柱体风格
    input  wire [2:0]            ui_view,       // 来自 ui_ctrl：视图使能
    input  wire [7:0]            ui_hue_spd,    // 来自 ui_ctrl：色相滚动速度

    //--------------------- 波形数据（clk_sys 域）---------------------
    input  wire signed [23:0]    wave_din,      // = audio_top 的 rx_l
    input  wire                  wave_we,       // = audio_top 的 rx_valid

    //--------------------- 液晶输出 ---------------------
    output wire [23:0]           lcd_rgb,
    output wire                  lcd_hs,
    output wire                  lcd_vs,
    output wire                  lcd_clk
);

    //=========================================================================
    // 1. 时序发生器
    //=========================================================================
    wire [9:0]  x;
    wire [8:0]  y;
    wire        de;
    wire        sof;
    wire [23:0] rgb_in;                        // 由 disp_mix 组合算出

    lcd_timing #(
        .H_SYNC(41), .H_BACK(2), .H_DISP(HDISP), .H_FRONT(2),
        .V_SYNC(10), .V_BACK(2), .V_DISP(VDISP), .V_FRONT(2)
    ) u_timing (
        .clk     (clk_pix),
        .rst_n   (rst_pix_n),
        .rgb_in  (rgb_in),
        .rgb_out (lcd_rgb),
        .hsync   (lcd_hs),
        .vsync   (lcd_vs),
        .de      (de),
        .x       (x),
        .y       (y),
        .sof     (sof)
    );

    // 像素时钟直连输出脚（与璞致官方例程一致，已实测可用）
    assign lcd_clk = clk_pix;

    //=========================================================================
    // 2. 色相滚动
    //=========================================================================
    reg [7:0] frame_cnt;
    reg [6:0] hue_off;

    // 色相滚动节拍：spd 取 0..5，0 = 不滚动，其余每 2^spd 帧滚一级
    wire [2:0] hue_spd = (ui_hue_spd == 8'd0) ? 3'd0
                       : (ui_hue_spd > 8'd5)  ? 3'd5 : ui_hue_spd[2:0];
    wire [7:0] tick_mask = (hue_spd == 3'd0) ? 8'hFF : ((8'd1 << hue_spd) - 8'd1);

    always @(posedge clk_pix) begin
        if (!rst_pix_n) begin
            frame_cnt <= 8'd0;
            hue_off   <= 7'd0;
        end else if (sof) begin
            frame_cnt <= frame_cnt + 1'b1;
            // 滚动速度由 ui_ctrl 决定：每 2^spd 帧把色相加 1（spd=0 表示不滚动）
            //   ⚠️ Verilog 不允许可变宽度的位选（frame_cnt[spd-1:0] 是非法的），
            //      所以改用"可变掩码"：mask = (1<<spd)-1，低位全 1 时触发。
            // ⚠️ 必须写成 (cnt & mask) == mask，不能写成 cnt == mask ——
            //    后者 256 帧才命中一次（frame_cnt 是 8 位），色相几乎不动。
            if ((frame_cnt & tick_mask) == tick_mask) begin
                hue_off <= hue_off + 1'b1;
            end
        end
    end

    //=========================================================================
    // 3. 跨时钟域快照
    //=========================================================================
    wire [NBARS*HW-1:0] bars;

    spec_sync #(.NBARS(NBARS), .HW(HW)) u_sync (
        .wclk   (clk_sys),
        .wrst_n (rst_sys_n),
        .wr_en  (spec_wr),
        .din    (spec_din),
        .full   (),
        .rclk   (clk_pix),
        .rrst_n (rst_pix_n),
        .sof    (sof),
        .bars   (bars)
    );

    //=========================================================================
    // 4. 背景生成
    //=========================================================================
    wire [23:0] bg_rgb;

    bg_src #(.HDISP(HDISP), .VDISP(VDISP)) u_bg (
        .x    (x),
        .y    (y),
        .mode (ui_mode),
        .rgb  (bg_rgb)
    );

    //=========================================================================
    // 5. 波形缓冲（跨时钟域）
    //=========================================================================
    wire signed [23:0] wave_sample;

    wave_buf #(.DW(24), .AW(10), .SPAN(HDISP)) u_wave (
        .wclk   (clk_sys),
        .wrst_n (rst_sys_n),
        .we     (wave_we),
        .din    (wave_din),
        .rclk   (clk_pix),
        .rrst_n (rst_pix_n),
        .sof    (sof),
        .x      (x),
        .dout   (wave_sample)
    );

    //=========================================================================
    // 6. 混合
    //=========================================================================
    disp_mix #(
        .HDISP(HDISP), .VDISP(VDISP), .NBARS(NBARS), .HW(HW),
        .BARS_Y0(BARS_Y0), .BAR_GAP(BAR_GAP),
        .POL_CX(POL_CX), .POL_CY(POL_CY), .POL_RIN(POL_RIN), .POL_RMAX(POL_RMAX),
        .WAVE_CY(WAVE_CY), .WAVE_AMP(WAVE_AMP), .WAVE_TH(WAVE_TH)
    ) u_mix (
        .x       (x),
        .y       (y),
        .bg_rgb  (bg_rgb),
        .bars    (bars),
        .hue_off (hue_off),
        .wave    (wave_sample),
        .view_en (ui_view),
        .mode    (ui_style),
        .rgb     (rgb_in)
    );

endmodule
