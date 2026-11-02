//=============================================================================
// tb_top.v - 整机冒烟仿真
//-----------------------------------------------------------------------------
// 目的：各模块都已经【单独】验证过了（15 个 testbench 全 PASS），
//       但它们**从来没在一个仿真里跑过**。这个 TB 就是补这一课：
//       验证上电时序、跨模块连线、时钟域切换在整机上真的成立。
//
// 模拟的外部世界：
//   · 200 MHz 差分时钟（用 sim/tb/xilinx_stub.v 里的行为模型）
//   · WM8960 的 I2C 从机（要对 ACK，否则 WM8960_init 会一直重试）
//   · WM8960 的 I2S 主机（BCLK / LRCLK / ADCDAT）
//
// 检查项：
//   ① 上电时序   —— MMCM 锁定 -> 等 INIT_WAIT -> I2C 配置 -> Init_Done
//   ② I2C 序列   —— 必须正好 20 条，从机地址 0x34
//   ③ I2S 接收   —— Init_Done 之后 rx_valid 必须以 2*LRCLK 的节奏出现
//   ④ FFT 成帧   —— 每帧 512 个频点
//   ⑤ 频谱更新   —— spectrum.frame_done 必须以 FFT 帧的节奏出现
//   ⑥ 跨域生效   —— clk_pix 侧读到的柱高必须与 clk_sys 侧一致
//   ⑦ 显示输出   —— LCD 出帧，且每帧 480x272 个有效像素
//   ⑧ 柱高非零   —— 灌方波进去，至少要有几根柱被点亮（否则整条链是死的）
//
// 【仿真时长取舍】
//   音频采样率取 96 kHz（真实是 48 kHz）—— 只为了让 FFT 少跑一半时间。
//   FFT 的分组表是按 48 kHz 设计的，这里频率映射会偏一倍，
//   但冒烟仿真的目的是"链路通不通"，不是"频点准不准"（那个由 tb_fft_core 保证）。
//=============================================================================
`timescale 1ns / 1ps

module tb_top;


    `include "wm8960_nreg.vh"
    localparam integer INI_WAIT = 1;        // ms，复位释放后等多久发 I2C
    localparam integer I2C_DLY  = 0;        // ms，I2C 每条间隔（冒烟取 0 省时间）

    // 音频：96 kHz x 64 = 6.144 MHz BCLK
    //   ⚠️ 半周期 = 1e9 / (2*f)。写成 1000.0/(2*f) 会得到 8e-5 ns，
    //   在 1ns/1ps 精度下直接变成 #0 -> 时间 0 无限循环，仿真永远起不来。
    localparam real    BCLK_HALF = 1_000_000_000.0 / (2.0 * 6_144_000.0);   // 81.38 ns
    localparam integer SLOT      = 32;

    //=========================================================================
    // 200 MHz 差分时钟与复位
    //=========================================================================
    reg clk_p = 1'b0;
    reg clk_n = 1'b1;
    always #2.5 begin
        clk_p = ~clk_p;
        clk_n = ~clk_n;
    end

    reg rst_btn_n = 1'b0;
    reg key1_n = 1'b1;      // 按下 = 低
    reg key2_n = 1'b1;

    // UART："电脑"侧模型。声明提前（DUT 要用 pc_serial），实例化放后面
    //   （实例化要用 dut.clk_sys，形成互引用 —— 所以拆成两半）。
    reg        pc_send = 1'b0;
    reg  [7:0] pc_data = 8'd0;
    wire       pc_serial;       // TB -> DUT
    wire       pc_serial_back;  // DUT -> TB（回执）
    wire       pc_busy;
    wire       pc_rx_valid;
    wire [7:0] pc_rx_data;
    integer    n_pc_rx = 0;


    //=========================================================================
    // I2C 总线（TB 当从机，要会 ACK，否则 WM8960_init 会一直重试）
    //=========================================================================
    wire aud_scl;
    wire aud_sda;
    reg  sda_oe = 1'b0;
    assign aud_sda = sda_oe ? 1'b0 : 1'bz;
    wire sda_in = (aud_sda === 1'b0) ? 1'b0 : 1'b1;

    integer    i2c_n     = 0;
    integer    i2c_bad   = 0;
    reg [15:0] i2c_word [0:31];
    reg [15:0] cur_word = 16'd0;

    reg       in_frame = 1'b0;
    reg [3:0] bitcnt   = 4'd0;
    reg [2:0] byte_idx = 3'd0;
    reg [7:0] shreg    = 8'd0;

    // START / STOP 检测
    always @(sda_in) begin
        if (aud_scl && !in_frame && !sda_in) begin
            in_frame = 1'b1;
            bitcnt   = 4'd0;
            byte_idx = 3'd0;
        end else if (aud_scl && in_frame && sda_in) begin
            if (byte_idx == 3'd3) begin
                if (i2c_n < 32) i2c_word[i2c_n] = cur_word;
                i2c_n = i2c_n + 1;
            end
            in_frame = 1'b0;
        end
    end

    // SCL 上升沿采样
    always @(posedge aud_scl) begin
        if (in_frame) begin
            if (bitcnt < 4'd8) begin
                shreg  = {shreg[6:0], sda_in};
                bitcnt = bitcnt + 4'd1;
            end else begin
                bitcnt = 4'd0;
                case (byte_idx)
                    3'd0: if (shreg !== 8'h34) i2c_bad = i2c_bad + 1;
                    3'd1: cur_word[15:8] = shreg;
                    3'd2: cur_word[7:0]  = shreg;
                    default: ;
                endcase
                byte_idx = byte_idx + 3'd1;
            end
        end
    end

    // SCL 下降沿给 ACK
    always @(negedge aud_scl) begin
        sda_oe = (in_frame && bitcnt == 4'd8) ? 1'b1 : 1'b0;
    end

    //=========================================================================
    // I2S 主机（模拟 WM8960）
    //=========================================================================
    reg     aud_bclk   = 1'b0;
    reg     aud_lrclk  = 1'b0;
    reg     aud_adcdat = 1'b0;
    wire    aud_dacdat;

    integer mb = 0;
    reg [23:0] tx_sample = 24'h000000;
    integer    sq_cnt    = 0;

    initial begin
        forever begin
            #BCLK_HALF;
            aud_bclk = 1'b1;
            #BCLK_HALF;
            aud_bclk = 1'b0;
            mb = (mb == 2*SLOT - 1) ? 0 : mb + 1;
            aud_lrclk = (mb >= SLOT);
            if (mb < 24)
                aud_adcdat = tx_sample[23 - mb];
            else if (mb >= SLOT && mb < SLOT + 24)
                aud_adcdat = tx_sample[23 - (mb - SLOT)];
            else
                aud_adcdat = 1'b0;
        end
    end

    //=========================================================================
    // DUT
    //=========================================================================
    wire [23:0] lcd_rgb;
    wire        lcd_hs, lcd_vs, lcd_clk;
    wire [1:0]  led;
    wire        tp_dclk_w, tp_cs_n_w, tp_din_w;
    wire        tp_dout_w;
    reg  [11:0] tp_force_x = 12'hFFF;   // 默认：贴上限 = 没触摸
    reg  [11:0] tp_force_y = 12'hFFF;
    wire [7:0]  tp_last_cmd;
    wire [3:0]  tp_n_cmd;
    wire [7:0]  tp_n_dclk;

    xpt2046_model u_tpm (
        .tp_dclk(tp_dclk_w), .tp_cs_n(tp_cs_n_w),
        .tp_din(tp_din_w), .tp_dout(tp_dout_w),
        .force_x(tp_force_x), .force_y(tp_force_y),
        .last_cmd(tp_last_cmd), .n_cmd(tp_n_cmd), .n_dclk(tp_n_dclk)
    );

    top #(
        .INIT_WAIT_MS (INI_WAIT),
        .I2C_DLY_MS   (I2C_DLY),
        .ANIM_STEP    (128),    // 面板一帧开完，否则 TB 要等 384 ms
        // 按键手势的两个时长同样要缩小：产品是 20ms/300ms，
        // 那样"一次单击"就要等 14.4M 拍，冒烟测试会超时（实测过）。
        // ⚠️ 缩小的同时，下面 T_PRESS/T_GAP 也要按比例缩小，
        //    否则两次按下的间隔会超过窗口，双击测不出来。
        .KEY_DB_MS    (1),      // 消抖 1ms
        .KEY_WIN_MS   (8)       // 双击窗 8ms
    ) dut (
        .clk_200m_p (clk_p),
        .clk_200m_n (clk_n),
        .rst_btn_n  (rst_btn_n),
        .key1_n     (key1_n),
        .key2_n     (key2_n),
        .uart_rx_pin(pc_serial),
        .uart_tx_pin(pc_serial_back),
        // 触摸屏：接一个 XPT2046 行为模型，这样 SPI 那条链也一起被测到。
        //   force_x/force_y 由本 TB 控制，用来"把手指按到某个按钮上"。
        .tp_dclk    (tp_dclk_w),
        .tp_cs_n    (tp_cs_n_w),
        .tp_din     (tp_din_w),
        .tp_dout    (tp_dout_w),
        .aud_scl    (aud_scl),
        .aud_sda    (aud_sda),
        .aud_bclk   (aud_bclk),
        .aud_lrclk  (aud_lrclk),
        .aud_adcdat (aud_adcdat),
        .aud_dacdat (aud_dacdat),
        .lcd_rgb    (lcd_rgb),
        .lcd_hs     (lcd_hs),
        .lcd_vs     (lcd_vs),
        .lcd_clk    (lcd_clk),
        .led        (led)
    );

    // 内部信号观测（冒烟调试用）
    wire clk_sys   = dut.clk_sys;
    wire clk_pix   = dut.clk_pix;
    wire rst_sys_n = dut.rst_sys_n;     // UART 模型要用（和 DUT 同一份复位）
    wire locked    = dut.mmcm_locked;
    wire init_done = dut.init_done;
    wire rx_valid  = dut.rx_valid;
    wire fft_valid = dut.fft_valid;
    wire spec_done = dut.spec_frame_done;
    wire sof       = dut.u_disp.sof;
    wire de        = dut.u_disp.de;

    // ---- UART 模型实例化（此刻 dut.clk_sys 已经可用）----
    uart_tx #(.CLK_HZ(48_000_000), .BAUD(115200)) u_pc_tx (
        .clk(clk_sys), .rst_n(rst_sys_n), .send(pc_send), .data(pc_data),
        .tx(pc_serial), .busy(pc_busy)
    );

    uart_rx #(.CLK_HZ(48_000_000), .BAUD(115200)) u_pc_rx (
        .clk(clk_sys), .rst_n(rst_sys_n), .rx(pc_serial_back),
        .data(pc_rx_data), .valid(pc_rx_valid), .ferr()
    );

    task pc_put;
        input [7:0] c;
        begin
            @(negedge clk_sys); pc_data = c; pc_send = 1;
            @(negedge clk_sys); pc_send = 0;
            wait (pc_busy === 1'b1);
            wait (pc_busy === 1'b0);
            repeat (2) @(posedge clk_sys);
        end
    endtask

    //=========================================================================
    // 统计
    //=========================================================================
    integer n_rx      = 0;
    integer n_fft     = 0;
    integer n_spec    = 0;
    integer n_sof     = 0;
    integer n_de      = 0;
    integer n_de_frame = 0;
    integer de_bad    = 0;
    integer n_err     = 0;
    integer n_bars_nz = 0;
    integer k;

    reg [269:0] bars_pix;

    always @(posedge clk_sys) begin
        if (rx_valid)  n_rx  = n_rx  + 1;
        if (fft_valid) n_fft = n_fft + 1;
        if (spec_done) n_spec = n_spec + 1;
    end

    always @(posedge clk_pix) begin
        if (sof) begin
            n_sof = n_sof + 1;
            if (n_de_frame != 0 && n_de_frame != 480*272) de_bad = de_bad + 1;
            n_de_frame = 0;
        end
        if (de) begin
            n_de = n_de + 1;
            n_de_frame = n_de_frame + 1;
        end
    end

    //=========================================================================
    // 激励与检查
    //=========================================================================
    integer i, j;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("sim/build/tb_top.vcd");
            $dumpvars(0, tb_top);
        end

        $display("============================================================");
        $display(" 整机冒烟仿真");
        $display("   200MHz 差分 -> MMCM -> clk_sys 48MHz + clk_pix 12.5MHz");
        $display("   WM8960 模拟：I2C 从机(会 ACK) + I2S 主机(96kHz，加速用)");
        $display("   上电等待 %0d ms，I2C 每条间隔 %0d ms", INI_WAIT, I2C_DLY);
        $display("============================================================");

        rst_btn_n = 1'b0;
        repeat (50) @(posedge clk_p);
        @(negedge clk_p); rst_btn_n = 1'b1;

        //---------------------------------------------------------------------
        // ① 等 MMCM 锁定
        //---------------------------------------------------------------------
        wait (locked === 1'b1);
        $display("");
        $display(" [1] 上电时序");
        $display("  [ok ] MMCM 锁定    (t=%0t)", $time);

        // 等 I2C 配置完成
        fork
            begin : w_done
                wait (init_done === 1'b1);
                disable w_timeout;
            end
            begin : w_timeout
                #80_000_000;
                $display("  [ERR] 超时：Init_Done 一直没拉高");
                n_err = n_err + 1;
                disable w_done;
            end
        join
        $display("  [ok ] Init_Done 拉高 (t=%0t)", $time);

        //---------------------------------------------------------------------
        // ② I2C 序列
        //---------------------------------------------------------------------
        // 条数来自生成的头文件（和 RTL、和 tb_wm8960_init 同一个数）
        if (i2c_n != WM8960_NREG) begin
            n_err = n_err + 1;
            $display("  [ERR] I2C 条数 = %0d（应为 %0d）", i2c_n, WM8960_NREG);
        end else
            $display("  [ok ] I2C 写入 20 条，从机地址错误 %0d 次", i2c_bad);
        if (i2c_bad != 0) n_err = n_err + 1;

        //---------------------------------------------------------------------
        // ③~⑧ 让音频和显示跑一段
        //---------------------------------------------------------------------
        $display("");
        $display(" [2] 数据通路（跑约 30 ms）");

        // 方波：每 8 个 I2S 帧翻转一次符号
        fork
            begin : sq_gen
                forever begin
                    @(negedge aud_lrclk);
                    sq_cnt = sq_cnt + 1;
                    if (sq_cnt == 8) begin
                        sq_cnt = 0;
                        tx_sample = (tx_sample == 24'h400000) ? -24'h400000 : 24'h400000;
                    end
                end
            end
            begin : run_timer
                #30_000_000;        // 跑 30 ms
                disable sq_gen;     // Verilog-2001 没有 disable fork
            end
        join

        //---------------------------------------------------------------------
        // 结果
        //---------------------------------------------------------------------
        $display("");
        $display("   I2S 接收样本数   : %0d", n_rx);
        $display("   FFT 输出频点数   : %0d", n_fft);
        $display("   频谱帧完成次数   : %0d", n_spec);
        $display("   LCD 帧数         : %0d", n_sof);
        $display("   LCD 有效像素数   : %0d", n_de);

        if (n_rx < 1000) begin
            n_err = n_err + 1;
            $display("  [ERR] I2S 接收样本太少（%0d）", n_rx);
        end else
            $display("  [ok ] I2S 从模式接收正常，样本数以 2xLRCLK 节奏出现");

        if (n_fft == 0) begin
            n_err = n_err + 1;
            $display("  [ERR] FFT 一个频点都没输出");
        end else if (n_fft % 512 != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] FFT 输出 %0d 个频点，不是 512 的整数倍", n_fft);
        end else
            $display("  [ok ] FFT 输出 %0d 个频点 = %0d 帧 x 512",
                     n_fft, n_fft / 512);

        if (n_spec == 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 频谱一帧都没完成");
        end else
            $display("  [ok ] 频谱完成 %0d 帧", n_spec);

        // ⑥ 跨域
        //   ⚠️ 只能用【最新时刻】的 bars 去查，不能在 sof 那一拍抓 ——
        //      spec_sync 里 `bars <= stage` 是非阻塞赋值，sof 当拍读到的是
        //      上一帧的旧值，会误判成"跨域没生效"。
        //      （这已经是本项目第 4 次踩"和被观测信号差一拍"了）
        bars_pix = dut.u_disp.u_sync.bars;
        n_bars_nz = 0;
        for (k = 0; k < 30; k = k + 1)
            if (bars_pix[k*9 +: 9] != 9'd0) n_bars_nz = n_bars_nz + 1;
        $display("");
        $display(" [3] 跨时钟域与显示");
        if (n_bars_nz == 0) begin
            n_err = n_err + 1;
            $display("  [ERR] clk_pix 侧读到的柱高全是 0（跨域没生效或频谱是死的）");
        end else
            $display("  [ok ] clk_pix 侧柱高非零 %0d/30 根（柱0=%0d 柱15=%0d 柱29=%0d）",
                     n_bars_nz, bars_pix[0 +: 9], bars_pix[15*9 +: 9], bars_pix[29*9 +: 9]);

        if (n_sof < 2) begin
            n_err = n_err + 1;
            $display("  [ERR] LCD 只出了 %0d 帧", n_sof);
        end else if (de_bad != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 有 %0d 帧的有效像素数不等于 480x272", de_bad);
        end else
            $display("  [ok ] LCD 出 %0d 帧，每帧 480x272 个有效像素", n_sof);

        if (led[0] !== 1'b1) begin
            n_err = n_err + 1;
            $display("  [ERR] led[0] 应为 1（Init_Done 指示）");
        end else
            $display("  [ok ] led[0] = 1（WM8960 配置完成指示）");

        //---------------------------------------------------------------------
        // [4] 按键端到端：按一下 KEY1，视图预设应该轮换
        //---------------------------------------------------------------------
        $display("");
        $display(" [4] 按键手势端到端（P1-5：单击/双击四动作）");
        //   映射：KEY1 单击=光标左移  KEY1 双击=面板开关
        //         KEY2 单击=光标右移  KEY2 双击=确认
        //
        //   ⚠️ 执行顺序很重要：面板默认是【关】的，而单击/确认只在
        //      【面板展开】时才生效（用户看得见才谈得上选），
        //      所以必须【先双击开面板】，再测单击和确认。
        //      而且用例收尾要把面板切回去，否则污染后面的触摸测试。
        //
        //   时序依据（改参数时这里要跟着改）：
        //     key_debounce MS=1ms   ⟹ 按下要持续 >1ms 才认
        //     两次按下之间【松开】也要 >1ms（连释放都要消抖）
        //     key_gesture WIN_MS=8ms ⟹ 两次按下的脉冲间隔 <8ms 才算双击
        //   本 TB 每次按下低 3ms、间隔高 3ms ⟹ 相邻按下脉冲相隔约 4ms < 8ms ✓
        //   而【单击】要等窗口期满（8ms）才发，所以单击后等 10ms 再看结果。
        begin : key_test
            reg [2:0] sel_before;
            reg [7:0] view_before;
            reg       panel_before;

            // ---- ⓪ 面板关着时，单击必须【无效】（这是新语义，专门测它）----
            sel_before = dut.sel_idx;
            key1_n = 1'b0; #3_000_000; key1_n = 1'b1; #3_000_000;
            #10_000_000;
            if (dut.sel_idx === sel_before)
                $display("  [ok ] 面板关着时 KEY1 单击无效：光标仍是 %0d", dut.sel_idx);
            else begin
                n_err = n_err + 1;
                $display("  [ERR] 面板关着时 KEY1 单击竟然动了光标：%0d -> %0d",
                         sel_before, dut.sel_idx);
            end

            // ---- ① KEY1 双击 -> 面板开（这是唯一的"不受面板状态约束"的动作）----
            panel_before = dut.u_disp.ui_open;
            key1_n = 1'b0; #3_000_000; key1_n = 1'b1; #3_000_000;
            key1_n = 1'b0; #3_000_000; key1_n = 1'b1; #3_000_000;
            if (dut.u_disp.ui_open === ~panel_before)
                $display("  [ok ] KEY1 双击：面板 %0b -> %0b（已展开）", panel_before, dut.u_disp.ui_open);
            else begin
                n_err = n_err + 1;
                $display("  [ERR] KEY1 双击后面板 = %0b（期望 %0b）", dut.u_disp.ui_open, ~panel_before);
            end
            // 让 panel_open 同步到 clk_sys（跨时钟域，要等几拍）
            #10_000_000;

            // ---- ② KEY1 单击 -> 光标左移（0 环绕到 5）----
            sel_before = dut.sel_idx;
            key1_n = 1'b0; #3_000_000; key1_n = 1'b1; #3_000_000;
            #10_000_000;
            if (dut.sel_idx === ((sel_before == 3'd0) ? 3'd6 : sel_before - 1'b1))
                $display("  [ok ] KEY1 单击：光标 %0d -> %0d（左移）", sel_before, dut.sel_idx);
            else begin
                n_err = n_err + 1;
                $display("  [ERR] KEY1 单击后光标 = %0d（期望左移，原 %0d）", dut.sel_idx, sel_before);
            end

            // ---- ③ KEY2 单击 -> 光标右移 ----
            sel_before = dut.sel_idx;
            key2_n = 1'b0; #3_000_000; key2_n = 1'b1; #3_000_000;
            #10_000_000;
            if (dut.sel_idx === ((sel_before == 3'd6) ? 3'd0 : sel_before + 1'b1))
                $display("  [ok ] KEY2 单击：光标 %0d -> %0d（右移）", sel_before, dut.sel_idx);
            else begin
                n_err = n_err + 1;
                $display("  [ERR] KEY2 单击后光标 = %0d（期望右移，原 %0d）", dut.sel_idx, sel_before);
            end

            // ---- ④ KEY2 双击 -> 确认 ----
            //   ②左移一次（0 环绕到 6）+ ③右移一次（6 环绕到 0）= 回到 0（VIEW）
            //   在 VIEW 上"确认"= 切视图，所以看 ui_view 变没变
            view_before = dut.ui_view;
            key2_n = 1'b0; #3_000_000; key2_n = 1'b1; #3_000_000;
            key2_n = 1'b0; #3_000_000; key2_n = 1'b1; #3_000_000;
            if (dut.sel_idx === 3'd0) begin
                if (dut.ui_view === view_before) begin
                    n_err = n_err + 1;
                    $display("  [ERR] KEY2 双击确认后视图预设没变（一直 %08b）", view_before);
                end else
                    $display("  [ok ] KEY2 双击确认：视图预设 %08b -> %08b", view_before, dut.ui_view);
            end else begin
                n_err = n_err + 1;
                $display("  [ERR] 前提不成立：期望光标在 0(VIEW)，实际 %0d", dut.sel_idx);
            end

            // ---- ④b 覆盖【尾部两项】的确认动作 ----
            //   ⚠️ 为什么要专门测这两项：
            //     ui_ctrl 的动作码不是连续的光标值 ——
            //       光标 0..4 -> 动作码 0..4
            //       光标 5(DEMO) -> 4'h6    （跳过 5）
            //       光标 6(IN)   -> 4'h7
            //     而 4'h5 在 ui_ctrl 的 step 分支里【不存在】（4'h5 是 cfg_auto，只给 UART 用）。
            //     所以只要"光标->动作码"这份映射漏了一处，就会表现为
            //       "DEMO 按了没反应、IN 却执行了 DEMO"。
            //     这类"差一格"的 bug，中间的项全对，只有跳号处和末尾错 ——
            //     所以【第一项和最后两项】必须逐个测。
            begin : tail_items
                reg [7:0] d0, s0;
                integer n;

                // 从 VIEW(0) 右移到 DEMO(5)：5 次单击
                for (n = 0; n < 5; n = n + 1) begin
                    key2_n = 1'b0; #3_000_000; key2_n = 1'b1; #3_000_000;
                    #10_000_000;
                end
                if (dut.sel_idx !== 3'd5) begin
                    n_err = n_err + 1;
                    $display("  [ERR] 右移 5 次后光标 = %0d（期望 5 = DEMO）", dut.sel_idx);
                end else begin
                    d0 = dut.ui_demo;
                    // DEMO 上双击确认
                    key2_n = 1'b0; #3_000_000; key2_n = 1'b1; #3_000_000;
                    key2_n = 1'b0; #3_000_000; key2_n = 1'b1; #3_000_000;
                    if (dut.ui_demo === d0) begin
                        n_err = n_err + 1;
                        $display("  [ERR] 光标在 DEMO 上确认后 cfg_demo 没变（还是 %0d）", d0);
                    end else
                        $display("  [ok ] 光标在 DEMO 上确认：cfg_demo %0d -> %0d", d0, dut.ui_demo);
                end

                // 再右移一次到 IN(6)
                key2_n = 1'b0; #3_000_000; key2_n = 1'b1; #3_000_000;
                #10_000_000;
                if (dut.sel_idx !== 3'd6) begin
                    n_err = n_err + 1;
                    $display("  [ERR] 再右移一次后光标 = %0d（期望 6 = IN）", dut.sel_idx);
                end else begin
                    s0 = dut.ui_src;
                    key2_n = 1'b0; #3_000_000; key2_n = 1'b1; #3_000_000;
                    key2_n = 1'b0; #3_000_000; key2_n = 1'b1; #3_000_000;
                    if (dut.ui_src === s0) begin
                        n_err = n_err + 1;
                        $display("  [ERR] 光标在 IN 上确认后 cfg_src 没变（还是 %0d）", s0);
                    end else
                        $display("  [ok ] 光标在 IN 上确认：cfg_src %0d -> %0d（输入源切换）",
                                 s0, dut.ui_src);
                end
            end

            // ---- ⑤ 静态检查：空闲计时器的位宽必须装得下超时值 ----
            //   这是那个"说好 4 秒、实际 1.3 秒"bug 的回归判据。
            //   idle_cnt 原来 24 位，装不下 12500*4000=50,000,000，被静默截断。
            //   这里不去跑满 4 秒（太贵），而是直接检查【参数本身自洽】——
            //   便宜，而且正好抓住"位宽不够"这一类错误。
            if (dut.u_disp.TAB_CW < 26) begin
                n_err = n_err + 1;
                $display("  [ERR] 空闲计时器位宽不足：TAB_CW=%0d（需 >=26 才装得下 %0d）",
                         dut.u_disp.TAB_CW, dut.u_disp.TAB_CNT);
            end else
                $display("  [ok ] 空闲计时器位宽 TAB_CW=%0d，装得下 %0d 拍（≈%0d ms）",
                         dut.u_disp.TAB_CW, dut.u_disp.TAB_CNT,
                         dut.u_disp.TAB_CNT / 12500);

            // ---- ⑥ 收尾：把面板切回原状 ----
            //   ⚠️ 不能省：[6] 的触摸测试假设面板初始是关的，
            //      不还原的话它会看到 1->0，判"没打开"失败，还连锁带挂两项。
            key1_n = 1'b0; #3_000_000; key1_n = 1'b1; #3_000_000;
            key1_n = 1'b0; #3_000_000; key1_n = 1'b1; #3_000_000;
            if (dut.u_disp.ui_open === panel_before)
                $display("  [ok ] 收尾：面板已切回 %0b（不污染后续触摸测试）", panel_before);
            else begin
                n_err = n_err + 1;
                $display("  [ERR] 收尾失败：面板 = %0b（期望 %0b）",
                         dut.u_disp.ui_open, panel_before);
            end
        end

        //---------------------------------------------------------------------
        // [5] UART 端到端：从串口发一条命令，看配置有没有真的改掉
        //---------------------------------------------------------------------
        $display("");
        $display(" [5] UART 端到端");
        begin : uart_test
            reg [7:0] v_before2;
            v_before2 = dut.ui_view;
            pc_put("V"); pc_put("0"); pc_put("2");   // 只开极坐标
            repeat (2000) @(posedge clk_sys);
            if (dut.ui_view !== 8'h02) begin
                n_err = n_err + 1;
                $display("  [ERR] 串口发 'V02' 后视图 = %08b（期望 00000010）", dut.ui_view);
            end else
                $display("  [ok ] 串口发 'V02'：视图 %08b -> %08b", v_before2, dut.ui_view);

            // 再发 '?'，应至少收回 20 字节
            n_pc_rx = 0;
            pc_put("?");
            // 直接在等待循环里数 —— 比挂一个独立的 always 块更直观，
            // 也避免"计数器和被计数信号不在同一个时基"这种坑。
            for (j = 0; j < 400000; j = j + 1) begin
                @(posedge clk_sys);
                if (pc_rx_valid) n_pc_rx = n_pc_rx + 1;
            end
            if (n_pc_rx >= 20)
                $display("  [ok ] 串口发 '?'：收到 %0d 字节回执", n_pc_rx);
            else begin
                n_err = n_err + 1;
                $display("  [ERR] '?' 只回了 %0d 字节（应 >= 20）", n_pc_rx);
            end

            //-------------------------------------------------------------
            // T01（演示/自检图案）端到端：UART -> cmd_proc -> ui_ctrl
            //   -> top 里的 mux -> 显示链
            //
            // 这是新增的接线，必须验证它真的通。检查点选在
            // 【mux 之后、送给 disp_top 的那根线】上：
            //   T01 是斜坡，bar[i] 必须恰好是 i*8。
            //   音频通路的柱高不可能刚好长成 0,8,16,...,472，
            //   所以这个图案能确实区分“选到 demo 了”还是“还走音频”。
            //-------------------------------------------------------------
            begin : demo_test
                reg [8:0] b0, b59;
                reg [8:0] a0, a59;

                // 先记住关掉 demo 时的值（音频通路）
                a0  = dut.spec_bars_sel[0*9 +: 9];
                a59 = dut.spec_bars_sel[59*9 +: 9];

                pc_put("T"); pc_put("0"); pc_put("1");   // 开斜坡图案
                // 斜坡要等一个 tick（2^17 拍）才刷新，多等一会儿
                repeat (200000) @(posedge clk_sys);

                if (dut.ui_demo !== 8'h01) begin
                    n_err = n_err + 1;
                    $display("  [ERR] 串口发 'T01' 后 ui_demo = %0d（期望 1）", dut.ui_demo);
                end else
                    $display("  [ok ] 串口发 'T01'：ui_demo = 1");

                b0  = dut.spec_bars_sel[0*9 +: 9];
                b59 = dut.spec_bars_sel[59*9 +: 9];
                if (b0 !== 9'd0 || b59 !== 9'd472) begin
                    n_err = n_err + 1;
                    $display("  [ERR] T01 后柱高 bar[0]=%0d bar[59]=%0d（期望 0 与 472）",
                             b0, b59);
                    $display("        （音频通路当时是 %0d 与 %0d）", a0, a59);
                end else
                    $display("  [ok ] T01 后柱高变成斜坡 0..472（mux 切到 demo 成功）");

                // 关掉，确认能切回音频通路
                pc_put("T"); pc_put("0"); pc_put("0");
                repeat (200000) @(posedge clk_sys);
                if (dut.spec_bars_sel[0*9 +: 9] === b0 &&
                    dut.spec_bars_sel[59*9 +: 9] === b59) begin
                    n_err = n_err + 1;
                    $display("  [ERR] T00 后柱高没变，mux 可能没切回音频通路");
                end else
                    $display("  [ok ] T00 后切回音频通路（柱高不再等于斜坡）");
            end
        end

        //---------------------------------------------------------------------
        // [6] 触摸按钮端到端：打到按钮 3（GAIN）中心，配置必须真的变
        //---------------------------------------------------------------------
        //   ⚠️ 这条判据是补上的 —— 之前"按钮层"和"配置"各自都测了，
        //   但【从触摸到配置】这一整条链没有测试覆盖，
        //   结果上板时表现为：光标一直扫、配置一动不动。
        //
        //   换算：disp_top 里 screen = raw >> 3（x）、raw >> 4（y）。
        //   按钮 3 中心 = x 3*(BW+GAP)+BW/2
        //                y 234+19   = 253 -> raw_y = 253*16 = 4048
        //---------------------------------------------------------------------
        // [5b] 先点把手，把操作面板打开
        //---------------------------------------------------------------------
        //   ⚠️ 面板默认是【收起】的 —— 按钮带整条在屏幕外，点按钮当然没反应。
        //   这是设计如此（不占展示空间），但测试必须先"开面板"。
        //   第一次跑忘了这一步，[6] 直接失败，现象和真坏了很像。
        //
        //   把手在屏幕右侧 (448..463, 124..147)，原始值换算：
        //     x = 456 -> raw = 456*8  = 3648
        //     y = 136 -> raw = 136*16 = 2176
        $display("");
        $display(" [5b] 点右侧把手，打开操作面板");
        begin : open_panel
            tp_force_x = 12'd3648;
            tp_force_y = 12'd2176;
            repeat (600000) @(posedge clk_sys);
            tp_force_x = 12'hFFF; tp_force_y = 12'hFFF;
            repeat (600000) @(posedge clk_sys);
            if (!dut.u_disp.ui_open) begin
                n_err = n_err + 1;
                $display("  [ERR] 点了把手但面板没打开（ui_open 仍为 0）");
            end else
                $display("  [ok ] 点把手后 ui_open = 1（面板已展开）");
        end

        $display("");
        $display(" [6] 触摸按钮端到端（按 GAIN 按钮，配置必须变）");
        begin : tp_e2e
            reg [7:0] g0;
            g0 = dut.ui_wave_gain;
            //   ⚠️ 这个数字会随【面板几何】变：
            //     屏幕像素 x = BX0 + 3*(BW+GAP) + BW/2
            //     BW=78 时 = 279 -> 原始 2232（改 7 个按钮之前的值）
            //     BW=66 时 = 237 -> 原始 1896
            //     改 UI_BW / DISP_UI_NB 之后这里必须跟着改，否则"点不到按钮"。
            tp_force_x = 12'd1896;      // 按钮 3（GAIN）中心的原始 X
            tp_force_y = 12'd4048;      // 按钮 3 中心的原始 Y
            // 触摸是每 10 ms 轮询一次，所以至少要跑一个轮询周期 + SPI 事务
            repeat (600000) @(posedge clk_sys);     // 12.5 ms（一个轮询周期多一点）
            // 松开
            tp_force_x = 12'hFFF; tp_force_y = 12'hFFF;
            repeat (600000) @(posedge clk_sys);
            if (dut.ui_wave_gain === g0) begin
                n_err = n_err + 1;
                $display("  [ERR] 按住 GAIN 按钮后 cfg_wave_gain 没变（还是 %0d）", g0);
                $display("        说明 触摸->命中->同步->步进 这条链有一环没通");
            end else
                $display("  [ok ] 按 GAIN 按钮：cfg_wave_gain %0d -> %0d",
                         g0, dut.ui_wave_gain);

            //-----------------------------------------------------------------
            // [6b] 短按也必须被采到（回归：轮询周期 vs 按下宽度）
            //-----------------------------------------------------------------
            //   ⚠️ 这条是专门为"轮询丢事件"那个 bug 加的。
            //   当初轮询周期 10 ms、而演示扫描的按下只持续 6.4 ms ——
            //   两者相位固定，于是每次都漏掉同样几个按钮（实测只有 STYLE 生效）。
            //
            //   这里按住【6 ms】：只要轮询周期 < 6 ms，任意 6 ms 窗口里
            //   必然落进至少一次轮询，所以这条判据是【确定性】的，
            //   不是碰运气。用旧的 10 ms 周期跑，它一定会失败。
            begin : short_press
                reg [7:0] g1;
                g1 = dut.ui_wave_gain;
                tp_force_x = 12'd1896;      // 还是 GAIN 按钮
                tp_force_y = 12'd4048;
                repeat (288000) @(posedge clk_sys);     // 6 ms
                tp_force_x = 12'hFFF; tp_force_y = 12'hFFF;
                repeat (600000) @(posedge clk_sys);     // 松手后再等一会儿
                if (dut.ui_wave_gain === g1) begin
                    n_err = n_err + 1;
                    $display("  [ERR] 只按 6 ms 的那次没被采到（cfg_wave_gain 还是 %0d）",
                             g1);
                    $display("        说明轮询周期 >= 6 ms，短按会被整个跳过");
                    $display("        —— 这正是'某些按钮好用、某些不好用'的根因");
                end else
                    $display("  [ok ] 只按 6 ms 也被采到：cfg_wave_gain %0d -> %0d",
                             g1, dut.ui_wave_gain);
            end
        end

        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  上电/数据/跨域/显示/按键/UART 全部打通");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

    // 超时保护
    initial begin
        #900_000_000;
        $display(" 结果       : *** FAIL ***  超时");
        $finish;
    end

endmodule
