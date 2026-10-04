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
// 【色相滚动】每 N 帧把 hue_off 加 1，128 帧走完一整圈彩虹。
//   N 由 ui_hue_spd（H 命令）决定，**H 越大越快**，H=0 完全停住。
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
    parameter integer SCROLL_DIV = 5,       // 每多少帧色相滚动一级

    //-------------------------------------------------------------------------
    // 时序（P1-3a：从例化处提到参数表，双输出时每路一套）
    //-------------------------------------------------------------------------
    parameter integer H_SYNC     = 41,
    parameter integer H_BACK     = 2,
    parameter integer H_FRONT    = 2,
    parameter integer V_SYNC     = 10,
    parameter integer V_BACK     = 2,
    parameter integer V_FRONT    = 2,

    //-------------------------------------------------------------------------
    // 坐标位宽
    //-----------------------------------------------------------------------------
    // 必须写在【参数表里】（而不是模块体内的 localparam）：端口声明的位宽要在
    // 解析模块头时就确定，而 localparam 在它后面 —— 这是账本第 24 条踩过的坑。
    // Verilog-2001 允许后面的 parameter 引用前面的，所以可以这样算。
    //
    // 宽度按【含消隐期的总周期】算（和 lcd_timing 内部一致），
    // 因为 x/y 是从 hcnt/vcnt 减出来的，位宽必须装得下计数器。
    //   480x272: $clog2(41+2+480+2)=10 、 $clog2(10+2+272+2)=9
    //   —— 恰好是原来写死的 [9:0] / [8:0]，所以本次重构对现有布局【逐位不变】
    parameter integer XW = $clog2(H_SYNC + H_BACK + HDISP + H_FRONT),
    parameter integer YW = $clog2(V_SYNC + V_BACK + VDISP + V_FRONT),

    //-------------------------------------------------------------------------
    // 属性插值器的满值 / 每帧步进（P1-1）
    //   FULL=128 -> 显示侧除以 128 就是右移 7 位，零成本。
    //   过渡时长 = FULL/STEP 帧。
    //   暴露成参数是为了测试：TB 里把 STEP 设成 FULL，一帧就到位，
    //   否则逐像素比对的参照模型要等 32 帧才和 DUT 一致（一帧 150150 拍，
    //   32 帧就是 480 万拍，仿真跑不动）。
    //-------------------------------------------------------------------------
    parameter integer ANIM_FULL = 128,
    parameter integer ANIM_STEP = 4
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
    input  wire [7:0]            ui_wave_gain,  // 来自 ui_ctrl：波形增益（G 命令）
    input  wire [7:0]            ui_demo,       // 来自 ui_ctrl：演示图案（T 命令）

    //--------------------- 液晶输出 ---------------------
    output wire [23:0]           lcd_rgb,
    output wire                  lcd_hs,
    output wire                  lcd_vs,
    output wire                  lcd_clk
);

    //=========================================================================
    // 1. 时序发生器
    //=========================================================================
    wire [XW-1:0] x;
    wire [YW-1:0] y;
    wire        de;
    wire        sof;
    wire [23:0] rgb_in;                        // 由 disp_mix 组合算出

    lcd_timing #(
        .H_SYNC(H_SYNC), .H_BACK(H_BACK), .H_DISP(HDISP), .H_FRONT(H_FRONT),
        .V_SYNC(V_SYNC), .V_BACK(V_BACK), .V_DISP(VDISP), .V_FRONT(V_FRONT),
        // 显式传入，避免和 lcd_timing 内部的公式各自算一遍而错开
        .HW(XW), .VW(YW)
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
    // 2b. 配置位的跨时钟域同步（补历史遗漏）
    //-----------------------------------------------------------------------------
    // ui_mode / ui_style / ui_view / ui_hue_spd 都是 ui_ctrl 在 **clk_sys** 里
    // 的寄存器，却在 clk_pix 域被直接使用 —— 中间没有任何同步器。
    //   · 这是【既有】问题，不是 ui_anim 引入的；
    //   · 但它们是人手改的慢变量，同步风险很低，所以一直没暴露；
    //   · 而且 ui_anim 现在要在 sof 那一拍拿它当目标，采样点变了，
    //     更应该先同步再喂进去。
    //
    // ⚠️ 注意：cdc_sync 对【多比特】总线只能保证单比特稳定，
    //    多位同时翻转时仍可能采到中间态 —— 典型后果是“一帧里切到错视图”，
    //    下一帧就恢复，属于视觉上的极短暂闪动。
    //    之所以可接受：ui_anim 只在帧起始采样一次（每 12 ms 一次），
    //    而亚稳态窗口只有几十纳秒，命中概率完全可以忽略。
    //    真正需要无损传递的多比特数据（柱高）走的是 spec_sync / 异步 FIFO。
    //=========================================================================
    wire [3:0] ui_mode_s, ui_style_s;
    wire [2:0] ui_view_s;
    wire [7:0] ui_hue_spd_s, ui_wave_gain_s, ui_demo_s;

    cdc_sync #(.WIDTH(4), .RESET_VAL(4'd0)) u_sync_mode (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(ui_mode), .dout(ui_mode_s));
    cdc_sync #(.WIDTH(4), .RESET_VAL(4'd0)) u_sync_style (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(ui_style), .dout(ui_style_s));
    // 复位值取 ui_ctrl 的上电默认（三视图全开），免得第一帧闪成“什么都没有”
    cdc_sync #(.WIDTH(3), .RESET_VAL(3'b111)) u_sync_view (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(ui_view), .dout(ui_view_s));
    cdc_sync #(.WIDTH(8), .RESET_VAL(8'd6)) u_sync_hue (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(ui_hue_spd), .dout(ui_hue_spd_s));
    cdc_sync #(.WIDTH(8), .RESET_VAL(8'd8)) u_sync_wg (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(ui_wave_gain), .dout(ui_wave_gain_s));
    cdc_sync #(.WIDTH(8), .RESET_VAL(8'd0)) u_sync_demo (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(ui_demo), .dout(ui_demo_s));

    //=========================================================================
    // 3. 色相滚动
    //=========================================================================
    reg [7:0] frame_cnt;
    reg [6:0] hue_off;

    //-------------------------------------------------------------------------
    // 滚动节拍：**H 越大越快**，H=0 停住
    //
    //   旧实现（上板后被反馈"H08 比 H03 还慢"）：
    //       tick_mask = (1 << H) - 1          ->  H 越大【越慢】
    //       而且 H=0 的 mask 是 0xFF，变成"每 256 帧"—— 【根本不是停住】，
    //       是全场最慢（文档还写反了）。
    //       又因为 hue_spd 只有 3 位并钳在 5，H06~H15 效果完全一样。
    //
    //   现在：H = 速度档，1..7 有效，越大越快；H=0 停住；>7 当 7（最快）。
    //       roll_period = 2^(8-H) 帧
    //         H=1 -> 每 128 帧 (1.54 s)   H=5 -> 每  8 帧 ( 96 ms)
    //         H=2 -> 每  64 帧            H=6 -> 每  4 帧 ( 48 ms)  <= 默认
    //         H=3 -> 每  32 帧 (384 ms)   H=7 -> 每  2 帧 ( 24 ms)  最快
    //         H=4 -> 每  16 帧 (192 ms)
    //
    //   默认值从 2 改成 **6**：因为 "H=6 -> 每 4 帧" 恰好等于旧 H=2 的
    //   "每 2^2 = 4 帧"，上电动画速度与之前完全一致，只是坐标换成了
    //   "越大越快"的直觉方向。
    //
    //   实现上仍用可变掩码（Verilog 不允许可变宽度位选 frame_cnt[H-1:0]，
    //   见账本）：mask = (1 << (8-H)) - 1，低位全 1 时触发。
    //   H=0 时 8-H=8，1<<8 溢出成 0，mask 变成 0xFF，但那时被 hue_run 挡住。
    //-------------------------------------------------------------------------
    wire [3:0] hue_spd   = (ui_hue_spd_s > 8'd7) ? 4'd7 : ui_hue_spd_s[3:0];
    wire       hue_run   = (hue_spd != 4'd0);
    wire [7:0] tick_mask = (8'd1 << (4'd8 - hue_spd)) - 8'd1;

    always @(posedge clk_pix) begin
        if (!rst_pix_n) begin
            frame_cnt <= 8'd0;
            hue_off   <= 7'd0;
        end else if (sof) begin
            frame_cnt <= frame_cnt + 1'b1;
            // ⚠️ 必须写成 (cnt & mask) == mask，不能写成 cnt == mask ——
            //    后者 256 帧才命中一次（frame_cnt 是 8 位），色相几乎不动。
            if (hue_run && ((frame_cnt & tick_mask) == tick_mask)) begin
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
    // 3b. 属性插值器：三个视图各自的“存在度”（0..128）
    //-----------------------------------------------------------------------------
    //   按 KEY1 切视图预设时，disp_mix 里那些显示开关是【硬跳】的 ——
    //   极坐标“咕”地出现 / 消失，在 12 ms 一帧的液晶上很生硬。
    //   这里给每个视图一个每帧走一小步的 level，显示侧把几何量乘以
    //   level/128，画面就是平滑地【长出来 / 缩回去】。
    //
    //   选 128 而不是 256：因为显示侧要算 x*level/FULL，FULL=128 时
    //   除以 128 就是右移 7 位，零成本。
    //   过渡时长 = FULL/STEP 帧 = 32 帧 ≈ 32 x 12.01 ms ≈ 384 ms。
    //=========================================================================
    wire [3*8-1:0] ui_level;

    ui_anim #(.NCH(3), .FULL(ANIM_FULL), .STEP(ANIM_STEP)) u_anim (
        .clk    (clk_pix),
        .rst_n  (rst_pix_n),
        .frame  (sof),          // 帧起始，每帧只走一步
        .target (ui_view_s),    // 已同步到 clk_pix
        .level  (ui_level)
    );

    wire [7:0] pres_bar = ui_level[0*8 +: 8];   // 柱状
    wire [7:0] pres_pol = ui_level[1*8 +: 8];   // 极坐标
    wire [7:0] pres_wav = ui_level[2*8 +: 8];   // 波形

    //=========================================================================
    // 4. 背景生成
    //=========================================================================
    wire [23:0] bg_rgb;

    bg_src #(.HDISP(HDISP), .VDISP(VDISP), .XW(XW), .YW(YW)) u_bg (
        .x    (x),
        .y    (y),
        .mode (ui_mode_s),
        .rgb  (bg_rgb)
    );

    //=========================================================================
    // 5. 波形缓冲（跨时钟域）
    //=========================================================================
    wire signed [23:0] wave_sample;

    wave_buf #(.DW(24), .AW(10), .SPAN(HDISP), .XW(XW)) u_wave (
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
    // 5b. 波形增益（G 命令）
    //-----------------------------------------------------------------------------
    // 【为什么补在这里】
    //   `ui_wave_gain` 以前在 ui_ctrl 里能存能读，却【根本没接到显示链上】——
    //   是个死控件（上板时发现：即使有音频，敲 G 画面也毫无变化）。
    //   现在插在 wave_buf 与 disp_mix 之间，两条输出可以各用一份增益。
    //
    // 【语义】G[3:0]，8 = ×1.0（默认）。
    //   0 当作 8 处理；把波形置静音没意义，要关波形请用 V 命令的 view_en[2]。
    //
    // 【为什么必须做饱和】
    //   wave 是 24 位有符号，满量程 2^23。×15 会到 1.5×2^26。
    //   直接截成 24 位会【符号翻转】（正峰变负峰），比钳位难看得多 ——
    //   屏幕上会看到波形突然跳到另一侧。
    //   所以先在 28 位里算，再按 24 位上下限钳住。
    //
    // 【踩过的两个坑，都在这四行里】
    //
    //  ① Verilog 的“有符号”看的是【表达式】，不是左侧声明：
    //     写成 `wire signed [3:0] gain_m = cond ? 4'sd8 : ui_wave_gain[3:0];`，
    //     右侧含【无符号的部分选择】，整个表达式就是无符号的。
    //
    //  ② 【更阴的一个】4 位有符号装不下 +8！
    //     4 位有符号的范围是 -8..+7，而 +8 的位型 4'b1000 被解释成【-8】。
    //     所以 `$signed(4'd8)` 得到的是 -8，乘法结果变成 -采样（符号翻转）。
    //     → 增益必须用【5 位】有符号。
    //
    //   实测症状：TB 报 "wave_adj=-6291456 vs 采样=+6291456"，
    //   而且幅度逐位相等 —— 一眼就能看出是取了相反数，不是缩放错。
    //=========================================================================
    wire [3:0]        gain_u = (ui_wave_gain[3:0] == 4'd0) ? 4'd8 : ui_wave_gain[3:0];
    wire signed [4:0] gain_m = $signed({1'b0, gain_u});   // 先补 0 再转有符号

    wire signed [28:0] wave_g  = wave_sample * gain_m;    // 24 位 x 5 位 -> 29 位
    wire signed [27:0] wave_d3 = wave_g >>> 3;            // /8

    localparam signed [23:0] WG_MAX =  24'sh7FFFFF;
    localparam signed [23:0] WG_MIN = -24'sh800000;

    wire signed [23:0] wave_adj = (wave_d3 > WG_MAX) ? WG_MAX
                                : (wave_d3 < WG_MIN) ? WG_MIN
                                : wave_d3[23:0];

    //=========================================================================
    // 5c. 状态行文字
    //-----------------------------------------------------------------------------
    // 状态行用【已同步到 clk_pix 的】配置值，整个链路都在 clk_pix 域，
    // 所以 text_buf 可以是单时钟的，不用再搞一个双时钟存储器。
    // 内容格式和 UART 的 '?' 回执完全一致，方便两边对着看：
    //     V7 S0 H6 G8 B0 D0
    //=========================================================================
    wire        text_we;
    wire [15:0] text_waddr;
    wire [7:0]  text_wdata;
    wire        text_hit, text_lit;

    status_line u_status (
        .clk           (clk_pix),
        .rst_n         (rst_pix_n),
        .cfg_view      ({5'b0, ui_view_s}),
        .cfg_style     ({4'b0, ui_style_s}),
        .cfg_hue_spd   (ui_hue_spd_s),
        .cfg_wave_gain (ui_wave_gain_s),
        .cfg_bg_mode   ({4'b0, ui_mode_s}),
        .cfg_demo      (ui_demo_s),
        .we            (text_we),
        .waddr         (text_waddr),
        .wdata         (text_wdata)
    );

    text_buf #(.NC(60), .NL(4), .XW(XW), .YW(YW), .TX0(2), .TY0(2)) u_text (
        .clk   (clk_pix),
        .we    (text_we),
        .waddr (text_waddr),
        .wdata (text_wdata),
        .x     (x),
        .y     (y),
        .hit   (text_hit),
        .lit   (text_lit)
    );

    //=========================================================================
    // 6. 混合
    //=========================================================================
    disp_mix #(
        .HDISP(HDISP), .VDISP(VDISP), .NBARS(NBARS), .HW(HW),
        .XW(XW), .YW(YW),
        .BARS_Y0(BARS_Y0), .BAR_GAP(BAR_GAP),
        .POL_CX(POL_CX), .POL_CY(POL_CY), .POL_RIN(POL_RIN), .POL_RMAX(POL_RMAX),
        .WAVE_CY(WAVE_CY), .WAVE_AMP(WAVE_AMP), .WAVE_TH(WAVE_TH)
    ) u_mix (
        .x       (x),
        .y       (y),
        .bg_rgb  (bg_rgb),
        .bars    (bars),
        .hue_off (hue_off),
        .wave    (wave_adj),
        .view_en (ui_view_s),
        .mode    (ui_style_s),
        .pres_bar(pres_bar),
        .pres_pol(pres_pol),
        .pres_wav(pres_wav),
        .text_hit(text_hit),
        .text_lit(text_lit),
        .rgb     (rgb_in)
    );

endmodule
