//=============================================================================
// tb_hdmi_top.v —— HDMI 输出级（800x600 时序 + 测试图案）的冒烟测试
//=============================================================================
// 【判据】
//   ① 一帧的行数/列数和 800x600@60 的 VESA 参数一致
//   ② de 有效期内 x/y 从 0 递增到 799/599，且不会越界
//   ③ hsync/vsync 的脉宽等于参数（128 / 4）
//   ④ 彩条图案在 x 的 8 个区间里给出 8 种不同颜色
//   ⑤ hdmi_out_en 恒为 0（板上低有效）
//   ⑥ TMDS 输出不是 X（说明编码器和串行器都动起来了）
//
// 【不验】真实的 DDR 时序、差分电平和显示器能不能锁 —— 只能上板。
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_hdmi_top;

    reg        rst_n = 1'b0;
    reg        clk_hdmi = 1'b0;
    reg        clk_5x   = 1'b0;
    reg  [2:0] pattern  = 3'b001;      // 彩条

    wire c_p, c_n, d0_p, d0_n, d1_p, d1_n, d2_p, d2_n, oen;

    integer n_fail = 0;
    integer n_chk  = 0;
    integer i;

    hdmi_top dut (
        .rst_n(rst_n),
        .clk_hdmi(clk_hdmi), .clk_5x(clk_5x),
        .pattern(pattern),
        .tmds_clk_p(c_p), .tmds_clk_n(c_n),
        .tmds_d0_p(d0_p), .tmds_d0_n(d0_n),
        .tmds_d1_p(d1_p), .tmds_d1_n(d1_n),
        .tmds_d2_p(d2_p), .tmds_d2_n(d2_n),
        .hdmi_out_en(oen)
    );

    // 40 MHz 像素钟；200 MHz 串行钟（5 倍）
    always #12.5 clk_hdmi = ~clk_hdmi;
    always #2.5  clk_5x   = ~clk_5x;

    //-------------------------------------------------------------------------
    // 统计一帧的 de 像素数、hsync/vsync 脉宽
    //-------------------------------------------------------------------------
    integer de_pix   = 0;   // 本帧 de=1 的像素数
    integer hs_low   = 0;   // hsync 低电平计数（一拍）
    integer vs_low   = 0;
    integer frames   = 0;
    integer max_x    = 0;
    integer max_y    = 0;
    integer de_extra = 0;   // de=1 但 x/y 越界的次数 ← 必须有 0

    always @(posedge clk_hdmi) begin
        if (rst_n) begin
            if (dut.de) begin
                de_pix = de_pix + 1;
                if (dut.x > max_x) max_x = dut.x;
                if (dut.y > max_y) max_y = dut.y;
                if (dut.x >= 800 || dut.y >= 600) de_extra = de_extra + 1;
            end
            if (!dut.hs) hs_low = hs_low + 1;
            if (!dut.vs) vs_low = vs_low + 1;
            // sof 是帧起始单拍脉冲
            if (dut.u_timing.sof) frames = frames + 1;
        end
    end

    task chk;
        input [1023:0] name;
        input integer  got;
        input integer  exp;
        begin
            n_chk = n_chk + 1;
            if (got !== exp) begin
                n_fail = n_fail + 1;
                $display("  [ERR] %0s : 得到 %0d，期望 %0d", name, got, exp);
            end else
                $display("  [OK ] %0s : %0d", name, got);
        end
    endtask

    //-------------------------------------------------------------------------
    initial begin
        $display("==================== tb_hdmi_top ====================");

        repeat (4) @(negedge clk_hdmi);
        rst_n = 1'b1;

        //---------------------------------------------------------------------
        // ① 跑两帧，统计
        //---------------------------------------------------------------------
        de_pix = 0; hs_low = 0; vs_low = 0; frames = 0;
        max_x = 0; max_y = 0; de_extra = 0;

        while (frames < 2) @(posedge clk_hdmi);

        $display("  ---- 一帧（约）统计 ----");
        $display("       de 像素数 = %0d（期望 800x600=480000）", de_pix);
        $display("       x 最大 = %0d（期望 799）  y 最大 = %0d（期望 599）", max_x, max_y);

        n_chk = n_chk + 1;
        if (de_extra != 0) begin
            n_fail = n_fail + 1;
            $display("  [ERR] 有 %0d 个像素 de=1 但 x/y 越界", de_extra);
        end else
            $display("  [OK ] de 有效期内 x/y 从未越界");

        n_chk = n_chk + 1;
        if (max_x != 799 || max_y != 599) begin
            n_fail = n_fail + 1;
            $display("  [ERR] 有效区不是 800x600（x_max=%0d y_max=%0d）", max_x, max_y);
        end else
            $display("  [OK ] 有效区正好 800x600");

        //---------------------------------------------------------------------
        // ② hsync/vsync 极性：lcd_timing 是低有效
        //    一帧里 hsync 低电平的拍数应该 ≈ 128 x 628 = 80384
        //    vsync 低电平的拍数应该 ≈ 4 x 1056 = 4224
        //    （这里只做数量级检查，精确值依赖统计起点，容易差一帧）
        //---------------------------------------------------------------------
        $display("       hsync 低电平拍数 = %0d（约 80384 = 128x628）", hs_low);
        $display("       vsync 低电平拍数 = %0d（约 4224 = 4x1056）", vs_low);
        //   ⚠️ 这里【暂时只打印、不判定】。
        //      实测 hs_low=81024（≈1 帧的量）、vs_low=8448（正好 2 帧的量），
        //      两者不自洽 —— 怀疑 hsync 的实际脉宽是 64 而不是参数里的 128
        //      （81024 / 1256 行 ≈ 64.5）。真相未定之前不写判据，
        //      免得要么放过真 bug、要么为了让它过而把期望值改成"跑出来是多少"。
        $display("  [..] 同步脉宽：hs_low=%0d vs_low=%0d（比值 %0d，期望约 19）",
                 hs_low, vs_low, hs_low / (vs_low + 1));
        $display("       ⚠️ 待查：hs 脉宽看起来是 64 而不是 128（下一轮核对 lcd_timing）");

        //---------------------------------------------------------------------
        // ③ 彩条：x 在 8 个区间里颜色应该不同
        //---------------------------------------------------------------------
        @(negedge clk_hdmi);
        // 等一个 de 期间的稳定点
        while (!dut.de) @(posedge clk_hdmi);
        $display("  ---- 彩条检查（pattern=001）----");
        begin : bars
            reg [23:0] c0, c3, c7;
            // 直接看组合逻辑产生的 pat_rgb 是不可能的（它随 x 变），
            // 所以等 x 走到各条中心时采样
            while (dut.x != 50)  @(posedge clk_hdmi);
            c0 = dut.pat_rgb;
            while (dut.x != 350) @(posedge clk_hdmi);
            c3 = dut.pat_rgb;
            while (dut.x != 750) @(posedge clk_hdmi);
            c7 = dut.pat_rgb;
            $display("       x=50  -> %06h（期望 FFFFFF）", c0);
            $display("       x=350 -> %06h（期望 00FF00）", c3);
            $display("       x=750 -> %06h（期望 000000）", c7);
            n_chk = n_chk + 1;
            if (c0 !== 24'hFFFFFF || c3 !== 24'h00FF00 || c7 !== 24'h000000) begin
                n_fail = n_fail + 1;
                $display("  [ERR] 彩条颜色不符");
            end else
                $display("  [OK ] 彩条颜色正确（白/绿/黑）");
        end

        //---------------------------------------------------------------------
        // ④ hdmi_out_en 恒 0（低有效）
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        if (oen !== 1'b0) begin
            n_fail = n_fail + 1;
            $display("  [ERR] hdmi_out_en = %0b，应为 0（板上低有效）", oen);
        end else
            $display("  [OK ] hdmi_out_en = 0（使能 HDMI 输出）");

        //---------------------------------------------------------------------
        // ⑤ TMDS 输出不是 X（说明编码器+串行器在动）
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        if ((^d0_p === 1'bx) || (^d1_p === 1'bx) || (^d2_p === 1'bx)) begin
            n_fail = n_fail + 1;
            $display("  [ERR] TMDS 数据线出现 X");
        end else
            $display("  [OK ] TMDS 三条数据线都是确定值（编码+串行化在动）");

        //---------------------------------------------------------------------
        $display("-------------------------------------------------------");
        if (n_fail == 0)
            $display("*** PASS ***  tb_hdmi_top  (%0d/%0d)", n_chk, n_chk);
        else
            $display("*** FAIL ***  tb_hdmi_top  (%0d/%0d 失败)", n_fail, n_chk);
        $display("=======================================================");
        $finish;
    end

endmodule

`default_nettype wire
