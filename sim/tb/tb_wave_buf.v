//=============================================================================
// tb_wave_buf.v - 波形缓冲验证（触发采集 + 双 bank 乒乓）
//-----------------------------------------------------------------------------
// 这个模块的难点有两块：跨时钟域握手、以及"触发"这件事本身对不对。
// 所以要专门验证：
//
//   ① 触发点对齐    向上过零那一刻就是 x=0 列。
//                   用 64 个采样一周期的正弦，触发必然落在相位 0，
//                   于是整屏 480 个点都应该等于 sin(2*pi*c/64) ——
//                   逐点比对。这一条同时证明了"没丢点、没错位"。
//   ② 迟滞有效      幅度低于 TH 的信号永远碰不到迟滞闸门 -> 不触发。
//   ③ 画面静止      连续两帧读到的 480 个点【完全相同】。
//                   ← 这一条就是"零点固定、不滑动"。
//   ④ 不撕裂        一帧之内所有列来自同一个 bank（由 ①②③ 联合保证）。
//   ⑤ 自动触发兜底  没有过零的信号，等够 TO_MAX 也要强行抓一帧，
//                   否则画面永久冻住（上板时极难排查）。
//   ⑥ 握手不死锁    长时间跑，完成次数持续增长。
//
// 两个时钟不同源（48 MHz / 12.5 MHz），相位持续漂移。
//
// ⚠️ TB 自己造帧节拍时，sof 必须和 x==0 【同一拍】，
//    否则采集整屏的循环会错开一列。（真实 lcd_timing 里 sof 在行同步处，
//    远早于有效区，所以那边不存在这个问题；这里是对齐到最坏情况。）
//=============================================================================
`timescale 1ns / 1ps

module tb_wave_buf;

    //--------------------------------------------------------------- 参数 ---
    localparam integer DW       = 24;
    localparam integer AW       = 10;
    localparam integer SPAN     = 480;
    localparam integer TH       = 131072;       // 满量程的 1/64
    localparam integer TO_MAX_A = 65535;        // 主 DUT：大到不会自动触发
    localparam integer TO_MAX_B = 100;          // 辅助 DUT：测自动兜底
    localparam real    AMP      = 8000000.0;    // 约 0.95 满量程
    localparam integer PERIOD   = 64;           // 正弦周期 = 64 个采样

    localparam real    TSYS_NS  = 20.8333;      // 48 MHz
    localparam real    TPIX_NS  = 80.0;         // 12.5 MHz

    localparam integer WDIV      = 8;           // 每 8 个 clk_sys 出一个采样
    localparam integer FRAME_PIX = 1200;        // TB 里的帧长（真实是 150150）

    //--------------------------------------------------------------- 声明 ---
    //   ⚠️ 全部声明放在最前面。Verilog 没有前置声明，
    //      下面 always 里用到的 reg/integer 必须已经存在。
    integer n_err = 0;

    reg clk_sys = 0, clk_pix = 0;
    reg rst_sys_n = 0, rst_pix_n = 0;

    // 采样源
    integer mode = 0;                           // 0=强正弦 1=弱正弦 2=恒 0
    integer snum = 0;
    reg  signed [DW-1:0] din = 24'sd0;
    reg                  we  = 1'b0;
    integer wdiv = 0;

    // 帧节拍
    integer pcnt = 0;
    wire    sof  = (pcnt == 0);                 // 组合：和 x==0 同拍
    wire [9:0] x = pcnt[9:0];

    // 读回整屏
    reg  [9:0] xq = 10'd0;
    reg signed [DW-1:0] got [0:SPAN-1];
    reg  collecting = 1'b0;

    // 主 DUT
    wire signed [DW-1:0] dout;
    wire trig_pulse, done_pulse;
    integer trig_cnt = 0;
    integer n_done   = 0;

    // 辅助 DUT（自动触发）
    reg  signed [DW-1:0] din_b = 24'sd0;
    reg                  we_b  = 1'b0;
    wire signed [DW-1:0] dout_b;
    wire trig_b, done_b;
    integer trig_b_n = 0;

    // 数据
    integer i;
    integer bad;
    integer guard;
    reg signed [DW-1:0] sine    [0:SPAN-1];
    reg signed [DW-1:0] frame_a [0:SPAN-1];
    reg signed [DW-1:0] frame_b [0:SPAN-1];
    integer n_trig_before, n_trig_after;
    integer n_done_before, n_done_after;

`define CHK(cond, msg) \
        if (cond) $display("  [ok ] %0s", msg); \
        else begin n_err = n_err + 1; $display("  [ERR] %0s", msg); end

    //--------------------------------------------------------------- 时钟 ---
    always #(TSYS_NS/2.0) clk_sys = ~clk_sys;
    always #(TPIX_NS/2.0) clk_pix = ~clk_pix;

    //----------------------------------------------------------- 采样发生器 ---
    function signed [DW-1:0] gen_sample;
        input integer m;
        input integer n;
        real ang;
        begin
            ang = 2.0 * 3.141592653589793 * (n % PERIOD) / PERIOD;
            if (m == 0)      gen_sample = $rtoi(AMP * $sin(ang));
            else if (m == 1) gen_sample = $rtoi((AMP/160.0) * $sin(ang));
            else             gen_sample = 24'sd0;
        end
    endfunction

    always @(posedge clk_sys) begin
        if (!rst_sys_n) begin
            we   <= 1'b0;
            wdiv <= 0;
            snum <= 0;
        end else if (wdiv == WDIV-1) begin
            wdiv <= 0;
            we   <= 1'b1;
            din  <= gen_sample(mode, snum);
            snum <= snum + 1;
        end else begin
            wdiv <= wdiv + 1;
            we   <= 1'b0;
        end
    end

    //--------------------------------------------------------------- 帧节拍 ---
    always @(posedge clk_pix)
        pcnt <= (pcnt == FRAME_PIX - 1) ? 0 : pcnt + 1;

    //------------------------------------------------------------ 读回整屏 ---
    //   BRAM 同步读有一拍延迟：t 拍送地址、t+1 拍数据才有效。
    //   所以要【配对】采：把 x 也打一拍，再和 dout 一起采样。
    //   （账本里"TB 看到的和 DUT 里的不是一回事"已经栽过好几次了。）
    always @(posedge clk_pix) xq <= x;

    always @(posedge clk_pix)
        if (collecting && (xq < SPAN)) got[xq] <= dout;

    always @(posedge clk_sys) begin
        if (!rst_sys_n) begin
            trig_cnt <= 0;
            n_done   <= 0;
        end else begin
            if (trig_pulse) trig_cnt <= trig_cnt + 1;
            if (done_pulse) n_done   <= n_done + 1;
        end
    end

    //--------------------------------------------------------------- 主 DUT ---
    wave_buf #(
        .DW(DW), .AW(AW), .SPAN(SPAN), .TH(TH), .TO_MAX(TO_MAX_A)
    ) dut (
        .wclk(clk_sys), .wrst_n(rst_sys_n), .we(we), .din(din),
        .rclk(clk_pix), .rrst_n(rst_pix_n), .sof(sof), .x(x), .dout(dout),
        .trig_pulse(trig_pulse), .done_pulse(done_pulse)
    );

    //------------------------------------------------------------ 辅助 DUT ---
    //   第 5 项要测自动触发，需要一个小 TO_MAX。用独立实例，参数互不干扰。
    always @(posedge clk_sys) we_b <= rst_sys_n;      // 每拍一个采样，值恒 0

    always @(posedge clk_sys)
        if (!rst_sys_n) trig_b_n <= 0;
        else if (trig_b) trig_b_n <= trig_b_n + 1;

    wave_buf #(
        .DW(DW), .AW(AW), .SPAN(SPAN), .TH(TH), .TO_MAX(TO_MAX_B)
    ) dut_b (
        .wclk(clk_sys), .wrst_n(rst_sys_n), .we(we_b), .din(din_b),
        .rclk(clk_pix), .rrst_n(rst_pix_n), .sof(sof), .x(x), .dout(dout_b),
        .trig_pulse(trig_b), .done_pulse(done_b)
    );

    //=========================================================================
    // 读一帧
    //=========================================================================
    task grab_frame;
        begin
            // 等这一帧抓满（写侧抓满后会等读侧取走，所以此后必有一次 sof）
            while (!done_pulse) @(posedge clk_sys);
            // 等到帧起始那一拍（pcnt==0）
            while (pcnt != 0) @(posedge clk_pix);
            // sof 当拍 x=0；收集 pcnt=1..SPAN 这一拍读到的列 0..SPAN-1
            collecting = 1'b1;
            guard = 0;
            while (pcnt != SPAN) begin
                @(posedge clk_pix);
                guard = guard + 1;
                if (guard > 4*FRAME_PIX) begin
                    $display("  [ERR] 等整屏超时");
                    guard = 0;
                    disable grab_frame;
                end
            end
            @(posedge clk_pix);
            collecting = 1'b0;
        end
    endtask

    task do_reset;
        begin
            rst_sys_n = 0; rst_pix_n = 0;
            repeat (10) @(posedge clk_sys);
            rst_sys_n = 1; rst_pix_n = 1;
            repeat (10) @(posedge clk_sys);
        end
    endtask

    //=========================================================================
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_wave_buf.vcd");
            $dumpvars(0, tb_wave_buf);
        end

        // 参考：整屏应该等于 sin 的第 0..SPAN-1 个点（触发点必在相位 0）
        for (i = 0; i < SPAN; i = i + 1) sine[i] = gen_sample(0, i);

        do_reset;

        $display("");
        $display("============================================================");
        $display(" wave_buf：触发采集 + 双 bank 乒乓");
        $display("============================================================");
        $display("  正弦周期 %0d 采样，一屏 %0d 点（= %.2f 个周期）",
                 PERIOD, SPAN, SPAN*1.0/PERIOD);
        $display("");

        //---------------------------------------------------------------------
        $display(" [1] 触发点对齐：x=0 列必须是向上过零点");
        mode = 0; snum = 0;
        repeat (3) grab_frame;
        $display("      x=0 读到 %0d，x=1 读到 %0d，x=2 读到 %0d",
                 got[0], got[1], got[2]);
        `CHK((got[0] >= -200000) && (got[0] <= 200000),
             "x=0 列在零点附近（触发点是向上过零）");
        `CHK(got[1] > 0, "x=1 列已在正半周（说明方向是向上）");

        //---------------------------------------------------------------------
        $display("");
        $display(" [2] 整屏逐点比对：480 个点全部等于 sin(2*pi*c/%0d)", PERIOD);
        bad = 0;
        for (i = 0; i < SPAN; i = i + 1)
            if (got[i] !== sine[i]) bad = bad + 1;
        if (bad != 0)
            for (i = 0; i < SPAN; i = i + 1)
                if ((got[i] !== sine[i]) && (i < 6))
                    $display("      列 %0d：读到 %0d，期望 %0d", i, got[i], sine[i]);
        `CHK(bad == 0, "480 列逐点一致（不丢点、不错位、不撕裂）");

        //---------------------------------------------------------------------
        $display("");
        $display(" [3] 画面静止：连续两帧内容完全相同");
        for (i = 0; i < SPAN; i = i + 1) frame_a[i] = got[i];
        repeat (2) grab_frame;
        for (i = 0; i < SPAN; i = i + 1) frame_b[i] = got[i];
        bad = 0;
        for (i = 0; i < SPAN; i = i + 1)
            if (frame_a[i] !== frame_b[i]) bad = bad + 1;
        `CHK(bad == 0, "两帧逐点相同 —— 这就是'零点固定、不滑动'");

        //---------------------------------------------------------------------
        $display("");
        $display(" [4] 迟滞有效：幅度低于 TH 的信号不触发");
        //   先复位，把迟滞闸门 below 清干净（否则可能残留 1，误触发一次）
        do_reset;
        mode = 1;                                   // 弱正弦
        repeat (200) @(posedge clk_sys);            // 让它先跑起来
        n_trig_before = trig_cnt;
        repeat (20000) @(posedge clk_sys);
        n_trig_after = trig_cnt;
        $display("      20000 拍里触发了 %0d 次（TH=%0d，信号幅度约 %0d）",
                 n_trig_after - n_trig_before, TH, $rtoi(AMP/160.0));
        `CHK(n_trig_after == n_trig_before, "弱信号一次都没触发（迟滞挡住了）");

        //---------------------------------------------------------------------
        $display("");
        $display(" [5] 自动触发兜底：恒 0 信号，等够 TO_MAX=%0d 也要抓一帧", TO_MAX_B);
        repeat (200) @(posedge clk_sys);
        n_trig_before = trig_b_n;
        repeat (40000) @(posedge clk_sys);
        $display("      辅助 DUT 触发了 %0d 次", trig_b_n - n_trig_before);
        `CHK((trig_b_n - n_trig_before) >= 2,
             "没有过零也反复触发了（自动兜底生效）");

        //---------------------------------------------------------------------
        $display("");
        $display(" [6] 握手不死锁：长时间跑，完成次数持续增长");
        mode = 0;
        repeat (4000) @(posedge clk_pix);       // 先让状态稳定下来
        n_done_before = n_done;
        //   一次采集 = 480 采样 x 8 clk_sys = 3840 clk_sys ≈ 80 us
        //   = 1000 个 clk_pix；再加上等帧起始（一帧 1200 clk_pix）
        //   → 一次约 1500~2200 个 clk_pix。给 12000 拍，期望 3 次以上。
        repeat (12000) @(posedge clk_pix);
        n_done_after = n_done;
        $display("      12000 个像素时钟（约 960 us）里完成了 %0d 次采集",
                 n_done_after - n_done_before);
        // 既要"有进展"（不死锁），也要"不是疯跑"（握手真的在起作用）
        `CHK((n_done_after - n_done_before) >= 3, "采集持续推进（写侧没被握手卡死）");
        `CHK((n_done_after - n_done_before) <= 40, "采集速率合理（没在读侧刚取走前就野蛮覆盖）");

        //---------------------------------------------------------------------
        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  触发对齐/迟滞/画面静止/自动兜底/握手全对");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

endmodule
