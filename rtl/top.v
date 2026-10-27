//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    top
// Module Name:    top
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    top.v - 整机顶层
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module top #(
    //----------------------- 仿真友好参数 -----------------------
    parameter integer INIT_WAIT_MS = 10,        // 复位释放后等多久再发 I2C
    parameter integer I2C_DLY_MS   = 1,         // I2C 每条寄存器之间的间隔

    parameter integer KEY_DB_MS    = 20,        // key_debounce 消抖
    parameter integer KEY_WIN_MS   = 300,       // key_gesture 双击判定窗

    parameter integer ANIM_STEP    = 4,

    // SD 背景图的存放起始扇区（每张图占 512 个扇区 = 256 KB）
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
    // XPT2046 电阻触摸屏
    output wire        tp_dclk,
    output wire        tp_cs_n,
    output wire        tp_din,
    input  wire        tp_dout,

    output wire [23:0] lcd_rgb,
    output wire        lcd_hs,
    output wire        lcd_vs,
    output wire        lcd_clk,

    //----------------------- LED 指示 -----------------------------
    output wire [1:0]  led,

    //----------------------- SD 卡（SPI 模式）------------------
    output wire        sd_clk,
    output wire        sd_cs,
    output wire        sd_mosi,
    input  wire        sd_miso,

    //--------------------- HDMI 输出 ---------------------
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
    input  wire        hdmi_hpd         // 热插拔检测（只进端口，不参与逻辑）
);

    //=========================================================================
    // 时钟生成（一个 MMCM 出 48 MHz + 12.5 MHz，VCO = 900 MHz）
    //=========================================================================
    wire clk_sys;                       // 48 MHz
    wire clk_pix;                       // 12.5 MHz
    wire clk_hdmi;                      // 40 MHz  —— HDMI 像素时钟
    wire clk_5x;                        // 200 MHz —— HDMI 串行化时钟
    wire mmcm_locked;

    //   clk_hdmi / clk_5x 供 hdmi_top 使用（40 MHz 像素钟 / 200 MHz 串行钟）
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
    // 复位同步：两个域各自同步一份，异步置位 / 同步释放
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
    // WM8960 上电配置：复位释放后等模块晶振稳定（10 ms）后再发 I2C
    //=========================================================================
    localparam integer WAIT_CYC = 48_000_000 / 1000 * INIT_WAIT_MS;

    reg  [31:0] wait_cnt;
    reg         init_go;
    reg         init_started;
    wire        init_done;

    //-------------------------------------------------------------------------
    // 音频输入源：0 = MIC（LINPUT1）  1 = 耳机（RINPUT3）
    //-------------------------------------------------------------------------
    wire        src_sel;
    reg         src_sel_d;
    wire        src_chg = (src_sel != src_sel_d);

    always @(posedge clk_sys) begin
        if (!rst_sys_n) begin
            wait_cnt     <= 32'd0;
            init_go      <= 1'b0;
            init_started <= 1'b0;
            src_sel_d    <= 1'b0;               // src_sel 由 ui_ctrl 复位（默认MIC）
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
                init_go <= 1'b1;                // 重写配置
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
        .src_sel   (src_sel),               // 0=话筒 1=线路输入
        .Init_Done (init_done),
        .i2c_sclk  (aud_scl),
        .i2c_sdat  (aud_sda)
    );

    //=========================================================================
    // 音频链路
    //    Init_Done 之前不放行 —— 配置过程中 BCLK/LRCLK 频率会变
    //=========================================================================
    wire aud_rst_n = rst_sys_n & init_done;

    wire signed [23:0] rx_l, rx_r;
    wire               dacdat_audio;
    wire               dbg_bclk_fall, dbg_frame_start;
    wire [5:0]         dbg_bit_idx;
    wire               rx_valid;

    // 直流阻断
    wire signed [23:0] rx_l_dc;

    wire signed [23:0] rx_mono = src_sel ? rx_r : rx_l;

    dc_block #(.DW(24), .SH(10), .GW(2)) u_dc_block (
        .clk   (clk_sys),
        .rst_n (rst_sys_n),
        .en    (rx_valid),          // 每个采样一个 strobe
        .din   (rx_mono),
        .dout  (rx_l_dc)
    );

    // 喇叭静音（面板 SPK 键 / UART 4'h1）
    wire       ui_spk_mute;

    audio_top #(
        .DW(24), .CW(18), .CF(16), .AW(48), .NSECT(5), .SLOT(32)
    ) u_audio (
        .clk        (clk_sys),
        .rst_n      (aud_rst_n),
        .mute       (ui_spk_mute),         // 喇叭静音：清零送 DAC 的数据
        .bclk       (aud_bclk),
        .lrclk      (aud_lrclk),
        .sdin       (aud_adcdat),
        .sdout      (dacdat_audio),
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
    // FFT + 频谱柱
    //=========================================================================
    wire [8:0]   fft_index;
    wire [24:0]  fft_mag;
    wire         fft_valid;

    fft_core #(
        .N(1024), .LOG2N(10), .DW(24), .TW(16), .FIFO_DEPTH(64)
    ) u_fft (
        .clk      (clk_sys),
        .rst_n    (aud_rst_n),
        .x_in     (rx_l_dc),          // 去直流后再送 FFT
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
        .NBARS(60), .DW(25), .HW(9), .DECAY(6), .DB_OFFS(56), .SCALE_SH(3)
    ) u_spec (
        .clk        (clk_sys),
        .rst_n      (aud_rst_n),
        .in_valid   (fft_valid),
        .in_index   (fft_index),
        .in_mag     (fft_mag),
        .bar_flat   (spec_bars),
        .frame_done (spec_frame_done)
    );

    wire [719:0] spec_bars80;           // 80 根 x 9 bit
    wire         spec_frame_done80;

    spectrum #(
        .NBARS(80), .DW(25), .HW(9), .DECAY(6), .DB_OFFS(56), .SCALE_SH(3)
    ) u_spec80 (
        .clk        (clk_sys),
        .rst_n      (aud_rst_n),
        .in_valid   (fft_valid),
        .in_index   (fft_index),
        .in_mag     (fft_mag),
        .bar_flat   (spec_bars80),
        .frame_done (spec_frame_done80)
    );

    //=========================================================================
    // UI 控制（按键 / 触摸 / UART 都写同一组寄存器）
    //=========================================================================
    // 按键消抖
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

    //-------------------------------------------------------------------------
    // 按键手势
    //   映射：
    //     KEY1 单击 = 光标左移      KEY1 双击 = 面板 开/关
    //     KEY2 单击 = 光标右移      KEY2 双击 = 确认
    //-------------------------------------------------------------------------
    wire k1_single, k1_dbl, k2_single, k2_dbl;

    key_gesture #(.CLK_HZ(48_000_000), .WIN_MS(KEY_WIN_MS)) u_gest1 (
        .clk(clk_sys), .rst_n(rst_sys_n), .press(k1_press),
        .single(k1_single), .dbl(k1_dbl)
    );

    key_gesture #(.CLK_HZ(48_000_000), .WIN_MS(KEY_WIN_MS)) u_gest2 (
        .clk(clk_sys), .rst_n(rst_sys_n), .press(k2_press),
        .single(k2_single), .dbl(k2_dbl)
    );

    // 光标：0=VIEW 1=STYLE 2=HUE 3=GAIN 4=BG 5=DEMO 6=IN 7=SD
    localparam [3:0] SEL_N   = 4'd8;    // 光标项数（3 位装不下 8）
    localparam [2:0] SEL_MAX = 3'd7;    // 最后一项（SD）

    // 面板是否展开（从 clk_pix 域同步）
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

    // KEY1 双击 -> 面板开/关
    reg panel_tog;
    always @(posedge clk_sys) begin
        if (!rst_sys_n) panel_tog <= 1'b0;
        else if (k1_dbl) panel_tog <= ~panel_tog;
    end

    // 按键活动标志
    wire key_act = k1_single | k1_dbl | k2_single | k2_dbl;
    reg  key_act_tog;
    always @(posedge clk_sys) begin
        if (!rst_sys_n) key_act_tog <= 1'b0;
        else if (key_act) key_act_tog <= ~key_act_tog;
    end

    // 光标 -> 按钮动作码
    //   映射：光标 0..4 -> 动作码 0..4（VIEW..BG）
    //         光标 5   -> 4'h6（DEMO 按钮）
    //         光标 6   -> 4'h7（IN 按钮）
    wire [3:0] ui_sel_act = (sel_idx == 3'd7) ? 4'h8 :
                            (sel_idx == 3'd6) ? 4'h7 :
                            (sel_idx == 3'd5) ? 4'h6 : {1'b0, sel_idx};

    // KEY2 双击 -> 确认：执行光标所在项
    wire key_view = k2_dbl & keys_en & (sel_idx == 3'd0);
    wire key_step = k2_dbl & keys_en & (sel_idx != 3'd0);

    //-------------------------------------------------------------------------
    // XPT2046 触摸屏（预留未使用）
    //-------------------------------------------------------------------------
    localparam integer TP_PERIOD = 48_000_000 / 200;      // 5 ms

    // 触摸按钮，提前声明
    wire [3:0] ui_btn_act;      // disp_top 输出：当前按着的按钮动作码
    wire [3:0] btn_act_s;       // 同步到 clk_sys 之后的动作码
    wire       btn_press_s;     // clk_sys 域的一次"按下"事件（单拍）

    reg [22:0] tp_cnt;
    reg        tp_go;
    wire       tp_busy, tp_valid;
    wire [11:0] tp_x, tp_y;

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
        .dbg_edges (),              // 诊断：DOUT 跳变次数
        .dbg_low   (),                // 诊断：DOUT 见过低电平吗
        .tp_dclk (tp_dclk),
        .tp_cs_n (tp_cs_n),
        .tp_din  (tp_din),
        .tp_dout (tp_dout)
    );

    //-------------------------------------------------------------------------
    // 触摸按钮的跨时钟域（从 clk_pix 送回 clk_sys）
    //-------------------------------------------------------------------------
    reg [3:0] btn_act_d;

    cdc_sync #(.WIDTH(4), .RESET_VAL(4'hF)) u_sync_bact (
        .clk(clk_sys), .rst_n(rst_sys_n), .din(ui_btn_act), .dout(btn_act_s));

    always @(posedge clk_sys) begin
        if (!rst_sys_n) btn_act_d <= 4'hF;
        else            btn_act_d <= btn_act_s;
    end

    // 从"没按"变成"按了某个按钮" -> 一次按下事件
    assign btn_press_s = (btn_act_d == 4'hF) && (btn_act_s != 4'hF);

    //-------------------------------------------------------------------------
    // UART 命令通道（PC 串口 -> 改任意配置寄存器）
    //-------------------------------------------------------------------------
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

    // ui_ctrl 的配置输出
    wire [7:0] ui_view, ui_style, ui_hue_spd, ui_wave_gain, ui_bg_mode, ui_auto, ui_demo;
    wire [7:0] ui_src;
    wire [7:0] ui_img_idx;              // SD 背景图序号（面板 SD 键 / UART 4'h8）
    wire       ui_bg_src;               // 背景来源：0=程序化(BG键) 1=SD图片(SD键)

    //-------------------------- 需提前声明 -----------------------------------
    // SD 卡前 8 字节拼成 64 位，给状态行显示
    wire [63:0] sd_dbg_q;

    wire [15:0] fb_rd_data;
    wire [18:0] fb_rd_addr_hdmi;
    wire [15:0] fb_rd_data_hdmi;
    wire        load_wr2_en;
    wire [18:0] load_wr2_addr;             // 帧缓冲读出的 RGB565
    wire [18:0] fb_rd_addr;             // 帧缓冲读地址（由 disp_top 产生）
    reg  [15:0] sd_rd_count;            // 本轮已读到的字节数
    wire [18:0] load_pix_cnt;           // 已搬进帧缓冲的像素数（sd_img_load）
    wire        load_done;              // 本帧已搬满（sd_img_load）
    //-------------------------------------------------------------------------
    // ui_src = 输入源（0=话筒 1=线路），UART 命令 I 写 ui_ctrl 的 4'h7
    assign src_sel = ui_src[0];         // 只取最低位
    wire [3:0] ui_view_idx;

    cmd_proc u_cmd (
        .clk(clk_sys), .rst_n(rst_sys_n),
        .rx_data(uart_rx_data), .rx_valid(uart_rx_valid),
        .tx_data(uart_tx_data), .tx_send(uart_tx_send), .tx_busy(uart_tx_busy),
        // 回读：直接接 ui_ctrl 的输出
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

    //-------------------------------------------------------------------------
    // 面板控制
    //-------------------------------------------------------------------------
    // 写端口仲裁，优先级：按键 > UART
    wire        ui_wr_en   = uart_wr_en;
    wire [3:0]  ui_wr_addr = uart_wr_addr;
    wire [7:0]  ui_wr_data = uart_wr_data;

    // 触摸按钮 -> 配置
    // 优先级：触摸按钮 > 按键 > UART
    wire btn_view = btn_press_s & (btn_act_s == 4'h0);
    wire btn_step = btn_press_s & (btn_act_s != 4'h0) & (btn_act_s != 4'hF);

    ui_ctrl u_ui (
        .clk           (clk_sys),
        .rst_n         (rst_sys_n),
        .wr_en         (ui_wr_en),
        .wr_addr       (ui_wr_addr),
        .wr_data       (ui_wr_data),
        // 触摸与按键同一动作，优先级：触摸 > 按键
        .next_view     (key_view | btn_view),
        .step_en       (key_step | btn_step),
        // 动作码与光标同步
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
        .cfg_bg_src    (ui_bg_src),        // 背景来源：BG 键->0，SD 键->1
        .cfg_spk_mute  (ui_spk_mute),      // 喇叭静音：面板 SPK 键
        .view_idx      (ui_view_idx)
    );

    //=========================================================================
    // DEMO 演示 / 自检图案
    //=========================================================================
    wire [539:0]       demo_bars;
    wire               demo_wr;
    wire signed [23:0] demo_wave;
    wire               demo_wave_we;
    // DAC 测试音
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
    // 波形平滑 FIR（线性相位低通，15 抽头）
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
    // 自适应触发门限
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
    // SD 卡子系统
    //   上电后先做 SD 初始化（200 kHz），完成后自动读一次【扇区 0】
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
    reg  [23:0] sd_wdg;         // 读请求重试看门狗
    reg  [9:0]  sd_gap_q;
    // SD 子系统软复位
    reg  [3:0]  sd_srst_cnt;
    reg         sd_srst;

    wire        img_changed = (ui_img_idx != sd_img_d);

    sd_ctrl_top #(
        .CLK_HZ        (48_000_000),
        .FAST_DIV      (4),          // 12 MHz 读时钟
        .INIT_HZ       (200_000),
        .POWER_ON_NUM  (5000),
        .OVER_TIME_NUM (25000)
    ) u_sd (
        .clk         (clk_sys),
        // 每次切图时把整个 SD 子系统复位
        .rst_n       (rst_sys_n & ~sd_srst),
        .sd_clk      (sd_clk),
        .sd_cs       (sd_cs),
        .sd_mosi     (sd_mosi),
        .sd_miso     (sd_miso),
        .rd_start    (sd_rd_start),
        // 第 N 张图占 512 个扇区（256 KB）
        //   起始扇区 IMG_SECTOR_BASE 由脚本决定（见 scripts/sdcard/mkimage.py）
        .rd_sec_addr (IMG_SECTOR_BASE + ({24'd0, ui_img_idx} << 9)),
        .rd_busy     (sd_rd_busy),
        .rd_valid    (sd_rd_valid),
        .rd_data     (sd_rd_data),
        .init_done   (sd_init_done)
    );

    // 初始化完成后发一次读请求（单拍脉冲）
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
            // img_changed 是一个单拍脉冲，拉长成 8 拍的复位窗
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

            // 用户切图->重新读一轮
            if (img_changed) begin
                sd_rd_done  <= 1'b0;
                sd_rd_count <= 16'd0;
                sd_dbg_idx  <= 4'd0;
                sd_rd_start <= 1'b0;
                sd_wdg      <= 24'd0;
            end

            // 看门狗：超时重新发请求
            if (sd_rd_done)
                sd_wdg <= 24'd0;
            else if (sd_wdg != 24'h1FFFFF)  // 44ms
                sd_wdg <= sd_wdg + 24'd1;
            else begin
                // 超时
                sd_rd_done  <= 1'b0;
                sd_rd_count <= 16'd0;
                sd_dbg_idx  <= 4'd0;
                sd_wdg      <= 24'd0;
            end

            // 读完成后的最小间隔计数（CS 高电平保持时间）
            if (sd_rd_done)
                sd_gap_q <= 10'd0;
            else if (sd_gap_q != 10'h3FF)
                sd_gap_q <= sd_gap_q + 10'd1;

            // 初始化完成后发一次读请求（1 拍脉冲）
            if (sd_init_done && !sd_rd_done && !sd_rd_busy && !sd_rd_start &&
                (sd_gap_q == 10'h3FF))
                sd_rd_start <= 1'b1;
            else
                sd_rd_start <= 1'b0;

            // 收集读到的字节：前 16 个存下来，同时数总个数
            if (sd_rd_valid) begin
                // sd_dbg_idx 是 4 位 ≤ 15，不用再判
                sd_dbg_bytes[sd_dbg_idx] <= sd_rd_data;
                if (sd_dbg_idx != 4'd15)
                    sd_dbg_idx <= sd_dbg_idx + 4'd1;
                if (sd_rd_count != 16'd511)
                    sd_rd_count <= sd_rd_count + 16'd1;
            end

            // 收满 512 个，本次读完成
            if (!img_changed && (sd_rd_count == 16'd511))
                sd_rd_done <= 1'b1;
        end
    end

    //=========================================================================
    // SD 图片搬运：SD 字节流 -> RGB565 像素 -> 帧缓冲
    //=========================================================================
    wire        load_wr_en;
    wire [18:0] load_wr_addr;
    wire [15:0] load_wr_data;

    // 切图时给搬运器一个 start 脉冲，清掉计数重新搬
    reg         load_start;
    always @(posedge clk_sys or negedge rst_sys_n) begin
        if (!rst_sys_n)
            load_start <= 1'b0;
        else
            load_start <= img_changed;     // img_changed 是 1 拍脉冲
    end

    // 写第一份（480x272 全图）+ 第二份（裁剪 320x180）
    sd_img_load #(.W(480), .H(272),
                  .EN_CROP(1), .CX(80), .CY(46), .CW(320), .CH(180)) u_img_load (
        .clk        (clk_sys),
        .rst_n      (rst_sys_n),
        .start      (load_start),
        .byte_valid (sd_rd_valid),
        .byte_data  (sd_rd_data),
        .wr_en      (load_wr_en),
        .wr_addr    (load_wr_addr),
        .wr_data    (load_wr_data),
        .wr2_en     (load_wr2_en),
        .wr2_addr   (load_wr2_addr),
        .done       (load_done),
        .pix_cnt    (load_pix_cnt)
    );

    //-------------------------------------------------------------------------
    // 两份帧缓冲：避免被推断成 LUTRAM
    //-------------------------------------------------------------------------
    frame_buf #(.W(480), .H(272)) u_fb_lcd (
        .wr_clk  (clk_sys),
        .wr_en   (load_wr_en),
        .wr_addr (load_wr_addr),
        .wr_data (load_wr_data),
        .rd_clk  (clk_pix),
        .rd_addr (fb_rd_addr),
        .rd_data (fb_rd_data)
    );

    frame_buf #(.W(320), .H(180)) u_fb_hdmi (
        .wr_clk  (clk_sys),
        .wr_en   (load_wr2_en),
        .wr_addr (load_wr2_addr),
        .wr_data (load_wr_data),
        .rd_clk  (clk_hdmi),
        .rd_addr (fb_rd_addr_hdmi),
        .rd_data (fb_rd_data_hdmi)
    );

    //=========================================================================
    // 显示（LCD 侧）
    //=========================================================================
    disp_top #(
        .ANIM_STEP(ANIM_STEP),
        // LCD：读 480x272 完整缓冲，1:1 满屏
        .FB_SW(480), .FB_SH(272), .FB_W(480), .FB_H(272),
        .FB_X0(0), .FB_Y0(0), .SHIFT(0), .FB_CX(0), .FB_CY(0)
    ) u_disp (
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
        .ui_spk_mute(ui_spk_mute),
        .ui_src     (src_sel),
        .ui_img_idx (ui_img_idx),
        .ui_view    (ui_view[2:0]),
        .ui_hue_spd (ui_hue_spd),
        .ui_wave_gain(ui_wave_gain),        // G 命令：波形增益
        .ui_demo    (ui_demo),              // T 命令：演示图案
        .tp_x       (tp_x),                 // 触摸原始读数
        .tp_y       (tp_y),
        .tp_edges   (),
        .tp_low     (),
        .wave_din   (wave_din_sel),         // 波形显示左声道（或自检图案）
        .wave_th    (wave_th),              // 自适应触发门限（来自 env_track）
        .dbg_adc    ({15'd0, src_sel, ui_img_idx}),     // 调试值，已弃用
        .dbg_sd_bytes ({40'd0, rx_l}),                  // 调试值，已弃用
        // 等一帧（load_done）搬完再切显示
        .cfg_bg_src (ui_bg_src & load_done),
        .fb_rgb     (fb_rd_data),
        .fb_addr    (fb_rd_addr),
        .wave_we    (wave_we_sel),
        .lcd_rgb    (lcd_rgb),
        .lcd_hs     (lcd_hs),
        .lcd_vs     (lcd_vs),
        .lcd_de     (),                     // LCD 侧用不到
        .lcd_clk    (lcd_clk)
    );

    //=========================================================================
    // HDMI 输出（第二路显示：640 360@60）
    //=========================================================================
    wire        rst_hdmi_n;
    wire [23:0] hdmi_rgb;
    wire        hdmi_hs, hdmi_vs, hdmi_de;

    //-------------------------------------------------------------------------
    // HDMI 域的复位，在sys 域之后
    //-------------------------------------------------------------------------
    reg [7:0] rst_hdmi_cnt;
    reg       rst_hdmi_done;

    always @(posedge clk_hdmi or negedge rst_sys_n) begin
        if (!rst_sys_n) begin
            rst_hdmi_cnt  <= 8'd0;
            rst_hdmi_done <= 1'b0;
        end else if (!rst_hdmi_done) begin
            if (rst_hdmi_cnt == 8'hFF)
                rst_hdmi_done <= 1'b1;
            else
                rst_hdmi_cnt <= rst_hdmi_cnt + 8'd1;
        end
    end

    // 先用 rst_sys_n 把异步复位拉低，再由 rst_hdmi_done 决定何时释放
    wire rst_hdmi_pre = rst_sys_n & rst_hdmi_done;

    rst_sync u_rst_hdmi (
        .clk         (clk_hdmi),
        .rst_async_n (rst_hdmi_pre),
        .rst_n       (rst_hdmi_n)
    );

    //-------------------------------------------------------------------------
    // 同步 clk_sys 域信号到 clk_hdmi 域
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
        .WITH_UI(0), .WITH_TEXT(0),
        // HDMI：图片 2 倍放大满屏（320x180 -> 640x360）
        .FB_SW(320), .FB_SH(180), .FB_W(640), .FB_H(360),
        .FB_X0(0), .FB_Y0(0), .SHIFT(1), .FB_CX(0), .FB_CY(0),
        .NBARS_DISP(80),        // 640 / 80 = 8 px/柱
        .WAVE_AW(11),           // 640 采样需要 >=1024 的 bank
        .ANIM_STEP  (ANIM_STEP),
        //-------------------------------------------------------------------------
        // 大屏布局：640x360@60（16:9）
        //   为什么是 640x360 而不是 800x600 或 1280x720：
        //    disp_top 的关键路径 26.9 ns
        //    800x600@60 要 40 MHz，25 ns 预算，时序违例 -1.9 ns
        //    640x480@60 只要 25 MHz，40 ns 预算，余量 13 ns
        //-------------------------------------------------------------------------
        .PIX_HZ     (25_000_000),       // 这一路跑 clk_hdmi = 25MHz（空闲计时要用）
        .HDISP      (640),
        .VDISP      (360),              // 16:9，铺满显示器
        // V 消隐凑够 25MHz：800 x (360+3+6+152) x 60 = 25.01 MHz
        .V_FRONT    (3),
        .V_SYNC     (6),
        .V_BACK     (152),
        .NBARS      (80),              // HDMI：和第二个 spectrum 一致
        // 组件布局按 480x272 横向 x1.33、纵向 x(360/272)=1.32 重算
        .BARS_Y0    (15),
        .BARS_H     (340),              // 15..355 铺满，无底部留白
        .BAR_GAP    (2),
        .POL_CX     (320),
        .POL_CY     (78),
        .POL_RIN    (16),
        .POL_RMAX   (62),
        .WAVE_CY    (180),              // 和 LCD 一样放在中间
        .WAVE_AMP   (60),               // 和 LCD 的 80 相当（屏更高）
        .UI_BY0     (312),              // 360 - 48
        .UI_BW      (88),               // 7x88 + 6x2 = 628 <= 640
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
        .spec_wr    (demo_on ? demo_wr : spec_frame_done80),   // HDMI：80 根那路
        // demo_bars 60 根，后 20 根重复映射成 80 根
        .spec_din   (demo_on ? {demo_bars[539:459], demo_bars} : spec_bars80),
        .clk_pix    (clk_hdmi),
        .rst_pix_n  (rst_hdmi_n),
        .ui_mode    (ui_bg_mode[3:0]),
        .ui_style   (ui_style[3:0]),
        .ui_spk_mute(ui_spk_mute),
        .ui_src     (src_sel),
        .ui_img_idx (ui_img_idx),
        .ui_view    (ui_view[2:0]),
        .ui_hue_spd (ui_hue_spd),
        .ui_wave_gain(ui_wave_gain),
        .ui_demo    (ui_demo),
        .tp_x       (tp_x),
        .tp_y       (tp_y),
        .tp_edges   (),                         // 诊断量，HDMI 侧不接
        .tp_low     (),
        .wave_din   (wave_din_sel),
        .wave_th    (wave_th),
        // 诊断显示
        .dbg_adc    ({20'd0, ui_sel_hdmi}),
        .dbg_sd_bytes (sd_dbg_q),
        .cfg_bg_src (ui_bg_src & load_done),   // HDMI 也用 SD 图片
        .fb_rgb     (fb_rd_data_hdmi),         // 读裁剪后的 320x180 缓冲
        .fb_addr    (fb_rd_addr_hdmi),
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
        // R/B 互换：LCD 面板的接线是 BGR，HDMI 走标准 RGB
        .pix_rgb    ({hdmi_rgb[7:0], hdmi_rgb[15:8], hdmi_rgb[23:16]}),
        .pix_de     (hdmi_de),
        .pix_hs     (hdmi_hs),
        .pix_vs     (hdmi_vs),
        .tmds_clk_p (hdmi_clk_p), .tmds_clk_n (hdmi_clk_n),
        .tmds_d0_p  (hdmi_d0_p),  .tmds_d0_n  (hdmi_d0_n),
        .tmds_d1_p  (hdmi_d1_p),  .tmds_d1_n  (hdmi_d1_n),
        .tmds_d2_p  (hdmi_d2_p),  .tmds_d2_n  (hdmi_d2_n),
        .hdmi_out_en(hdmi_out_en)
    );

    // 预留未使用
    wire _unused_hpd = hdmi_hpd;

    //=========================================================================
    // 指示灯
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

endmodule
