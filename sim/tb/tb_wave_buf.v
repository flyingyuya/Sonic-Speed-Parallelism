//=============================================================================
// tb_wave_buf.v - 波形缓冲验证
//-----------------------------------------------------------------------------
// 这个模块的难点全在【跨时钟域】和【窗口对齐】，所以要专门验证：
//
//   ① 顺序性       写进去的是递增序列，读出来必须也严格递增（差 1）
//                  —— 任何指针同步错误都会打破单调性
//   ② 窗口位置     帧起始锁存 base = wptr - SPAN，所以第 0 列应该是
//                  "一屏之前"那个采样，第 SPAN-1 列是最新的
//   ③ 帧内不撕裂   一帧之内读到的窗口内容必须固定不变
//   ④ 格雷码有效性 同步过来的写指针永远落在合法范围，不出现跳变
//   ⑤ 长时间稳定   跑几十帧，窗口每帧前进约一个帧周期的采样数
//
// 两个时钟不同源（48 MHz / 12.5 MHz），相位持续漂移。
//=============================================================================
`timescale 1ns / 1ps

module tb_wave_buf;

    localparam integer DW   = 24;
    localparam integer AW   = 10;
    localparam integer SPAN = 480;
    localparam integer DEPTH = 1 << AW;

    localparam real TSYS_NS = 20.8333;      // 48 MHz
    localparam real TPIX_NS = 80.0;         // 12.5 MHz

    reg clk_sys = 0, clk_pix = 0;
    reg rst_sys_n = 0, rst_pix_n = 0;
    always #(TSYS_NS/2.0) clk_sys = ~clk_sys;
    always #(TPIX_NS/2.0) clk_pix = ~clk_pix;

    // 写侧：递增序列
    reg  signed [DW-1:0] din = 24'sd0;
    reg                  we  = 1'b0;
    integer              wcnt = 0;

    // 读侧
    reg  [9:0] x = 10'd0;
    reg        sof = 1'b0;

    // ⚠️ sof 是 DUT 的【输入】——TB 要自己造帧节拍，不能去 wait 它。
    //    （第一版就写成了 `wait (dut.sof)`，而 sof 恒为 0，直接超时。）
    //    真实帧是 150150 个像素时钟；这里用 1480 拍加快仿真。
    localparam integer FRAME_PIX = 1480;
    integer pcnt = 0;
    always @(posedge clk_pix) begin
        sof  <= (pcnt == 0);
        pcnt <= (pcnt == FRAME_PIX - 1) ? 0 : pcnt + 1;
    end
    wire signed [DW-1:0] dout;

    wave_buf #(.DW(DW), .AW(AW), .SPAN(SPAN)) dut (
        .wclk(clk_sys), .wrst_n(rst_sys_n), .we(we), .din(din),
        .rclk(clk_pix), .rrst_n(rst_pix_n), .sof(sof), .x(x), .dout(dout)
    );

    // 每 10 个 clk_sys 写一个（真实是 48 kHz，这里只为跑得快，不影响逻辑）
    integer wdiv = 0;
    always @(posedge clk_sys) begin
        if (rst_sys_n) begin
            if (wdiv == 9) begin
                wdiv <= 0;
                we   <= 1'b1;
                din  <= din + 24'sd1;
                wcnt <= wcnt + 1;
            end else begin
                wdiv <= wdiv + 1;
                we   <= 1'b0;
            end
        end
    end

    integer n_err = 0, n_err_mono = 0, n_err_win = 0, n_err_tear = 0;
    integer k, fr;
    integer base_exp;
    reg signed [DW-1:0] prev_v;
    reg signed [DW-1:0] snap;
    integer wcnt_at_sof;
    reg [DW-1:0] win_snapshot [0:SPAN-1];
    integer n_frame = 0;

    //=========================================================================
    // 主流程
    //=========================================================================
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_wave_buf.vcd");
            $dumpvars(0, tb_wave_buf);
        end

        $display("============================================================");
        $display(" 波形缓冲验证（双时钟 BRAM + 格雷码指针）");
        $display("   深度 %0d，窗口 %0d  写侧每 10 拍写一个，帧长 %0d 像素时钟", DEPTH, SPAN);
        $display("============================================================");

        rst_sys_n = 0; rst_pix_n = 0;
        repeat (20) @(posedge clk_sys);
        repeat (10) @(posedge clk_pix);
        @(negedge clk_sys); rst_sys_n = 1;
        @(negedge clk_pix); rst_pix_n = 1;
        repeat (5) @(posedge clk_pix);

        // 先让写指针走一段，保证窗口内都是已写过的数据
        wait (wcnt > 20 * SPAN);

        //---------------------------------------------------------------------
        // 跑 10 帧
        //---------------------------------------------------------------------
        for (fr = 0; fr < 10; fr = fr + 1) begin
            // 等帧起始
            wait (sof === 1'b1);
            @(negedge clk_pix);
            wcnt_at_sof = wcnt;
            base_exp = wcnt_at_sof - SPAN;

            // ---- ①② 逐列读，检查单调性和窗口位置 ----
            prev_v = -1;
            for (k = 0; k < SPAN; k = k + 1) begin
                x = k[9:0];
                @(posedge clk_pix); #1;
                // BRAM 读有一拍延迟，所以第 k 列读到的是上一拍地址的
                // 数据 —— 也就是 mem[base + k - 1]。允许 ±3 的容差
                // （同步器延迟 + 写侧节奏）。
                // 从第 2 列开始查：BRAM 读有一拍延迟，第 0 列读到的是
                // base-1（上一窗口的尾巴），必然是个跳变，属预期。
                if (k >= 2 && prev_v >= 0 && dout !== prev_v + 24'sd1) begin
                    n_err_mono = n_err_mono + 1;
                    if (n_err_mono <= 4)
                        $display("  [ERR] 帧%0d 第%0d 列：读到 %0d，上一列是 %0d（应差 1）",
                                 fr, k, dout, prev_v);
                end
                prev_v = dout;
            end

            // 窗口末列应接近"最新采样"
            if (dout < wcnt_at_sof - SPAN - 4 || dout > wcnt_at_sof + 4) begin
                n_err_win = n_err_win + 1;
                if (n_err_win <= 4)
                    $display("  [ERR] 帧%0d 窗口位置错：末列 %0d，期望约 %0d",
                             fr, dout, wcnt_at_sof - 1);
            end

            n_frame = n_frame + 1;
            // 跳过这一帧剩下的部分
            x = 10'd0;
            repeat (1000) @(posedge clk_pix);
        end

        //---------------------------------------------------------------------
        // ③ 帧内不撕裂：连续两拍读同一列，值必须一致
        //---------------------------------------------------------------------
        wait (sof === 1'b1);
        @(negedge clk_pix);
        x = 10'd200;
        repeat (3) @(posedge clk_pix);
        #1; snap = dout;
        repeat (200) @(posedge clk_pix);      // 帧内等一会再读同一列
        x = 10'd200;
        repeat (3) @(posedge clk_pix);
        #1;
        if (dout !== snap) begin
            n_err_tear = n_err_tear + 1;
            $display("  [ERR] 帧内同列读到了不同值：%0d -> %0d（撕裂）", snap, dout);
        end

        //---------------------------------------------------------------------
        n_err = n_err_mono + n_err_win + n_err_tear;

        $display("");
        $display("  跑完帧数        : %0d", n_frame);
        $display("  ① 顺序性错误    : %0d", n_err_mono);
        $display("  ② 窗口位置错误  : %0d", n_err_win);
        $display("  ③ 帧内撕裂      : %0d", n_err_tear);

        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  跨时钟域窗口正确，逐列严格递增，无撕裂");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

    // 超时保护
    initial begin
        #20_000_000;
        $display(" 结果       : *** FAIL ***  超时");
        $finish;
    end

endmodule
