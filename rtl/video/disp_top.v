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
    parameter integer BARS_H     = `DISP_BARS_H,
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
    parameter integer ANIM_STEP = 4,

    //-------------------------------------------------------------------------
    // UI 按钮带（P1-1 工控屏）
    //-------------------------------------------------------------------------
    parameter integer NB_UI  = `DISP_UI_NB,
    parameter integer UI_BX0 = 0,
    parameter integer UI_BY0 = `DISP_UI_BY0,
    parameter integer UI_BW  = `DISP_UI_BW,
    parameter integer UI_BH  = `DISP_UI_BH,
    parameter integer UI_GAP = `DISP_UI_GAP
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

    //--------------------- 触摸原始读数（clk_sys 域）---------------------
    input  wire [11:0]           tp_x,
    input  wire [11:0]           tp_y,
    input  wire [11:0]           tp_edges,      // 诊断：DOUT 跳变次数
    input  wire                  tp_low,        // 诊断：DOUT 是否出现过低电平

    //--------------------- 液晶输出 ---------------------
    //--------------------- 按钮命中（送回 clk_sys 改配置）---------------------
    //   ui_btn_act   : 当前正按着的按钮的动作码（4'hF = 没按）
    //   ui_btn_press : 【按下那一拍】的单拍脉冲 —— 上层用它触发一次动作。
    //                  边沿检测放在这里而不是上层，是因为"按下"的原始状态
    //                  就在本模块里（demo 扫描 / 真实触摸二选一），
    //                  上层拿到的已经是屏幕坐标了，再判一次边沿反而绕。
    output wire [3:0]            ui_btn_act,
    output wire                  ui_btn_press,

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

    // 触摸原始读数也要跨过来。它们是慢变量（10 ms 才更新一次），
    // 而且只用来在屏幕上显示数字 —— 偶尔采到中间态最多让某一帧的数字
    // 闪一下，无害。真正需要无损传递的多比特数据走异步 FIFO。
    wire [11:0] tp_x_s, tp_y_s;
    wire [11:0] tp_edges_s;
    wire        tp_low_s;
    cdc_sync #(.WIDTH(12), .RESET_VAL(12'd0)) u_sync_tpx (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(tp_x), .dout(tp_x_s));
    cdc_sync #(.WIDTH(12), .RESET_VAL(12'd0)) u_sync_tpy (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(tp_y), .dout(tp_y_s));
    cdc_sync #(.WIDTH(12), .RESET_VAL(12'd0)) u_sync_tpe (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(tp_edges), .dout(tp_edges_s));
    cdc_sync #(.WIDTH(1), .RESET_VAL(1'b0)) u_sync_tpl (
        .clk(clk_pix), .rst_n(rst_pix_n), .din(tp_low), .dout(tp_low_s));

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
    // 6. 触摸坐标：原始 ADC -> 屏幕坐标（或者演示扫描）
    //-----------------------------------------------------------------------------
    // 【真实触摸】XPT2046 原始值大约 200..3900（12 位）。
    //   先做一个【临时线性标定】：screen = raw >> 3（4096/8 = 512，接近 480）。
    //   这只是让 UI 能动起来；等 U2 焊好后，要按实测的四角坐标做正式标定
    //   （带偏移和斜率），那时候再改这里。
    //
    // 【按下判定】没触摸时 XPT2046 的读数会贴到 0 或 4095，所以
    //   "落在一个像样的中间范围"就当作按下。
    //
    // 【T04 演示扫描】焊好之前，用一个虚拟光标依次停在每个按钮上并"按下"，
    //   让人现在就能看到工控屏 UI 工作。它也顺便是个演示模式。
    //=========================================================================
    wire demo_touch = (ui_demo_s[3:0] == 4'd4);

    wire [9:0] tch_x_raw = tp_x_s[11:3];
    wire [8:0] tch_y_raw = tp_y_s[11:4];
    // 阈值必须覆盖到【屏幕最下边】对应的原始值：
    //   screen = raw >> 4，屏幕底 y=271 -> raw = 271*16 = 4336。
    //   第一版写的是 <4000，于是按钮带（屏幕下半部分）永远判不成"按下"。
    //   这里放宽到"没卡在两端轨"就行 —— 没触摸时 XPT2046 会贴到 0 或 4095。
    //   ⚠️ 这只是【临时】判据；正式标定要在拿到实测四角之后重做。
    wire       tch_down  = (tp_x_s > 12'd16) && (tp_x_s < 12'd4080) &&
                           (tp_y_s > 12'd16) && (tp_y_s < 12'd4080);

    // ---- 演示扫描：每 SW_HOLD 拍换一个按钮，切换时给一个短"按下"脉冲 ----
    // ⚠️ SW_PUSH 必须【明显长于触摸轮询周期】（那一头是 5 ms），
    //   否则按下会被轮询整个跳过，表现为"某些按钮好用、某些不好用"。
    //   第一版 SW_PUSH=80_000（6.4 ms）< 轮询 10 ms，实测就是只有个别按钮生效。
    localparam integer SW_HOLD = 4_000_000;     // @12.5MHz 约 0.32 s
    localparam integer SW_PUSH = 2_000_000;     // 按下持续约 0.16 s（远大于轮询周期）

    reg [22:0] sw_cnt;
    reg [2:0]  sw_idx;

    always @(posedge clk_pix) begin
        if (!rst_pix_n) begin
            sw_cnt <= 23'd0;
            sw_idx <= 3'd0;
        end else if (demo_touch) begin
            if (sw_cnt == SW_HOLD - 1) begin
                sw_cnt <= 23'd0;
                sw_idx <= (sw_idx == NB_UI - 1) ? 3'd0 : sw_idx + 1'b1;
            end else begin
                sw_cnt <= sw_cnt + 1'b1;
            end
        end else begin
            sw_cnt <= 23'd0;
            sw_idx <= 3'd0;
        end
    end

    // 光标停在按钮 sw_idx 的中心
    wire [XW-1:0] sw_x = UI_BX0 + sw_idx*(UI_BW+UI_GAP) + UI_BW/2;
    wire [YW-1:0] sw_y = UI_BY0 + UI_BH/2;
    wire          sw_down = demo_touch && (sw_cnt < SW_PUSH);

    wire [XW-1:0] tx_scr = demo_touch ? sw_x : tch_x_raw;
    wire [YW-1:0] ty_scr = demo_touch ? sw_y : tch_y_raw;
    wire          td_scr = demo_touch ? sw_down : tch_down;


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
    wire [4*8-1:0] ui_level;      // 4 个通道：柱状/极坐标/波形/面板

    //=========================================================================
    // 3b-0. 操作面板的展开/收起（声明提前，驱动在 ui_layer 之后）
    //-----------------------------------------------------------------------------
    //   ⚠️ 这里有个环：ui_anim 要用 panel_target，panel_target 要用 ui_open，
    //      而 ui_open 的翻转要用 ui_layer 输出的 tab_press。
    //      Verilog 没有前置声明，只能【声明提前、驱动后置】——
    //      和账本第 82/83 条那个环是同一套解法。
    //
    //   演示扫描时必须强制展开：否则按钮整条在屏幕外，命中测试永远落空，
    //   T04 就成了"光标在动但没人接"。
    //=========================================================================
    localparam integer TAB_MS  = `DISP_UI_IDLE_MS;       // 空闲多久自动收起
    localparam integer TAB_CNT = 12500 * TAB_MS;         // @12.5MHz，1 ms = 12500 拍

    reg  [23:0] idle_cnt;
    reg         ui_open;
    wire        panel_target = demo_touch | ui_open;

    ui_anim #(.NCH(4), .FULL(ANIM_FULL), .STEP(ANIM_STEP)) u_anim (
        .clk    (clk_pix),
        .rst_n  (rst_pix_n),
        .frame  (sof),          // 帧起始，每帧只走一步
        .target ({panel_target, ui_view_s}),   // [3]=面板 [2:0]=三个视图
        .level  (ui_level)
    );

    wire [7:0] pres_bar = ui_level[0*8 +: 8];   // 柱状
    wire [7:0] pres_pol = ui_level[1*8 +: 8];   // 极坐标
    wire [7:0] pres_wav = ui_level[2*8 +: 8];   // 波形
    wire [7:0] pres_panel = ui_level[3*8 +: 8];   // 操作面板

    // 动画后的实际 y：收起时整条移到屏幕下边缘之外
    //   level=128 -> y = BY0；level=0 -> y = VDISP（看不见）
    // 宏不能直接放进拼接里（`DISP_UI_BH 的宽度不定），先落成有宽度的常量
    localparam [9:0] UI_BH_L = `DISP_UI_BH;
    wire [YW+7:0] by0_mul = {6'b0, UI_BH_L} * pres_panel[7:0];
    wire [YW-1:0] ui_by0  = VDISP[YW-1:0] - by0_mul[YW+6:7];

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
        .dout   (wave_sample),
        // 这两个只是给调试/测试用的观测点，显示链不用它们。
        // 【为什么要显式写出来】不写的话 Verilator 报 PINMISSING（真问题类），
        // 显式接空只是 PINCONNECTEMPTY（风格类，已在白名单里）。
        .trig_pulse(),
        .done_pulse()
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

    status_line #(.NLEN(`DISP_TXT_NLEN), .NC(`DISP_TXT_NLEN)) u_status (
        .clk           (clk_pix),
        .rst_n         (rst_pix_n),
        .cfg_view      ({5'b0, ui_view_s}),
        .cfg_style     ({4'b0, ui_style_s}),
        .cfg_hue_spd   (ui_hue_spd_s),
        .cfg_wave_gain (ui_wave_gain_s),
        .cfg_bg_mode   ({4'b0, ui_mode_s}),
        .cfg_demo      (ui_demo_s),
        .tp_x          (tp_x_s),
        .tp_y          (tp_y_s),
        .tp_edges      (tp_edges_s),
        .tp_low        (tp_low_s),
        .we            (text_we),
        .waddr         (text_waddr),
        .wdata         (text_wdata)
    );

    // NC=20：每行 20 字符 = 160 px 宽，正好不碰圆盘（圆盘从 x=178 起）。
    // NL=8 ：6 行配置标签 + 2 行触摸诊断。
    //   旧配置是 NC=60/NL=4（240 项），现在是 160 项 —— 反而更省。
    text_buf #(.NC(`DISP_TXT_NLEN), .NL(`DISP_TXT_NL), .XW(XW), .YW(YW),
               .TX0(2), .TY0(2)) u_text (
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
    // 6b. UI 按钮层（工控屏式操作条）
    //   必须放在高亮逻辑【之前】：高亮要用到它的 hit_act（ui_btn_act）。
    //=========================================================================
    wire        ui_draw;
    wire [23:0] ui_rgb;
    wire [2:0]  ui_hit_k;
    wire        tab_hit_w;
    reg         tab_hit_d;

    // 把手按下的边沿检测（tab_hit_w 是电平，切成单拍脉冲给 ui_open 用）
    always @(posedge clk_pix) begin
        if (!rst_pix_n) tab_hit_d <= 1'b0;
        else            tab_hit_d <= tab_hit_w;
    end
    wire tab_press = tab_hit_w & ~tab_hit_d;

    // 高亮值要先声明（Verilog 不允许先用后声明）——
    //   ui_layer 例化时就要用到它，而"锁存最近按下"的逻辑在下面。
    reg [3:0]  ui_active;

    ui_layer #(
        .NB(NB_UI), .XW(XW), .YW(YW),
        .BX0(UI_BX0), .BY0(UI_BY0), .BW(UI_BW), .BH(UI_BH), .GAP(UI_GAP)
    ) u_ui (
        .x        (x),
        .y        (y),
        .tx       (tx_scr),
        .ty       (ty_scr),
        .pressed  (td_scr),
        .ui_by0   (ui_by0),
        .ui_open  (panel_target),
        .active   (ui_active),
        .draw     (ui_draw),
        .rgb      (ui_rgb),
        .hit_k    (ui_hit_k),
        .hit      (),
        .hit_act  (ui_btn_act),
        .tab_hit  (tab_hit_w)
    );

    // 高亮：锁存"最近一次按下的按钮"，松开后保持约 1.3 s，让人看清反馈。
    //   press_now 是按下沿；它同时也作为对外的 ui_btn_press 脉冲。
    reg [21:0] hl_cnt;
    reg        td_scr_d;
    wire       press_now = td_scr & ~td_scr_d;

    always @(posedge clk_pix) begin
        if (!rst_pix_n) begin
            td_scr_d  <= 1'b0;
            ui_active <= 4'hF;
            hl_cnt    <= 22'd0;
        end else begin
            td_scr_d <= td_scr;
            if (press_now) begin
                ui_active <= ui_btn_act;    // 按下时锁存动作码
                hl_cnt    <= 22'd0;
            end else if (hl_cnt != 22'h3FFFFF) begin
                hl_cnt <= hl_cnt + 1'b1;    // 保持一段时间后自动清高亮
            end else begin
                ui_active <= 4'hF;
            end
        end
    end

    //=========================================================================
    // 6b-2. 面板展开/收起的驱动（放在 ui_layer 之后：要用它的 tab_press）
    //=========================================================================
    always @(posedge clk_pix) begin
        if (!rst_pix_n) begin
            ui_open  <= 1'b0;
            idle_cnt <= 24'd0;
        end else begin
            // 任何触摸（或演示里的"按下"）都算活动，重置空闲计时
            if (td_scr || tab_press) idle_cnt <= 24'd0;
            else if (idle_cnt != TAB_CNT[23:0]) idle_cnt <= idle_cnt + 1'b1;

            if (tab_press)                       // 点把手 -> 切换
                ui_open <= ~ui_open;
            if (idle_cnt == TAB_CNT[23:0])       // 空闲超时 -> 自动收起
                ui_open <= 1'b0;
        end
    end

    assign ui_btn_press = press_now;

    //=========================================================================
    // 7. 混合
    //=========================================================================
    disp_mix #(
        .HDISP(HDISP), .VDISP(VDISP), .NBARS(NBARS), .HW(HW),
        .XW(XW), .YW(YW),
        .BARS_Y0(BARS_Y0), .BARS_H(BARS_H), .BAR_GAP(BAR_GAP),
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
        .ui_draw (ui_draw),
        .ui_rgb  (ui_rgb),
        .rgb     (rgb_in)
    );

endmodule
