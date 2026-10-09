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

    // 属性插值器每帧步进。默认 4 -> 32 帧 ≈ 384 ms 的过渡。
    //   暴露出来是为了让 testbench 能设成 128（一帧到位）：
    //   否则 TB 要等 384 ms 仿真时间才能看到操作面板开完，跑不动。
    parameter integer ANIM_STEP    = 4
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
    output wire [1:0]  led
);

    //=========================================================================
    // 1. 时钟生成（一个 MMCM 出 48 MHz + 12.5 MHz，VCO = 900 MHz）
    //=========================================================================
    wire clk_sys;                       // 48 MHz
    wire clk_pix;                       // 12.5 MHz
    wire mmcm_locked;

    clk_gen u_clkgen (
        .clk_200m_p  (clk_200m_p),
        .clk_200m_n  (clk_200m_n),
        .rst_btn_n   (rst_btn_n),
        .clk_sys     (clk_sys),
        .clk_pix     (clk_pix),
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

    always @(posedge clk_sys) begin
        if (!rst_sys_n) begin
            wait_cnt     <= 32'd0;
            init_go      <= 1'b0;
            init_started <= 1'b0;
        end else begin
            init_go <= 1'b0;                    // 默认拉低，只给一个脉冲
            if (!init_started) begin
                wait_cnt <= wait_cnt + 1'b1;
                if (wait_cnt >= WAIT_CYC) begin
                    init_go      <= 1'b1;
                    init_started <= 1'b1;
                end
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
    wire               rx_valid;

    audio_top #(
        .DW(24), .CW(18), .CF(16), .AW(48), .NSECT(5), .SLOT(32)
    ) u_audio (
        .clk        (clk_sys),
        .rst_n      (aud_rst_n),
        .bclk       (aud_bclk),
        .lrclk      (aud_lrclk),
        .sdin       (aud_adcdat),
        .sdout      (aud_dacdat),
        .band_gain  (25'd0),                // 全频段 0 dB（后续由 ui_ctrl 驱动）
        .cfg_load   (1'b0),
        .bypass     (1'b0),
        .cfg_busy   (),
        .running    (),
        .dbg_bclk_rise   (),
        .dbg_bclk_fall   (),
        .dbg_frame_start (),
        .dbg_half_start  (),
        .dbg_bit_idx     (),
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
        .x_in     (rx_l),
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

    key_debounce #(.CLK_HZ(48_000_000), .MS(20)) u_key1 (
        .clk(clk_sys), .rst_n(rst_sys_n), .key_n(key1_n),
        .key_pressed(k1_state), .press(k1_press)
    );

    key_debounce #(.CLK_HZ(48_000_000), .MS(20)) u_key2 (
        .clk(clk_sys), .rst_n(rst_sys_n), .key_n(key2_n),
        .key_pressed(k2_state), .press(k2_press)
    );

    // KEY2：轮换背景模式（0=网格 1=纯渐变）
    reg [3:0] bg_mode_r;
    always @(posedge clk_sys) begin
        if (!rst_sys_n)
            bg_mode_r <= 4'd0;
        else if (k2_press)
            bg_mode_r <= (bg_mode_r == 4'd1) ? 4'd0 : bg_mode_r + 1'b1;
    end

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
    wire [7:0] bg_next = {4'd0, (bg_mode_r == 4'd1) ? 4'd0 : bg_mode_r + 1'b1};

    wire        ui_wr_en   = k2_press | uart_wr_en;
    wire [3:0]  ui_wr_addr = k2_press ? 4'h4 : uart_wr_addr;
    wire [7:0]  ui_wr_data = k2_press ? bg_next : uart_wr_data;

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
        .next_view     (k1_press | btn_view),   // KEY1 或 VIEW 按钮
        .step_en       (btn_step),
        .step_addr     (btn_act_s),
        .cfg_view      (ui_view),
        .cfg_style     (ui_style),
        .cfg_hue_spd   (ui_hue_spd),
        .cfg_wave_gain (ui_wave_gain),
        .cfg_bg_mode   (ui_bg_mode),
        .cfg_auto      (ui_auto),
        .cfg_demo      (ui_demo),
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
    //     它要解决的问题只和波形显示有关，所以只给"波形"这一路做。
    //     插在 mux【之前】，演示图案（T01~T04）完全不受影响，
    //     而且 disp_top 一行都不用改 -> tb_disp_top 的参照模型也不用动。
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
        .wave_we    (wave_we_sel),
        .lcd_rgb    (lcd_rgb),
        .lcd_hs     (lcd_hs),
        .lcd_vs     (lcd_vs),
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


endmodule
