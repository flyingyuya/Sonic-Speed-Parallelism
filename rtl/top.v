//=============================================================================
// top.v - 整机顶层
//-----------------------------------------------------------------------------
// 纯 RTL 实时音频处理 + 频谱可视化系统
//
//                        ┌──────────────────────────────────────────────┐
//  WM8960 (接 JM2)       │                  FPGA                        │
//  ┌──────────┐          │                                              │
//  │24MHz 晶振│──MCLK──▶ │                                              │
//  │          │          │  clk_gen ──┬─ clk_sys 48MHz ─┬─ WM8960_init  │
//  │  BCLK ───┼─────────▶│            │                 │   (I2C 配置)  │
//  │  LRCLK ──┼─────────▶│            │                 │               │
//  │  ADCDAT ─┼─────────▶│            │                 ▼               │
//  │  DACDAT ◀┼──────────│            │            audio_top            │
//  │  SCL/SDA │◀────────▶│            │        (I2S 从 + 5 段均衡)      │
//  └──────────┘          │            │                 │ rx_l          │
//                        │            │   ┌─────────────┴────────┐      │
//                        │            │   │    ▼                 │      │
//  LCD (接 JM1)          │            │   │ fft_core → spectrum  │      │
//  ┌──────────┐          │            │   │  (1024 点)   (30 柱) │      │
//  │ RGB888   │◀─────────│            │   │                      │      │
//  │ HS/VS/CLK│◀─────────│            │   └──────────────────────┘      │
//  └──────────┘          │            │                   │             │
//                        │            └─▶ clk_pix 12.5MHz │             │
//                        │                      │         │             │
//                        │                      │         ▼             │
//                        │                      └───▶ disp_top → LCD    │
//                        └──────────────────────────────────────────────┘
//
// 【三个时钟域】
//   clk_sys = 48 MHz   音频 + 控制（I2C 配置、I2S 时序恢复、EQ、FFT、频谱）
//   clk_pix = 12.5 MHz 显示扫描
//   BCLK    = 3.072 MHz（外部输入，不当时钟用，只做过采样恢复）
//
//   注意 BCLK/LRCLK 是【异步输入】，本工程不把它们当全局时钟，
//   而是由 i2s_slave_clk 在 clk_sys 域过采样出边沿选通 —— 少一个时钟域，
//   也避免了时钟脚上的抖动问题。
//
// 【上电顺序】
//   1. MMCM 锁定
//   2. 等 10 ms（让 WM8960 自己的晶振和内部电路稳下来）
//   3. 发 I2C 配置序列（约 21 ms，其中含 PLL 锁定余量 9.6 ms）
//   4. Init_Done 拉高后才放行 audio_top / fft / spectrum
//      —— 因为配置过程中 BCLK/LRCLK 频率会变，此时不能收数据
//=============================================================================
`timescale 1ns/1ps

module top #(
    // 【仿真友好】上电等待和 I2C 每条之间的延时做成参数，
    //   整机冒烟仿真可以把它们调小，否则光上电就要跑 31 ms 仿真时间。
    //   综合时用默认值（10 ms + 1 ms x 20 条）。
    parameter integer INIT_WAIT_MS = 10,        // 复位释放后等多久再发 I2C
    parameter integer I2C_DLY_MS   = 1,         // I2C 每条寄存器之间的间隔

    // 【仿真友好·同款】按键消抖时长 和 双击判定窗。
    //   为什么要做成参数：单击要等"窗口期满"才上报（见 key_gesture.v），
    //   产品值是 300ms，但整机冒烟仿真里每等一次就是 14.4M 拍 ——
    //   两次单击就是 660ms 仿真时间，直接把冒烟测试跑到超时（实测 25 分钟）。
    //   所以 TB 把这两个值调小（1ms / 8ms），产品保持默认。
    //   ⚠️ 注意：TB 调小后，TB 里的"按住/松开"时长也必须跟着缩小，
    //      否则"两次按下的间隔"会超过窗口，双击就测不出来。
    parameter integer KEY_DB_MS    = 20,        // key_debounce 消抖
    parameter integer KEY_WIN_MS   = 300,       // key_gesture 双击判定窗

    // 属性插值器每帧步进。默认 4 -> 32 帧 ≈ 384 ms 的过渡。
    //   暴露出来是为了让 testbench 能设成 128（一帧到位）：
    //   否则 TB 要等 384 ms 仿真时间才能看到操作面板开完，跑不动。
    parameter integer ANIM_STEP    = 4,

    // SD 背景图的存放起始扇区（每张图占 512 个扇区 = 256 KB）
    //   要和 scripts/sdcard/mkimage.py 的布局一致
    parameter [31:0]  IMG_SECTOR_BASE = 32'd2048
) (
    //----------------------- 时钟与复位 -----------------------
    input  wire        clk_200m_p,      // R4  IO_L13P_MRCC_34（差分）
    input  wire        clk_200m_n,      // T4  IO_L13N_MRCC_34
    input  wire        rst_btn_n,       // R14 板载复位按键，低有效
    input  wire        key1_n,          // W21 KEY1，按下 = 低
    input  wire        key2_n,          // Y21 KEY2，按下 = 低

    //----------------------- UART（板载 CH340E）---------------
    input  wire        uart_rx_pin,     // P14  PC -> FPGA
    output wire        uart_tx_pin,     // P15  FPGA -> PC

    //----------------------- WM8960（接 JM2）------------------
    output wire        aud_scl,
    inout  wire        aud_sda,
    input  wire        aud_bclk,
    input  wire        aud_lrclk,
    input  wire        aud_adcdat,      // WM8960 ADCDAT -> FPGA
    output wire        aud_dacdat,      // FPGA -> WM8960 DACDAT

    //----------------------- LCD（接 JM1）---------------------
    // XPT2046 电阻触摸屏（在 LCD 子卡上，经 JM1 的 37~40 脚过来）
    output wire        tp_dclk,
    output wire        tp_cs_n,
    output wire        tp_din,
    input  wire        tp_dout,

    output wire [23:0] lcd_rgb,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output wire        lcd_clk,

    //----------------------- 指示 -----------------------------
    output wire [1:0]  led,

    //----------------------- SD 卡（SPI 模式）------------------
    //   引脚见 constrs/sd.xdc：CLK=AA20 / CMD(MOSI)=AB21 /
    //   DATA0(MISO)=AB18 / DATA3(CS)=AA21
    //   CS 用 DATA3 是 SD 规范对 SPI 模式的规定。
    output wire        sd_clk,
    output wire        sd_cs,
    output wire        sd_mosi,
    input  wire        sd_miso,

    //--------------------- HDMI 输出（DVI 兼容，无发送芯片）---------------------
    //   Bank 14 的 Vcco = 3.3V，所以差分用 TMDS_33（见 constrs/hdmi.xdc）
    //   通道分配：D0=蓝  D1=绿  D2=红  时钟=像素时钟
    output wire        hdmi_clk_p,
    output wire        hdmi_clk_n,
    output wire        hdmi_d0_p,
    output wire        hdmi_d0_n,
    output wire        hdmi_d1_p,
    output wire        hdmi_d1_n,
    output wire        hdmi_d2_p,
    output wire        hdmi_d2_n,
    output wire        hdmi_out_en,     // 低有效（NC7SZ125 的 OE）
    input  wire        hdmi_hpd         // 热插拔检测（本版不参与逻辑，但必须进端口）
);

    //=========================================================================
    // 1. 时钟生成（一个 MMCM 出 48 MHz + 12.5 MHz，VCO = 900 MHz）
    //=========================================================================
    wire clk_sys;                       // 48 MHz
    wire clk_pix;                       // 12.5 MHz
    wire clk_hdmi;                      // 40 MHz  —— HDMI 像素时钟
    wire clk_5x;                        // 200 MHz —— HDMI 串行化时钟
    wire mmcm_locked;

    //   clk_hdmi / clk_5x 供 hdmi_top 使用（40 MHz 像素钟 / 200 MHz 串行钟）。
    clk_gen u_clkgen (
        .clk_200m_p  (clk_200m_p),
        .clk_200m_n  (clk_200m_n),
        .rst_btn_n   (rst_btn_n),
        .clk_sys     (clk_sys),
        .clk_pix     (clk_pix),
        .clk_hdmi    (clk_hdmi),
        .clk_5x      (clk_5x),
        .mmcm_locked (mmcm_locked)
    );

    //=========================================================================
    // 2. 复位同步
    //    两个域各自同步一份，异步置位 / 同步释放
    //=========================================================================
    wire arst_n = rst_btn_n & mmcm_locked;

    wire rst_sys_n, rst_pix_n;

    rst_sync u_rst_sys (
        .clk         (clk_sys),
        .rst_async_n (arst_n),

        .rst_n       (rst_sys_n)
    );

    rst_sync u_rst_pix (
        .clk         (clk_pix),
        .rst_async_n (arst_n),

        .rst_n       (rst_pix_n)
    );

    //=========================================================================
    // 3. WM8960 上电配置
    //    复位释放后等 10 ms 再发 I2C，让模块自己的晶振和内部电路稳下来
    //=========================================================================
    localparam integer WAIT_CYC = 48_000_000 / 1000 * INIT_WAIT_MS;

    reg  [31:0] wait_cnt;
    reg         init_go;
    reg         init_started;
    wire        init_done;

    //-------------------------------------------------------------------------
    // 音频输入源（P1-6 线路输入）
    //   0 = 话筒（LINPUT1）  1 = 线路输入（LINPUT3/RINPUT3）
    //   默认话筒 —— 与改造前完全一致，行为零变化。
    //   变化时会重新脉冲一次 init_go（整表重写，表是幂等的，安全）。
    //-------------------------------------------------------------------------
    //   ⚠️ src_sel 是【wire】：它由 ui_ctrl 的 cfg_src 驱动（见下面的 assign）。
    //      不要在这里用 always 写它 —— 那会变成"同一个变量被两种方式驱动"，
    //      静态检查工具会直接报 BLKANDNBLK 类错误。
    //      （注意：注释里不要写"斜杠/斜杠 空白 + 该工具名"——
    //        它会被当成 pragma 解析，报 BADVLTPRAGMA。）
    wire        src_sel;
    reg         src_sel_d;
    wire        src_chg = (src_sel != src_sel_d);

    always @(posedge clk_sys) begin
        if (!rst_sys_n) begin
            wait_cnt     <= 32'd0;
            init_go      <= 1'b0;
            init_started <= 1'b0;
            src_sel_d    <= 1'b0;               // src_sel 由 ui_ctrl 复位（默认话筒）
        end else begin
            init_go    <= 1'b0;                 // 默认拉低，只给一个脉冲
            src_sel_d  <= src_sel;
            if (!init_started) begin
                wait_cnt <= wait_cnt + 1'b1;
                if (wait_cnt >= WAIT_CYC) begin
                    init_go      <= 1'b1;
                    init_started <= 1'b1;
                end
            end else if (src_chg) begin
                // 输入源变了 -> 重跑一遍整表初始化。
                // 表是幂等的（每条都是"设定成某个值"），全表重写比"只写 4 条"
                // 更省事也更不容易漏；代价只有 ~33ms 的 I2C 时间。
                init_go <= 1'b1;
            end
        end
    end

    WM8960_init #(
        .CLK_FREQ_HZ (48_000_000),
        .DLY_MS      (I2C_DLY_MS)
    ) u_wm_init (
        .Clk       (clk_sys),
        .Rst_n     (rst_sys_n),
        .Go        (init_go),
        .device_id (8'h34),                 // WM8960: 7bit 0x1A << 1 | W
        .src_sel   (src_sel),               // 0=话筒 1=线路输入（P1-6）
        .Init_Done (init_done),
        .i2c_sclk  (aud_scl),
        .i2c_sdat  (aud_sda)
    );

    //=========================================================================
    // 4. 音频链路
    //    Init_Done 之前不放行 —— 配置过程中 BCLK/LRCLK 频率会变
    //=========================================================================
    wire aud_rst_n = rst_sys_n & init_done;

    wire signed [23:0] rx_l, rx_r;
    wire               dacdat_audio;
    wire               dbg_bclk_fall, dbg_frame_start;
    wire [5:0]         dbg_bit_idx;
    wire               rx_valid;

    //=========================================================================
    // 6d-2. 直流阻断（只作用于【显示用的波形】）
    //-----------------------------------------------------------------------------
    //   【为什么需要】音频 ADC 输出带直流偏置。对波形显示有两个具体危害：
    //     ① 波形不居中（零点不在屏幕中线上）
    //     ② **触发不了** —— wave_buf 用"先低于 -TH，再向上过零"的迟滞触发。
    //        直流偏置比信号幅度还大时，信号永远到不了负半周，
    //        迟滞闸门永远打不开 -> 只能靠自动触发兜底 -> 画面一直跳。
    //
    //   【为什么插在这里而不是音频主通路】
    //     插在 audio_top 后面会让已经逐位验证过的 EQ / 频谱行为发生变化。
    //     disp_top 一行都不用改 -> tb_disp_top 的参照模型也不用动。
    //
    //   【2026-10 修正：它现在接在【分叉之前】】
    //     原来只给"波形"那一路做，FFT 吃的还是带直流的 rx_l ——
    //     上板实测：频谱【第一根柱子明显偏高】，那正是直流全落在第 0 个 bin。
    //     现在改成在 rx_l 之后立刻分叉，波形和 FFT 都吃去直流后的信号。
    //     直流送进 FFT 本来就没有物理意义，所以这是纯粹的修正。
    //     演示图案（T01~T04）仍然接在 mux 之后，不受影响。
    //
    //   截止频率约 7.46 Hz（SH=10 @48kHz），零 DSP：只有一个移位和一个减法。
    //=========================================================================
    wire signed [23:0] rx_l_dc;

    dc_block #(.DW(24), .SH(10), .GW(2)) u_dc_block (
        .clk   (clk_sys),
        .rst_n (rst_sys_n),
        .en    (rx_valid),          // 每个采样一个 strobe
        .din   (rx_l),
        .dout  (rx_l_dc)
    );


    audio_top #(
        .DW(24), .CW(18), .CF(16), .AW(48), .NSECT(5), .SLOT(32)
    ) u_audio (
        .clk        (clk_sys),
        .rst_n      (aud_rst_n),
        .bclk       (aud_bclk),
        .lrclk      (aud_lrclk),
        .sdin       (aud_adcdat),
        .sdout      (dacdat_audio),
        // ⚠️⚠️ 【上板实测的真 bug：EQ 系数从来没装载过】
        //   cfg_load 一直是 0，`coe` 寄存器就一直是初值 -> EQ 输出是垃圾
        //   -> DAC 放出来是"刺耳的高频噪声"，安静时也不停。
        //   （TB 里是 TB 自己驱动 cfg_load 的，所以仿真里完全看不出来 ——
        //     典型的"仿真过了 ≠ 板上对"。）
        //
        //   band_gain 每个频段 5 bit，索引 0..20 映射 -10..+10 dB，
        //   所以【0 dB = 索引 10】。原来写 25'd0 是 -10 dB（而且注释还写着 0 dB）。
        //   cfg_load 用常高：audio_top 里是"band_gain != gain_reg 才装载"，
        //   所以常高不会反复重载，但以后 band_gain 一改就会自动重载。
        .band_gain  ({5{5'd10}}),           // 5 个频段都是 0 dB（index 10 = 0 dB）
        .cfg_load   (1'b1),
        .bypass     (1'b0),
        .cfg_busy   (),
        .running    (),
        .dbg_bclk_rise   (),
        .dbg_bclk_fall   (dbg_bclk_fall),
        .dbg_frame_start (dbg_frame_start),
        .dbg_half_start  (),
        .dbg_bit_idx     (dbg_bit_idx),
        .dbg_sample_stb  (),
        .dbg_rx_l        (rx_l),
        .dbg_rx_r        (rx_r),
        .dbg_rx_valid    (rx_valid)
    );

    //=========================================================================
    // 5. FFT + 频谱柱高
    //    只分析左声道（fft_core 接受实数输入）
    //=========================================================================
    wire [8:0]   fft_index;
    wire [24:0]  fft_mag;
    wire         fft_valid;

    fft_core #(
        .N(1024), .LOG2N(10), .DW(24), .TW(16), .FIFO_DEPTH(64)
    ) u_fft (
        .clk      (clk_sys),
        .rst_n    (aud_rst_n),
        .x_in     (rx_l_dc),          // 去直流后再送 FFT（直流落在第 0 个 bin，没意义）
        .x_valid  (rx_valid),
        .y_index  (fft_index),
        .y_mag    (fft_mag),
        .y_valid  (fft_valid),
        .busy     (),
        .drop_cnt ()
    );

    wire [539:0] spec_bars;             // 60 根柱 x 9 bit
    wire         spec_frame_done;

    spectrum #(
        .NBARS(60), .DW(25), .HW(9), .DECAY(6), .DB_OFFS(64), .SCALE_SH(2)
    ) u_spec (
        .clk        (clk_sys),
        .rst_n      (aud_rst_n),
        .in_valid   (fft_valid),
        .in_index   (fft_index),
        .in_mag     (fft_mag),
        .bar_flat   (spec_bars),
        .frame_done (spec_frame_done)
    );

    //=========================================================================
    // 6. UI 控制（扩展点 ②：按键 / 触摸 / UART 都写同一组寄存器）
    //    现在只接了按键；以后接 UART 或触摸屏时，再挂一个上游写同一个端口即可。
    //=========================================================================
    wire k1_press, k2_press;
    wire k1_state, k2_state;

    key_debounce #(.CLK_HZ(48_000_000), .MS(KEY_DB_MS)) u_key1 (
        .clk(clk_sys), .rst_n(rst_sys_n), .key_n(key1_n),
        .key_pressed(k1_state), .press(k1_press)
    );

    key_debounce #(.CLK_HZ(48_000_000), .MS(KEY_DB_MS)) u_key2 (
        .clk(clk_sys), .rst_n(rst_sys_n), .key_n(key2_n),
        .key_pressed(k2_state), .press(k2_press)
    );

    //=========================================================================
    // 6a. 按键手势（P1-5）：把两个按键变成"四动作"
    //=========================================================================
    //   为什么需要：
    //     板子上只有两个键，但要表达四种动作，所以用"单击 vs 双击"区分。
    //     两者在按下的那一瞬间分不清，必须等一个窗口 —— 见 key_gesture.v 注释。
    //
    //   映射（用户定的）：
    //     KEY1 单击 = 光标左移      KEY1 双击 = 面板 开/关
    //     KEY2 单击 = 光标右移      KEY2 双击 = 确认
    //
    //   ⚠️ 原来 KEY1 绑的是"切视图"、KEY2 绑的是"轮换背景模式"，
    //      这两条遗留绑定在这里【一并去掉】，改由手势统一管理。
    //=========================================================================
    wire k1_single, k1_dbl, k2_single, k2_dbl;

    key_gesture #(.CLK_HZ(48_000_000), .WIN_MS(KEY_WIN_MS)) u_gest1 (
        .clk(clk_sys), .rst_n(rst_sys_n), .press(k1_press),
        .single(k1_single), .dbl(k1_dbl)
    );

    key_gesture #(.CLK_HZ(48_000_000), .WIN_MS(KEY_WIN_MS)) u_gest2 (
        .clk(clk_sys), .rst_n(rst_sys_n), .press(k2_press),
        .single(k2_single), .dbl(k2_dbl)
    );

    //-------------------------------------------------------------------------
    // 光标：0=VIEW 1=STYLE 2=HUE 3=GAIN 4=BG 5=DEMO 6=IN 7=SD
    //   顺序和 ui_layer 里按钮的排列一致，所以"光标右移"在视觉上就是往右走。
    //   首尾【环绕】：到 DEMO 再右移回到 VIEW，反之亦然（菜单的常规做法）。
    //-------------------------------------------------------------------------
    localparam [3:0] SEL_N   = 4'd8;    // 光标项数（3 位装不下 8）
    localparam [2:0] SEL_MAX = 3'd7;    // 最后一项（SD）
    // ⚠️ SEL_MAX 必须和 ui_layer 的 DISP_UI_NB 一致（NB-1）。
    //    这里漏改过一次：面板上明明画了 8 个按钮，但光标到第 7 个就环绕回去，
    //    于是"SD 按钮看得见却选不中"。
    //    这就是账本 251 说的"同一个语义出现两份映射必然漏改一份"——
    //    按钮个数在 disp_cfg.vh（DISP_UI_NB），项数在 top.v（SEL_N/SEL_MAX），
    //    两处必须同步。

    //-------------------------------------------------------------------------
    // 面板是否展开（从 clk_pix 域同步回来）
    //   按键只有在【看得见面板】时才有意义 —— 否则用户在盲选一个看不见的光标。
    //   KEY1 双击（开/关面板）是唯一【不受此约束】的动作，否则就打不开了。
    //-------------------------------------------------------------------------
    wire panel_open_pix;
    wire panel_open_sys;
    cdc_sync u_panel_sync (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .din(panel_open_pix), .dout(panel_open_sys)
    );
    wire keys_en = panel_open_sys;

    reg [2:0] sel_idx;
    always @(posedge clk_sys) begin
        if (!rst_sys_n)
            sel_idx <= 3'd0;
        else if (keys_en && k1_single)               // 左移（面板不在时无效）
            sel_idx <= (sel_idx == 3'd0) ? SEL_MAX : sel_idx - 1'b1;
        else if (keys_en && k2_single)               // 右移（面板不在时无效）
            sel_idx <= (sel_idx == SEL_MAX) ? 3'd0 : sel_idx + 1'b1;
    end
    // SEL_N 只用于注释里的说明，避免"声明了没用"——加一条显式引用

    //-------------------------------------------------------------------------
    // KEY1 双击 -> 面板开/关
    //   传【翻转标志】过去而不是脉冲：脉冲跨到 clk_pix 可能整个被漏掉。
    //-------------------------------------------------------------------------
    reg panel_tog;
    always @(posedge clk_sys) begin
        if (!rst_sys_n) panel_tog <= 1'b0;
        else if (k1_dbl) panel_tog <= ~panel_tog;
    end

    //-------------------------------------------------------------------------
    // 按键活动标志：任何一个手势动作都翻转一次
    //   用途：让"面板空闲自动收起"的计时器在用户按键时重置。
    //   同样传翻转标志（脉冲跨到 clk_pix 会被漏掉）。
    //-------------------------------------------------------------------------
    wire key_act = k1_single | k1_dbl | k2_single | k2_dbl;
    reg  key_act_tog;
    always @(posedge clk_sys) begin
        if (!rst_sys_n) key_act_tog <= 1'b0;
        else if (key_act) key_act_tog <= ~key_act_tog;
    end

    //-------------------------------------------------------------------------
    // 光标 -> 按钮动作码
    //   ui_layer 里的映射是：按钮 0..4 的动作码就是 0..4，第 6 个（DEMO）是 6。
    //   所以这里把光标 5 映成 6，其余照抄。送过去当"高亮项"，
    //   复用它本来就有的 is_active 方框高亮。
    //-------------------------------------------------------------------------
    //   映射：光标 0..4 -> 动作码 0..4（VIEW..BG）
    //         光标 5   -> 4'h6（DEMO 按钮）
    //         光标 6   -> 4'h7（IN 按钮）
    wire [3:0] ui_sel_act = (sel_idx == 3'd7) ? 4'h8 :
                            (sel_idx == 3'd6) ? 4'h7 :
                            (sel_idx == 3'd5) ? 4'h6 : {1'b0, sel_idx};

    //-------------------------------------------------------------------------
    // KEY2 双击 -> 确认：执行光标所在项
    //   和触摸的语义【完全一致】：VIEW 走 next_view，其它走 step_en+地址。
    //   ⟹ 顺手把 ui_ctrl 那条现成的通路复用了，下游一行都不用改。
    //-------------------------------------------------------------------------
    //   同样受 keys_en 约束：面板不在眼前时的"确认"没有意义。
    wire key_view = k2_dbl & keys_en & (sel_idx == 3'd0);
    wire key_step = k2_dbl & keys_en & (sel_idx != 3'd0);

    //=========================================================================
    // 6b. UART 命令通道（PC 串口 -> 改任意配置寄存器）
    //=========================================================================
    wire [7:0] uart_rx_data;
    wire       uart_rx_valid;
    wire       uart_rx_ferr;

    uart_rx #(.CLK_HZ(48_000_000), .BAUD(115200)) u_uart_rx (
        .clk(clk_sys), .rst_n(rst_sys_n), .rx(uart_rx_pin),
        .data(uart_rx_data), .valid(uart_rx_valid), .ferr(uart_rx_ferr)
    );

    wire [7:0] uart_tx_data;
    wire       uart_tx_send;
    wire       uart_tx_busy;
    wire       uart_wr_en;
    wire [3:0] uart_wr_addr;
    wire [7:0] uart_wr_data;

    // ui_ctrl 的配置输出（声明必须在使用之前 —— Verilog 不允许先用后声明）
    wire [7:0] ui_view, ui_style, ui_hue_spd, ui_wave_gain, ui_bg_mode, ui_auto, ui_demo;
    wire [7:0] ui_src;
    wire [7:0] ui_img_idx;              // SD 背景图序号（面板 SD 键 / UART 4'h8）
    wire       ui_bg_src;               // 背景来源：0=程序化(BG键) 1=SD图片(SD键)
    // SD 卡前 8 字节拼成 64 位，给状态行显示。
    //   ⚠️ 必须在【第一次使用之前】声明：disp_top 的例化在前面，
    //      否则 Vivado 会按 1 位隐式声明，然后报 [Synth 8-992]
    //      "already implicitly declared earlier"，显示出来是垃圾。
    wire [63:0] sd_dbg_q;

    // ⚠️ 下面这几个必须在【第一次使用之前】声明：
    //   disp_top 的例化在前面（LCD 那一路要读帧缓冲），
    //   而它们的原声明在后面的 SD 段里 ⟹ Vivado 会按 1 位隐式声明，
    //   然后报一串 [Synth 8-992] "already implicitly declared earlier"。
    //   这次一次踩了 3 个（fb_rd_data / fb_rd_addr / sd_rd_count）。
    wire [15:0] fb_rd_data;             // 帧缓冲读出的 RGB565
    wire [18:0] fb_rd_addr;             // 帧缓冲读地址（由 disp_top 产生）
    reg  [15:0] sd_rd_count;            // 本轮已读到的字节数
    wire [18:0] load_pix_cnt;           // 已搬进帧缓冲的像素数（sd_img_load）
    // ui_src = 输入源（0=话筒 1=线路），UART 命令 I 写 ui_ctrl 的 4'h7
    assign src_sel = ui_src[0];         // 只取最低位（ui_ctrl 那边已经限过 1 位）
    wire [3:0] ui_view_idx;

    cmd_proc u_cmd (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .rx_data(uart_rx_data), .rx_valid(uart_rx_valid),
        .tx_data(uart_tx_data), .tx_send(uart_tx_send), .tx_busy(uart_tx_busy),
        // 回读：直接接 ui_ctrl 的输出（组合读，不会成环 ——
        // ui_ctrl 的输出只由它内部的寄存器驱动，不依赖 cmd_proc）
        .cfg_view(ui_view), .cfg_style(ui_style), .cfg_hue_spd(ui_hue_spd),
        .cfg_wave_gain(ui_wave_gain), .cfg_bg_mode(ui_bg_mode),
        .cfg_auto(ui_auto),
        .wr_en(uart_wr_en), .wr_addr(uart_wr_addr), .wr_data(uart_wr_data)
    );

    uart_tx #(.CLK_HZ(48_000_000), .BAUD(115200)) u_uart_tx (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .send(uart_tx_send), .data(uart_tx_data),
        .tx(uart_tx_pin), .busy(uart_tx_busy)
    );

    //=========================================================================
    // 6b-1. 触摸按钮的网络声明
    //-----------------------------------------------------------------------------
    //   【为什么要单独提前声明】
    //     这里有个环：ui_ctrl 需要"哪个按钮被按了"，而按钮来自 disp_top，
    //     disp_top 又需要 ui_ctrl 输出的配置。Verilog【没有前置声明】，
    //     所以只能把【导线声明】提前、【驱动它的逻辑】放到后面。
    //
    //   ⚠️ 不提前声明的话，`ui_btn_act` 会被当成【隐式 1 位网络】——
    //     既不报错也不连到 disp_top 的端口上，功能静默失效。
    //     （最初就是这么错的，iverilog 只报了一句 implicit definition 的警告。）
    //=========================================================================
    wire [3:0] ui_btn_act;      // disp_top 输出：当前按着的按钮动作码
    wire [3:0] btn_act_s;       // 同步到 clk_sys 之后的动作码
    wire       btn_press_s;     // clk_sys 域的一次"按下"事件（单拍）

    //=========================================================================
    // 6c. 写端口仲裁：按键 / UART **汇到同一条总线**
    //     这就是扩展点②真正落地的地方 —— 显示链完全不知道是谁改的。
    //     优先级：按键 > UART（人的即时操作优先，UART 少写一次无所谓）
    //=========================================================================
    //   （原来这里还有一条"KEY2 单击 -> 轮换背景模式"的通路，
    //     已随手势改造删除：BG 现在由"光标移到 BG + 双击确认"来操作。）

    wire        ui_wr_en   = uart_wr_en;
    wire [3:0]  ui_wr_addr = uart_wr_addr;
    wire [7:0]  ui_wr_data = uart_wr_data;

    //=========================================================================
    // 6c-2. 触摸按钮 -> 配置（P1-1 工控屏）
    //-----------------------------------------------------------------------------
    // disp_top 已经给出"按下那一拍"的脉冲（ui_btn_press）和动作码（ui_btn_act），
    // 这里只做分流：
    //   VIEW 按钮 -> next_view 脉冲（和 KEY1 完全同一个动作）
    //   其它按钮  -> step_en + 地址（让 ui_ctrl 自己按字段的有效范围递增）
    //
    // 优先级：触摸按钮 > 按键 > UART（屏幕上的是用户刚点的，最"新"）
    //=========================================================================
    wire btn_view = btn_press_s & (btn_act_s == 4'h0);
    wire btn_step = btn_press_s & (btn_act_s != 4'h0) & (btn_act_s != 4'hF);

    ui_ctrl u_ui (
        .clk           (clk_sys),
        .rst_n         (rst_sys_n),
        .wr_en         (ui_wr_en),
        .wr_addr       (ui_wr_addr),
        .wr_data       (ui_wr_data),
        //   VIEW：光标在 VIEW 时"确认"= 切视图（和触摸的 VIEW 按钮同一动作）
        //   其它：光标选中哪一项，就让 ui_ctrl 按该字段的有效范围 +1
        //   优先级：触摸 > 按键（屏幕上的是用户刚点的，最"新"）
        .next_view     (key_view | btn_view),
        .step_en       (key_step | btn_step),
        // ⚠️⚠️ 【这里原来有个"差一格"的映射 bug】
        //   光标是 0..6（VIEW/STYLE/HUE/GAIN/BG/DEMO/IN），
        //   而 ui_ctrl 的动作码不是光标值：DEMO 是 4'h6、IN 是 4'h7（中间跳过了 5）。
        //   原来这里直接送 {1'b0, sel_idx}，于是：
        //     光标 5(DEMO) -> 送 4'h5 -> ui_ctrl 没这个分支（4'h5 是 cfg_auto，只给 UART）-> 毫无反应
        //     光标 6(IN)   -> 送 4'h6 -> ui_ctrl 的 cfg_demo -> 按下 IN 却在切演示图案
        //   修法：用和高亮【同一个】映射 ui_sel_act，两边永远一致。
        .step_addr     (btn_step ? btn_act_s : ui_sel_act),
        .cfg_view      (ui_view),
        .cfg_style     (ui_style),
        .cfg_hue_spd   (ui_hue_spd),
        .cfg_wave_gain (ui_wave_gain),
        .cfg_bg_mode   (ui_bg_mode),
        .cfg_auto      (ui_auto),
        .cfg_demo      (ui_demo),
        .cfg_src       (ui_src),           // 输入源：UART 命令 I 写 4'h7
        .cfg_img_idx   (ui_img_idx),       // SD 切图：面板 SD 按钮写 4'h8
        .cfg_bg_src    (ui_bg_src),        // 背景来源：BG 键 ⟹ 0，SD 键 ⟹ 1
        .view_idx      (ui_view_idx)
    );

    //=========================================================================
    // 6d. 演示 / 自检图案（P1-4）
    //     为什么需要：没有音频模块时，柱状/极坐标/波形全是空的，
    //     连“S / H / G 三条命令有没有生效”都判断不了，显示链在硬件上
    //     一直是零观察。这个模块合成一路假数据顶上。
    //
    //     T00（上电默认）时它被【完全旁路】—— 两个 mux 都选真实通路，
    //     对音频链路零影响。
    //
    //     两条通路各挂一个 2:1 mux，而不是去改 spectrum / audio_top：
    //       频谱：spectrum.bar_flat / .frame_done   vs  demo.bar_flat / .bar_wr
    //       波形：audio_top.rx_l / .rx_valid          vs  demo.wave_din / .wave_we
    //     这样【真实模块一行不改】，不会因为加了个测试功能把主链路弄坏。
    //=========================================================================
    wire [539:0]       demo_bars;
    wire               demo_wr;
    wire signed [23:0] demo_wave;
    wire               demo_wave_we;

    //=========================================================================
    // 6c-2. DAC 测试音（验证 I2C / I2S / 时钟的"整条 codec 链路"）
    //-----------------------------------------------------------------------------
    //   【为什么需要这个】ADC 读回来是 -90dBFS 的"数字静音"，
    //   这说明 WM8960 的 ADC 根本没在转换。可能的原因只有两类：
    //     ① I2C 配置没生效（或 PLL/SYSCLK 不对）
    //     ② 模拟输入侧的问题
    //   而这两类的【分界线】就是：往 DAC 送一个已知的音，看能不能听到。
    //
    //     听得到 -> I2C ✓ I2S ✓ 时钟 ✓ 全是好的 -> 问题纯在模拟输入侧
    //     听不到 -> 配置/时钟是坏的
    //
    //   【怎么产生】不加新模块 —— 直接复用已经逐位验证过的 i2s_tx，
    //   用它需要的时序信号 audio_top 早就通过 dbg_* 导出来了。
    //   音频数据用 1 kHz 三角波（48kHz / 48 = 1000Hz），幅度约 75% 满量程。
    //
    //   【怎么开】UART 敲 T08（ui_demo[3]=1）；T00 关掉。
    // =========================================================================
    reg  [5:0]        tone_ph;
    reg  signed [23:0] tone_val;

    wire signed [6:0] tph7 = {1'b0, tone_ph};
    // 三角波：ph 0..47 -> 值 -12..+11..-12（一个完整周期）
    wire signed [6:0] tri7 = (tph7 < 7'sd24) ? (tph7 - 7'sd12) : (7'sd35 - tph7);
    wire signed [25:0] tsh = tri7 <<< 19;          // 约 ±0.75 满量程

    always @(posedge clk_sys) begin
        if (!rst_sys_n) begin
            tone_ph  <= 6'd0;
            tone_val <= 24'sd0;
        end else if (dbg_frame_start) begin       // 每帧一个采样 = 48 kHz
            tone_ph  <= (tone_ph == 6'd47) ? 6'd0 : tone_ph + 1'b1;
            tone_val <= tsh[23:0];
        end
    end

    wire dacdat_tone;
    wire tone_on = ui_demo[3];

    i2s_tx #(.SLOT(32), .DATA_BITS(24), .DW(24)) u_tone_tx (
        .clk         (clk_sys),
        .rst_n       (rst_sys_n),
        .bclk_fall   (dbg_bclk_fall),
        .frame_start (dbg_frame_start),
        .bit_idx     (dbg_bit_idx),
        .l_data      (tone_val),
        .r_data      (tone_val),
        .data_en     (1'b1),
        .sdout       (dacdat_tone)
    );

    // 测试音打开时接管 DACDAT，否则走正常音频
    assign aud_dacdat = tone_on ? dacdat_tone : dacdat_audio;

    wire demo_on = (ui_demo[1:0] != 2'd0);

    demo_src #(
        .NBARS(60), .HW(9), .DW(24)
    ) u_demo (
        .clk      (clk_sys),
        .rst_n    (rst_sys_n),
        .mode     (ui_demo[1:0]),
        .bar_flat (demo_bars),
        .bar_wr   (demo_wr),
        .wave_din (demo_wave),
        .wave_we  (demo_wave_we)
    );

    //=========================================================================
    // 6d-3. 波形平滑 FIR（线性相位低通，15 抽头）
    //-----------------------------------------------------------------------------
    //   【为什么需要】触发靠的是"向上过零"，而过零点附近的噪声会让每次
    //   触发的时刻抖一下 —— "画面静止"就变成了"画面在抖"。
    //   低通把过零点磨平，抖动就小了。
    //
    //   【为什么是"线性相位"（系数对称）】非线性相位会让不同频率的分量错开
    //   不同的时间，波形【形状会被扭歪】。对称 FIR 等价于整体延迟 7 个采样，
    //   形状不失真。0.15 ms 的延迟对显示毫无影响。
    //
    //   【为什么全并行】48 kHz 采样、48 MHz 时钟 -> 一个采样周期有 1000 拍。
    //   串行复用 1 个乘法器当然更省，但要写状态机 + RAM 变址，复杂度和
    //   出错概率高得多。全并行用 8 个 DSP48（共 240 个），换来纯组合、
    //   一眼看懂、没有跨拍问题 —— 对显示通路是明显划算的交易。
    //
    //   截止 5.76 kHz（-6 dB），20 kHz 处 -54.4 dB。系数见 fir_sym_coeff.vh。
    //=========================================================================
    wire signed [23:0] rx_l_fir;

    fir_sym #(.DW(24), .CF(16), .BYPASS(0)) u_fir (
        .clk   (clk_sys),
        .rst_n (rst_sys_n),
        .en    (rx_valid),
        .din   (rx_l_dc),
        .dout  (rx_l_fir)
    );

    wire [539:0]       spec_bars_sel = demo_on ? demo_bars    : spec_bars;
    wire               spec_wr_sel   = demo_on ? demo_wr      : spec_frame_done;
    wire signed [23:0] wave_din_sel  = demo_on ? demo_wave    : rx_l_fir;
    wire               wave_we_sel   = demo_on ? demo_wave_we : rx_valid;

    //=========================================================================
    // 6d-4. 自适应触发门限
    //-----------------------------------------------------------------------------
    //   wave_buf 的触发条件是"信号先低于 -TH 再向上过零"，而 TH 固定成
    //   满量程 1/64 有两个毛病：小信号永远碰不到 -TH（只能靠自动触发，
    //   画面一直跳）；大信号门限相对太小，噪声也能骗过迟滞。
    //   改成"门限 = 包络/8"两个问题一起解决。
    //
    //   ⚠️ 门限必须有【下限 TH_MIN】。静音时包络->0，门限也->0，
    //      此时"低于 -TH"退化成"小于 0"，一点底噪就能疯狂触发。
    //      这是自适应门限最典型的坑，env_track 里有 TH_MIN 兜底。
    //
    //   放在 FIR 【之后】：包络要跟踪的是"真正拿去显示的那个信号"。
    //   FIR 会把尖峰磨掉，放在前面的话包络会被单点毛刺顶高。
    //=========================================================================
    wire signed [23:0] wave_th;

    env_track #(.DW(24), .AS(6), .DS(12), .KP(3), .TH_MIN(4096)) u_env (
        .clk   (clk_sys),
        .rst_n (rst_sys_n),
        .en    (wave_we_sel),
        .din   (wave_din_sel),
        .th    (wave_th),
        .env   ()
    );


    //=========================================================================
    // 6e. 触摸屏（XPT2046，在 LCD 子卡上）
    //-----------------------------------------------------------------------------
    // 没有用中断脚（TP_nINT 那一路的 R12 是 NC 未焊，接不到），所以纯轮询。
    //
    // ⚠️ 轮询周期决定了"多短的触摸能被看到"：**周期必须小于按下持续时间**，
    //   否则会【稳定地漏掉某些按下】而不是偶尔漏。
    //   第一版取 10 ms，而演示扫描的"按下"只持续 6.4 ms ——
    //   两者相位固定，于是每次都是同样几个按钮被跳过（实测只有 STYLE 生效）。
    //   改成 5 ms：一次读 X+Y 约 48 us，占空比约 1%，仍然很低；
    //   而 5 ms 能覆盖住人手最短的轻点，演示扫描的 0.16 s 更是绰绰有余。
    //
    //   更彻底的方案是把"按下"做成【锁存】而不是电平（一次触摸不管多短都记住，
    //   上层处理完再清），那样对轮询周期完全免疫。留到正式标定时一起做。
    //=========================================================================
    localparam integer TP_PERIOD = 48_000_000 / 200;      // 5 ms

    reg [22:0] tp_cnt;
    reg        tp_go;
    wire       tp_busy, tp_valid;
    wire [11:0] tp_x, tp_y;
    wire [11:0] tp_edges;
    wire        tp_low;

    always @(posedge clk_sys) begin
        if (!rst_sys_n) begin
            tp_cnt <= 23'd0;
            tp_go  <= 1'b0;
        end else begin
            tp_go <= 1'b0;
            if (tp_cnt == TP_PERIOD - 1) begin
                tp_cnt <= 23'd0;
                tp_go  <= 1'b1;         // 单拍脉冲，启动一次读 X+Y
            end else begin
                tp_cnt <= tp_cnt + 1'b1;
            end
        end
    end

    xpt2046 #(.CLK_HZ(48_000_000), .SCLK_HZ(1_000_000)) u_touch (
        .clk     (clk_sys),
        .rst_n   (rst_sys_n),
        .start   (tp_go),
        .busy    (tp_busy),
        .valid   (tp_valid),
        .x_pos   (tp_x),
        .y_pos   (tp_y),
        .dbg_edges (tp_edges),              // 诊断：DOUT 跳变次数
        .dbg_low   (tp_low),                // 诊断：DOUT 见过低电平吗
        .tp_dclk (tp_dclk),
        .tp_cs_n (tp_cs_n),
        .tp_din  (tp_din),
        .tp_dout (tp_dout)
    );

    //=========================================================================
    // 7. 显示（含跨时钟域快照）
    //=========================================================================
    disp_top #(.ANIM_STEP(ANIM_STEP)) u_disp (
        .panel_tog  (panel_tog),            // KEY1 双击 -> 面板开/关
        .panel_open (panel_open_pix),       // 面板是否展开 -> 回 clk_sys 约束按键
        .key_act    (key_act_tog),          // 按键活动 -> 重置空闲计时
        .ui_sel     (ui_sel_act),           // 光标 -> 方框高亮
        .ui_btn_act (ui_btn_act),
        .ui_btn_press(),                    // 用不到：边沿在 clk_sys 侧重新做
        .clk_sys    (clk_sys),
        .rst_sys_n  (rst_sys_n),
        .spec_wr    (spec_wr_sel),
        .spec_din   (spec_bars_sel),
        .clk_pix    (clk_pix),
        .rst_pix_n  (rst_pix_n),
        .ui_mode    (ui_bg_mode[3:0]),      // 来自 ui_ctrl
        .ui_style   (ui_style[3:0]),
        .ui_view    (ui_view[2:0]),
        .ui_hue_spd (ui_hue_spd),
        .ui_wave_gain(ui_wave_gain),        // G 命令：波形增益（以前是死控件）
        .ui_demo    (ui_demo),              // T 命令：演示图案
        .tp_x       (tp_x),                 // 触摸原始读数（显示在状态行第二行）
        .tp_y       (tp_y),
        .tp_edges   (tp_edges),             // 诊断量（状态行第三行）
        .tp_low     (tp_low),
        .wave_din   (wave_din_sel),         // 波形显示左声道（或自检图案）
        .wave_th    (wave_th),              // 自适应触发门限（来自 env_track）
        // 诊断显示：状态行那一行 6 位十六进制 = {触摸X, 触摸Y}
        //   ⚠️ 原来接的是音频的原始 ADC（rx_l）—— 音频调好后就没用了，
        //      而触摸正需要"看见坐标"，所以换回触摸。
        //      拼成 24 位就能一次显示 X 和 Y（各 3 位十六进制）。
        // 诊断显示：现在换成【按键交互状态】
        //   ⚠️ 原来这里显示 {tp_x, tp_y}——但排查后确认这块屏【没有触摸层】，
        //      所以那两个值恒为 000，留着没意义。换成光标值：
        //      屏幕最后一行会显示 00000N（N = 光标 0..5），按 KEY1/KEY2 单击就能看到它动。
        // 诊断：这一行现在显示【SD 图序号 ui_img_idx】而不是光标值。
        //   为什么换：按 SD 键后那 16 个字节不变，有两种可能 ——
        //     ① 序号根本没加（ui_ctrl 的动作没到）
        //     ② 加了但没重新读
        //   把序号显示出来就能一次区分：
        //     序号变了 ⟹ ①OK，问题在读触发
        //     序号不变 ⟹ ①坏了，问题在按键/动作码
        // ★ 决定性诊断：这一行显示 {图序号, 读到的字节数}
        //     格式：NN HHHH  （图序号 2 位 + 字节数 4 位十六进制）
        //
        //   怎么判读：
        //     双击 SD 后
        //       · NN 加 1 ✓ HHHH 还是 01FF ⟹ 读是【完成】的
        //                                     ⟹ 问题在扇区地址没生效
        //       · NN 加 1 ✓ HHHH 变成 0000   ⟹ 读【启动了但没读到数据】
        //       · NN 加 1 ✓ HHHH 一直是 01FF 不变的旧值 ⟹ 读没启动
        //
        //   正常一次读：HHHH 会从 0000 一路涨到 01FF（=511），然后停住。
        // ★ 现在显示【已搬进帧缓冲的像素数】load_pix_cnt：
        //     000000  ⟹ 一个像素都没写（SD 数据没到 / sd_img_load 没启动）
        //     1FE00   ⟹ 130560，整帧写满 ✓
        //   比显示图序号更有用：图序号只说明"按键到了"，
        //   像素数才说明"数据真的搬进去了"。
        .dbg_adc    ({5'd0, load_pix_cnt}),
        .dbg_sd_bytes (sd_dbg_q),
        .cfg_bg_src (ui_bg_src),        // LCD：可用 SD 图片当背景
        .fb_rgb     (fb_rd_data),
        .fb_addr    (fb_rd_addr),
        .wave_we    (wave_we_sel),
        .lcd_rgb    (lcd_rgb),
        .lcd_hs     (lcd_hs),
        .lcd_vs     (lcd_vs),
        .lcd_de     (),                     // LCD 侧用不到（面板靠 hsync/vsync 定边界）
        .lcd_clk    (lcd_clk)
    );

    //=========================================================================
    // 8. 指示灯
    //=========================================================================
    reg [24:0] hb;

    always @(posedge clk_sys) begin
        if (!rst_sys_n)
            hb <= 25'd0;
        else
            hb <= hb + 1'b1;
    end

    //=========================================================================
    // SD 卡子系统
    //=========================================================================
    //   上电后先做 SD 初始化（200 kHz），完成后自动读一次【扇区 0】，
    //   把前 16 个字节抓进 sd_dbg_bytes，供后续显示/打印用。
    //
    //   ⚠️ 为什么先读扇区 0 而不是用户数据区：
    //      扇区 0 是 MBR/引导区，几乎任何卡都有内容 ⟹ 能区分
    //      "卡没插/没初始化"和"读流程有问题"两种情况：
    //        · sd_init_done = 0 ⟹ 卡没通
    //        · sd_init_done = 1 但 sd_rd_count < 512 ⟹ 命令通了、数据没通
    //        · sd_rd_count = 512 ⟹ 整条读通路 OK
    //=========================================================================
    wire        sd_init_done;
    wire        sd_rd_busy;
    wire        sd_rd_valid;
    wire [7:0]  sd_rd_data;
    reg         sd_rd_start;

    reg  [7:0]  sd_dbg_bytes [0:15]; // 前 16 个字节
    reg  [3:0]  sd_dbg_idx;

    // sd_dbg_bytes[0] 打在最左边
    assign sd_dbg_q = {sd_dbg_bytes[0], sd_dbg_bytes[1], sd_dbg_bytes[2], sd_dbg_bytes[3],
                       sd_dbg_bytes[4], sd_dbg_bytes[5], sd_dbg_bytes[6], sd_dbg_bytes[7]};

    reg         sd_rd_done;
    reg  [7:0]  sd_img_d;        // ui_img_idx 打拍，用来检测"用户切图"
    // 读请求的"重试看门狗"：
    //   如果发出 sd_rd_start 之后 sd_rd_done 长时间不拉高（实测发现卡可能
    //   不响应某条命令，而 sd_read 本身没有超时保护），就重新发一次请求。
    //   放在这里而不是改 sd_read —— sd_read 已经验证过 4/4，不想为一个
    //   边界情况去动它（账本：改已验证模块的代价往往高于在外面加保护）。
    reg  [23:0] sd_wdg;
    // 两次读之间的最小间隔：
    //   SD 规范要求一条命令结束后 CS 保持高电平 ≥8 个 SPI 时钟，
    //   卡才会接受下一条命令。sd_read 的 ST_DONE 只把 CS 拉高 1 个 sd_clk 周期
    //   ⟹ 紧接着发的下一次 CMD17 会被卡忽略（上板实测：第 1 次能读、
    //     第 2 次起 sr_rd_count 恒为 0）。
    //   这里读完成后强制等 GAP_CYC 个 clk_sys 周期才允许下一次触发。
    //   12 MHz 的 sd_clk ⟹ 8 拍 = 32 个 clk_sys；这里给到 512（约 10 us），
    //   余量充足且不影响体验（用户按一次键远慢于 10 us）。
    reg  [9:0]  sd_gap_q;
    // SD 子系统软复位：
    //   上板实测：上电后第一次读永远成功，之后无论怎么切图都读不到数据
    //   （sr_rd_count 恒 0），说明卡在一次完整事务之后就不再响应了。
    //   与其继续猜"第 2 次为什么不响应"，不如让每次切图都回到"刚上电"：
    //   给 sd_ctrl_top（连同 sd_init/sd_read）一个软复位脉冲，
    //   重新走一遍初始化 ⟹ 每次都是"第一次读" ⟹ 必然成功。
    //   代价：每次切图多花约 300 ms 初始化时间（可以接受）。
    reg  [3:0]  sd_srst_cnt;
    reg         sd_srst;
    // 切图检测做成【组合逻辑】：sd_img_d 是打拍后的值，两者不等就是刚切过。
    //   ⚠️ 不能在时序块里用 `=` 临时算它（Verilator 报 BLKSEQ，
    //      而且阻塞赋值和同块内的非阻塞赋值混用容易出意外）。
    wire        img_changed = (ui_img_idx != sd_img_d);

    sd_ctrl_top #(
        .CLK_HZ        (48_000_000),
        .FAST_DIV      (4),          // 12 MHz 读时钟
        .INIT_HZ       (200_000),
        .POWER_ON_NUM  (5000),
        .OVER_TIME_NUM (25000)
    ) u_sd (
        .clk         (clk_sys),
        // ⚠️ 用软复位：切图时把整个 SD 子系统复位，让它从"刚上电"开始
        .rst_n       (rst_sys_n & ~sd_srst),
        .sd_clk      (sd_clk),
        .sd_cs       (sd_cs),
        .sd_mosi     (sd_mosi),
        .sd_miso     (sd_miso),
        .rd_start    (sd_rd_start),
        // 第 N 张图占 512 个扇区（256 KB）。
        //   起始扇区 IMG_SECTOR_BASE 由 PC 端脚本决定（见 scripts/sdcard/mkimage.py），
        //   这里留成参数，方便和脚本对齐。
        .rd_sec_addr (IMG_SECTOR_BASE + ({24'd0, ui_img_idx} << 9)),
        .rd_busy     (sd_rd_busy),
        .rd_valid    (sd_rd_valid),
        .rd_data     (sd_rd_data),
        .init_done   (sd_init_done)
    );

    // 初始化完成后发一次读请求（单拍脉冲）
    // 【注意】所有 sd_rd_* 寄存器必须在【同一个 always 块】里驱动。
    //   我第一版把它们分到两个块里，结果 Verilator 报 MULTIDRIVEN（多驱动）——
    //   综合器会只保留其中一个，行为完全不可预测。
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            sd_rd_start <= 1'b0;
            sd_rd_done  <= 1'b0;
            sd_rd_count <= 16'd0;
            sd_dbg_idx  <= 4'd0;
            sd_img_d    <= 8'd0;
            sd_wdg      <= 24'd0;
            sd_gap_q    <= 10'd0;
            sd_srst_cnt <= 4'd0;
            sd_srst     <= 1'b0;
        end else begin
            // img_changed 是一个单拍脉冲 ⟹ 拉长成 8 拍的复位窗
            if (img_changed) begin
                sd_srst_cnt <= 4'd15;
                sd_srst     <= 1'b1;
            end else if (sd_srst_cnt != 4'd0) begin
                sd_srst_cnt <= sd_srst_cnt - 4'd1;
                sd_srst     <= 1'b1;
            end else begin
                sd_srst     <= 1'b0;
            end

            sd_img_d <= ui_img_idx;

            // 用户切图（面板 SD 按钮 / UART 4'h8）⟹ 重新来一轮读
            //
            // ⚠️ 这里必须和下面的"③ 收满 512 ⟹ 完成"互斥！
            //    第一版两个 if 是并列的，而 ③ 判断用的是【清零之前】的
            //    sd_rd_count（还是 511）⟹ ③ 又把 sd_rd_done 置回 1
            //    ⟹ 标志永远清不掉 ⟹ 按 SD 键不会重新读（现象：16 位数不变）。
            //    账本 215：并列的两个 if 写同一个寄存器，后写的赢。
            if (img_changed) begin
                sd_rd_done  <= 1'b0;
                sd_rd_count <= 16'd0;
                sd_dbg_idx  <= 4'd0;
                sd_rd_start <= 1'b0;
                sd_wdg      <= 24'd0;
            end

            // 看门狗：没读到数据时一直计数，超时就把"已完成"清掉 ⟹ 重新发请求
            //   阈值取 24'hFFFFFF 太大（48MHz 下约 350 ms），这里用 2^21
            //   ≈ 44 ms，比一次正常读（512 字节 @12MHz ≈ 3.4 ms）宽得多。
            if (sd_rd_done)
                sd_wdg <= 24'd0;
            else if (sd_wdg != 24'h1FFFFF)
                sd_wdg <= sd_wdg + 24'd1;
            else begin
                // 超时 ⟹ 强制重来
                sd_rd_done  <= 1'b0;
                sd_rd_count <= 16'd0;
                sd_dbg_idx  <= 4'd0;
                sd_wdg      <= 24'd0;
            end

            // ①-b 读完成后的最小间隔计数（CS 高电平保持时间）
            if (sd_rd_done)
                sd_gap_q <= 10'd0;
            else if (sd_gap_q != 10'h3FF)
                sd_gap_q <= sd_gap_q + 10'd1;

            // ① 初始化完成后发一次读请求（1 拍脉冲）
            //    ⚠️ 用 sd_gap_q 作为门控：只在"距上次读完成已过足够时间"才允许
            //    sd_ctrl_top 内部会把"脉冲"转成"翻转+双打+边沿检测"来跨时钟域
            if (sd_init_done && !sd_rd_done && !sd_rd_busy && !sd_rd_start &&
                (sd_gap_q == 10'h3FF))
                sd_rd_start <= 1'b1;
            else
                sd_rd_start <= 1'b0;

            // ② 收集读到的字节：前 16 个存下来，同时数总个数
            if (sd_rd_valid) begin
                // sd_dbg_idx 是 4 位 ⟹ 天然 ≤ 15，不用再判
                sd_dbg_bytes[sd_dbg_idx] <= sd_rd_data;
                if (sd_dbg_idx != 4'd15)
                    sd_dbg_idx <= sd_dbg_idx + 4'd1;
                if (sd_rd_count != 16'd511)
                    sd_rd_count <= sd_rd_count + 16'd1;
            end

            // ③ 收满 512 个 ⟹ 本次读完成（和上面的"切图清零"互斥）
            if (!img_changed && (sd_rd_count == 16'd511))
                sd_rd_done <= 1'b1;
        end
    end

    //=========================================================================
    // SD 图片搬运：SD 字节流 -> RGB565 像素 -> 帧缓冲
    //=========================================================================
    //   数据流：
    //     sd_ctrl_top (rd_valid/rd_data, 8 位)
    //        ⟹ sd_img_load (两字节凑一像素，小端)
    //        ⟹ frame_buf   (480x272x16 双口 BRAM，写口在 clk_sys)
    //
    //   ⚠️ 显示端还没接（下一步）。这一步只保证【数据能正确搬进帧缓冲】，
    //      可以用综合+后续的 TB 验证，不会影响现有画面。
    //=========================================================================
    wire        load_wr_en;
    wire [18:0] load_wr_addr;
    wire [15:0] load_wr_data;
    wire        load_done;

    // 切图时给搬运器一个 start 脉冲，清掉计数重新搬
    reg         load_start;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n)
            load_start <= 1'b0;
        else
            load_start <= img_changed;     // img_changed 是 1 拍脉冲
    end

    sd_img_load #(.W(480), .H(272)) u_img_load (
        .clk        (clk_sys),
        .rst_n      (rst_sys_n),
        .start      (load_start),
        .byte_valid (sd_rd_valid),
        .byte_data  (sd_rd_data),
        .wr_en      (load_wr_en),
        .wr_addr    (load_wr_addr),
        .wr_data    (load_wr_data),
        .done       (load_done),
        .pix_cnt    (load_pix_cnt)
    );

    // 帧缓冲：写口在这里，读口留给显示端（下一步接）


    frame_buf #(.W(480), .H(272)) u_fb (
        .wr_clk  (clk_sys),
        .wr_en   (load_wr_en),
        .wr_addr (load_wr_addr),
        .wr_data (load_wr_data),
        .rd_clk  (clk_pix),
        .rd_addr (fb_rd_addr),
        .rd_data (fb_rd_data)
    );

    assign led[0] = init_done;          // 常亮 = WM8960 配置完成
    assign led[1] = hb[23];             // 约 2.9 Hz 心跳

    //=========================================================================
    // 6b-0. 触摸按钮的跨时钟域（从 clk_pix 送回 clk_sys）
    //-----------------------------------------------------------------------------
    //   注意 CDC 要【放在使用之前】—— Verilog 不允许先用后声明。
    //
    //   ui_btn_press 是 clk_pix 域的【单拍脉冲】，直接过两级同步器会：
    //     · 宽了或窄了都有风险（pulse 同步必须用展宽/握手或边沿编码）
    //     这里用最省事又安全的办法：在 clk_sys 侧对【电平】做边沿检测。
    //     也就是把 ui_btn_act 同步过来，再看"按下的按钮编号变了"当作一次按下 ——
    //     因为每次按下都会让 act 变化（松开时变成 0xF）。
    //     代价是同一按钮连按两次要靠 0xF 的中间态区分，本工程够用。
    //=========================================================================
    reg [3:0] btn_act_d;

    cdc_sync #(.WIDTH(4), .RESET_VAL(4'hF)) u_sync_bact (
        .clk(clk_sys), .rst_n(rst_sys_n), .din(ui_btn_act), .dout(btn_act_s));

    always @(posedge clk_sys) begin
        if (!rst_sys_n) btn_act_d <= 4'hF;
        else            btn_act_d <= btn_act_s;
    end

    // 从"没按"变成"按了某个按钮" -> 一次按下事件
    assign btn_press_s = (btn_act_d == 4'hF) && (btn_act_s != 4'hF);


    //=========================================================================
    // 9. HDMI 输出（第二路显示：800x600@60 + 大屏布局）
    //=========================================================================
    //   【架构：两个 disp_top 各自独立】
    //     · LCD 那一路（480x272 @12.5MHz）—— 一行不改
    //     · HDMI 那一路（800x600 @40MHz）—— 新例化一个，参数全部换成大屏值
    //   ⟹ 哪一路出问题都不影响另一路；大屏布局也能独立调。
    //
    //   【为什么不用"一个 disp_top 输出两路"】
    //     disp_top 里自带 lcd_timing，输出的像素流带着自己的节拍（12.5MHz）。
    //     要送到 40MHz 的 800x600 画布上，就得做帧缓冲/跨时钟域 ——
    //     那要动 spec_sync/wave_buf/ui_* 整条链，风险和收益不成比例。
    //     资源翻倍（约 7200 -> 13000 LUT，11% -> 20%）完全不是瓶颈。
    //
    //   【大屏布局参数：先按约 1.5~2 倍放，之后看实际效果再调】
    //     柱状  NBARS 保持 60 —— 注意【不能】改成 100：
    //           spec_din 的宽度是 NBARS*HW 位，而频谱上游（spectrum_map）
    //           固定只产生 60 根柱（540 位）。改成 100 会让端口宽度不匹配
    //           （iverilog 会报 "Port spec_din expects 900 bits, given 540"）。
    //           大屏上 60 根柱自然变宽（800/60 ≈ 13px/柱），观感反而更好。
    //     极坐标 圆心 (240,78)->(400,170)，半径 16/62 -> 24/92
    //     波形 中轴 136->300，振幅 40->60
    //     面板 底边 234->540，按钮 66x38 -> 106x48
    //     把手 448/124 -> 768/288
    //=========================================================================
    // ⚠️ 先声明再使用（Verilog-2001 硬约束）：
    //    rst_hdmi_n 给 HDMI 那一路的 disp_top 和 hdmi_top 用。
    wire        rst_hdmi_n;
    wire [23:0] hdmi_rgb;
    wire        hdmi_hs, hdmi_vs, hdmi_de;

    rst_sync u_rst_hdmi (
        .clk         (clk_hdmi),
        .rst_async_n (rst_sys_n),
        .rst_n       (rst_hdmi_n)
    );

    //-------------------------------------------------------------------------
    // 从 clk_sys 域跨到 clk_hdmi 域的三个信号 —— 必须同步
    //-----------------------------------------------------------------------------
    //   【为什么必须同步】
    //     HDMI 那一路的 disp_top 跑在 clk_hdmi(25MHz)，而这三个信号都来自
    //     clk_sys(48MHz)。直接接过去就是【异步跨域】：
    //       · ui_sel_act（4 位电平）—— 位之间可能不同步变化，读到的可能是乱码值
    //       · panel_tog / key_act（翻转标志）—— 也可能采到亚稳态
    //     实测证据：加了 -timing_summary 之后 Vivado 直接报
    //       Slack (VIOLATED) -3.135ns：sel_idx_reg -> u_disp_hdmi/u_status/cnt_reg
    //     它把这条路径当成同步路径去算，算了 3 个时钟周期的账，自然算不过。
    //   ⟹ 正确做法就是两级同步器（cdc_sync），工具也就不会再按同步路径去约束它。
    //-------------------------------------------------------------------------
    wire [3:0] ui_sel_hdmi;
    wire       panel_tog_hdmi;
    wire       key_act_hdmi;

    cdc_sync #(.WIDTH(4)) u_cdc_sel (
        .clk(clk_hdmi), .rst_n(rst_hdmi_n),
        .din(ui_sel_act), .dout(ui_sel_hdmi)
    );

    cdc_sync #(.WIDTH(1)) u_cdc_ptog (
        .clk(clk_hdmi), .rst_n(rst_hdmi_n),
        .din(panel_tog), .dout(panel_tog_hdmi)
    );

    cdc_sync #(.WIDTH(1)) u_cdc_kact (
        .clk(clk_hdmi), .rst_n(rst_hdmi_n),
        .din(key_act_tog), .dout(key_act_hdmi)
    );

    disp_top #(
        .ANIM_STEP  (ANIM_STEP),
        //-------------------------------------------------------------------------
        // 大屏布局：640x360@60（16:9）。
        //
        // ⚠️ 为什么是 640x360 而不是 800x600 或 1280x720：
        //    disp_top 的关键路径 26.9 ns（46 级逻辑，60 根柱的优先级选择链）。
        //    800x600@60 要 40 MHz ⟹ 25 ns 预算 ⟹ 时序违例 -1.9 ns（实测）。
        //    640x480@60 只要 25 MHz ⟹ 40 ns 预算 ⟹ 余量 13 ns ✓
        //    想上更高分辨率必须先改架构（帧缓冲 + 整数倍放大），不是调参数。
        //
        // ⚠️ NBARS 必须保持 60：spec_din 的宽度是 NBARS*HW 位，
        //    而频谱上游（spectrum_map）固定只产生 60 根柱。改大端口就对不上了。
        //-------------------------------------------------------------------------
        .PIX_HZ     (25_000_000),       // 这一路跑 clk_hdmi = 25MHz（空闲计时要用）
        .HDISP      (640),
        .VDISP      (360),              // 16:9（640/360 = 16/9），铺满现代显示器
        // V 消隐凑够 25MHz：800 x (360+3+6+152) x 60 = 25.01 MHz
        //   （H 的消隐沿用默认 640x480 那套：24/40/96 ⟹ 总宽 800）
        .V_FRONT    (3),
        .V_SYNC     (6),
        .V_BACK     (152),
        .NBARS      (60),
        // 布局按 480x272 横向 x1.33、纵向 x(360/272)=1.32 重算
        .BARS_Y0    (15),
        .BARS_H     (255),
        .BAR_GAP    (2),
        .POL_CX     (320),
        .POL_CY     (78),
        .POL_RIN    (16),
        .POL_RMAX   (62),
        .WAVE_CY    (180),
        .WAVE_AMP   (40),
        .UI_BY0     (312),              // 360 - 48
        .UI_BW      (88),               // 7x88 + 6x2 = 628 <= 640 ✓
        .UI_BH      (48),
        .UI_GAP     (2),
        .TAB_X      (622),
        .TAB_Y      (168),              // 360/2 - 12
        .TAB_W      (16),
        .TAB_H      (24)
    ) u_disp_hdmi (
        .panel_tog  (panel_tog_hdmi),
        .panel_open (),
        .key_act    (key_act_hdmi),
        .ui_sel     (ui_sel_hdmi),
        .ui_btn_act (),
        .ui_btn_press(),
        .clk_sys    (clk_sys),
        .rst_sys_n  (rst_sys_n),
        .spec_wr    (spec_wr_sel),
        .spec_din   (spec_bars_sel),
        .clk_pix    (clk_hdmi),
        .rst_pix_n  (rst_hdmi_n),
        .ui_mode    (ui_bg_mode[3:0]),
        .ui_style   (ui_style[3:0]),
        .ui_view    (ui_view[2:0]),
        .ui_hue_spd (ui_hue_spd),
        .ui_wave_gain(ui_wave_gain),
        .ui_demo    (ui_demo),
        .tp_x       (tp_x),
        .tp_y       (tp_y),
        .tp_edges   (tp_edges),
        .tp_low     (tp_low),
        .wave_din   (wave_din_sel),
        .wave_th    (wave_th),
        // 诊断显示：大屏上用【同步后】的 ui_sel_hdmi，不能用 clk_sys 的 sel_idx。
        //   原来直接写 sel_idx ⟹ 又一条跨域路径（实测报 -3.134ns 违例）。
        .dbg_adc    ({20'd0, ui_sel_hdmi}),
        .dbg_sd_bytes (sd_dbg_q),
        .cfg_bg_src (1'b0),             // HDMI：暂用程序化背景（帧缓冲读口给 LCD）
        .fb_rgb     (16'd0),
        .fb_addr    (),
        .wave_we    (wave_we_sel),
        .lcd_rgb    (hdmi_rgb),
        .lcd_hs     (hdmi_hs),
        .lcd_vs     (hdmi_vs),
        .lcd_de     (hdmi_de),
        .lcd_clk    ()
    );

    hdmi_top u_hdmi (
        .rst_n      (rst_hdmi_n),
        .clk_hdmi   (clk_hdmi),
        .clk_5x     (clk_5x),
        .pix_rgb    (hdmi_rgb),
        .pix_de     (hdmi_de),
        .pix_hs     (hdmi_hs),
        .pix_vs     (hdmi_vs),
        .tmds_clk_p (hdmi_clk_p), .tmds_clk_n (hdmi_clk_n),
        .tmds_d0_p  (hdmi_d0_p),  .tmds_d0_n  (hdmi_d0_n),
        .tmds_d1_p  (hdmi_d1_p),  .tmds_d1_n  (hdmi_d1_n),
        .tmds_d2_p  (hdmi_d2_p),  .tmds_d2_n  (hdmi_d2_n),
        .hdmi_out_en(hdmi_out_en)
    );

    // hdmi_hpd 本版不参与逻辑：接进来但不使用
    wire _unused_hpd = hdmi_hpd;

endmodule
