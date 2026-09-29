//=============================================================================
// tb_lcd_timing.v - 480x272 液晶时序发生器验证
//-----------------------------------------------------------------------------
// 时序发生器的 bug 有个特点：波形上"看起来都对"，但一帧可能少几个像素、
// 或者某个同步脉冲差一拍 —— 上板表现为画面偏一边、抖动、或者整个不出图。
// 所以这里不靠肉眼，全部用【一帧总量守恒】+【逐像素遍历】来核对。
//
// 【先搞清楚 DUT 的时序契约】（这是写对检查的前提）
//
//     周期 T   : x/y = 当前扫描位置（组合输出），调用方据此算 rgb_in
//     周期 T+1 : de / hsync / vsync / rgb_out 一起寄存输出
//                rgb_out = rgb_in(T)，即【上一拍 x/y 对应的颜色】
//
//   也就是说 de 与 x 本来就差一拍 —— 这是刻意的：
//   调用方需要当拍的 x/y 才来得及算颜色，而送到屏幕的那一组信号必须互相严格对齐。
//
//   所以正确的检查方式是：
//       · rgb_out  与 de 同拍            （本拍比）
//       · x_d/y_d（上一拍的 x/y）与 de 同拍（本拍比）
//   而不是拿当拍的 x 去对 de。
//
// 七项检查：
//   ① DE 每帧像素数    = H_DISP x V_DISP = 130560
//   ② HSYNC 每帧低电平 = H_SYNC x V_TOTAL = 11726
//   ③ VSYNC 每帧低电平 = V_SYNC x H_TOTAL = 5250
//   ④ 帧周期           = H_TOTAL x V_TOTAL = 150150
//   ⑤ x 必须逐行 0->479 连续递增，DE 期间不能有断点
//   ⑥ y 必须每行加一：0->271
//   ⑦ rgb 对齐         —— rgb_out 必须与 de 同拍，DE 之外恒为 0
//
//   ①②③④ 用【两次 sof 之间的差值】统计，这样正好覆盖完整的一帧，
//   不受复位释放时刻在帧中间的影响。
//=============================================================================
`timescale 1ns / 1ps

module tb_lcd_timing;

    // ---- 与 lcd_timing 保持一致的参数 ----
    localparam integer H_SYNC  = 41;
    localparam integer H_BACK  = 2;
    localparam integer H_DISP  = 480;
    localparam integer H_FRONT = 2;
    localparam integer V_SYNC  = 10;
    localparam integer V_BACK  = 2;
    localparam integer V_DISP  = 272;
    localparam integer V_FRONT = 2;

    localparam integer H_TOTAL = H_SYNC + H_BACK + H_DISP + H_FRONT;   // 525
    localparam integer V_TOTAL = V_SYNC + V_BACK + V_DISP + V_FRONT;   // 286
    localparam real    PCLK_NS = 80.0;                                 // 12.5 MHz

    localparam integer EXP_DE     = H_DISP * V_DISP;                   // 130560
    localparam integer EXP_HS_LOW = H_SYNC * V_TOTAL;                  // 11726
    localparam integer EXP_VS_LOW = V_SYNC * H_TOTAL;                  // 5250
    localparam integer EXP_FRAME  = H_TOTAL * V_TOTAL;                 // 150150

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;

    wire [9:0]  x;
    wire [8:0]  y;
    wire [23:0] rgb_out;
    wire        hsync, vsync, de, sof;

    reg  [23:0] rgb_in;
    always @(*) rgb_in = {x, y, 5'b0};      // 用【当拍】的 x/y 组合算颜色

    lcd_timing #(
        .H_SYNC(H_SYNC), .H_BACK(H_BACK), .H_DISP(H_DISP), .H_FRONT(H_FRONT),
        .V_SYNC(V_SYNC), .V_BACK(V_BACK), .V_DISP(V_DISP), .V_FRONT(V_FRONT)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .rgb_in(rgb_in), .rgb_out(rgb_out),
        .hsync(hsync), .vsync(vsync), .de(de),
        .x(x), .y(y), .sof(sof)
    );

    always #(PCLK_NS / 2.0) clk = ~clk;

    //=========================================================================
    // 上一拍的 x/y（用于和 de/rgb_out 比对）
    //=========================================================================
    reg [9:0] x_d = 10'd0;
    reg [8:0] y_d = 9'd0;
    reg       de_d = 1'b0;
    wire      de_rise = de && !de_d;

    //=========================================================================
    // 统计量（累加）
    //=========================================================================
    integer n_cyc = 0, n_de = 0, n_hs_low = 0, n_vs_low = 0;
    integer sof_cnt = 0;

    // 两次 sof 之间的差值 = 完整一帧
    integer b_cyc = 0, b_de = 0, b_hs = 0, b_vs = 0;
    integer f_cyc = 0, f_de = 0, f_hs = 0, f_vs = 0;
    reg     frame_ready = 1'b0;

    // 结构检查
    integer n_err = 0;
    integer x_exp = 0;
    integer y_exp = 0;
    integer xy_bad = 0;
    integer align_bad = 0;
    integer len_bad = 0;
    integer de_run_len = 0;
    integer n_de_run = 0;
    integer cyc_bad = 0;

    //=========================================================================
    // 逐拍
    //=========================================================================
    always @(posedge clk) begin
        if (rst_n) begin
            n_cyc = n_cyc + 1;
            if (de)     n_de     = n_de + 1;
            if (!hsync) n_hs_low = n_hs_low + 1;
            if (!vsync) n_vs_low = n_vs_low + 1;

            //-----------------------------------------------------------------
            // sof：用相邻两次的差值统计完整一帧
            //-----------------------------------------------------------------
            if (sof) begin
                sof_cnt = sof_cnt + 1;
                if (sof_cnt == 2) begin
                    b_cyc = n_cyc;  b_de = n_de;
                    b_hs  = n_hs_low; b_vs = n_vs_low;
                end else if (sof_cnt == 3) begin
                    f_cyc = n_cyc    - b_cyc;
                    f_de  = n_de     - b_de;
                    f_hs  = n_hs_low - b_hs;
                    f_vs  = n_vs_low - b_vs;
                    frame_ready = 1'b1;
                end
            end

            //-----------------------------------------------------------------
            // ⑤⑥ 逐像素遍历
            //   注意：与 de 对齐的是【上一拍】的 x_d / y_d
            //-----------------------------------------------------------------
            if (de_rise) begin
                n_de_run = n_de_run + 1;
                if (de_run_len != 0 && de_run_len != H_DISP) len_bad = len_bad + 1;
                de_run_len = 0;      // 归零，下面 if(de) 再加到 1（否则会多算一拍）
                if (x_d !== 10'd0) begin
                    xy_bad = xy_bad + 1;
                    if (xy_bad <= 5)
                        $display("  [ERR] t=%0t 行首 x_d=%0d（应为 0）", $time, x_d);
                end
                if (y_d !== y_exp[8:0]) begin
                    xy_bad = xy_bad + 1;
                    if (xy_bad <= 5)
                        $display("  [ERR] t=%0t 行号 y_d=%0d（期望 %0d）", $time, y_d, y_exp);
                end
                y_exp = y_exp + 1;
                if (y_exp == V_DISP) y_exp = 0;
                x_exp = 0;
            end

            if (de) begin
                de_run_len = de_run_len + 1;
                if (x_d !== x_exp[9:0]) begin
                    xy_bad = xy_bad + 1;
                    if (xy_bad <= 5)
                        $display("  [ERR] t=%0t x_d=%0d（期望 %0d）", $time, x_d, x_exp);
                end
                x_exp = x_exp + 1;
            end

            //-----------------------------------------------------------------
            // ⑦ rgb 对齐 + 同步脉冲不得侵入有效区
            //-----------------------------------------------------------------
            if (de) begin
                if (rgb_out !== {x_d, y_d, 5'b0}) begin
                    align_bad = align_bad + 1;
                    if (align_bad <= 3)
                        $display("  [ERR] t=%0t rgb 对齐错：%06h 期望 %06h",
                                 $time, rgb_out, {x_d, y_d, 5'b0});
                end
                if (!hsync || !vsync) begin
                    align_bad = align_bad + 1;
                    if (align_bad <= 3)
                        $display("  [ERR] t=%0t 有效像素区内出现同步脉冲", $time);
                end
            end else begin
                if (rgb_out !== 24'd0) begin
                    align_bad = align_bad + 1;
                    if (align_bad <= 3)
                        $display("  [ERR] t=%0t DE 之外 rgb_out=%06h 不为 0", $time, rgb_out);
                end
            end

            //-----------------------------------------------------------------
            // 存档上一拍
            //-----------------------------------------------------------------
            x_d  <= x;
            y_d  <= y;
            de_d <= de;
        end
    end

    //=========================================================================
    // 主流程
    //=========================================================================
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_lcd_timing.vcd");
            $dumpvars(0, tb_lcd_timing);
        end

        $display("============================================================");
        $display(" 480x272 液晶时序验证");
        $display("   H: SYNC=%0d BACK=%0d DISP=%0d FRONT=%0d TOTAL=%0d",
                 H_SYNC, H_BACK, H_DISP, H_FRONT, H_TOTAL);
        $display("   V: SYNC=%0d BACK=%0d DISP=%0d FRONT=%0d TOTAL=%0d",
                 V_SYNC, V_BACK, V_DISP, V_FRONT, V_TOTAL);
        $display("   像素时钟 %.1f MHz -> 帧率 %.2f Hz",
                 1000.0 / PCLK_NS, (1000.0 / PCLK_NS) * 1.0e6 / EXP_FRAME);
        $display("============================================================");

        rst_n = 1'b0;
        repeat (8) @(posedge clk);
        @(negedge clk); rst_n = 1'b1;

        // 至少跑满 3 帧才能取到一次完整的帧间差值
        wait (frame_ready === 1'b1);
        @(negedge clk);

        // ---- ④ 帧周期 ----
        if (f_cyc !== EXP_FRAME) begin
            cyc_bad = cyc_bad + 1;
            $display("  [ERR] 帧周期 = %0d 拍（期望 %0d）", f_cyc, EXP_FRAME);
        end else
            $display("  [ok ] 帧周期          = %0d 拍 = %0.3f ms  (%.2f Hz)",
                     f_cyc, f_cyc * PCLK_NS / 1.0e6, 1.0e9 / (f_cyc * PCLK_NS));

        // ---- ① DE 像素数 ----
        if (f_de !== EXP_DE) begin
            n_err = n_err + 1;
            $display("  [ERR] DE 像素数 = %0d（期望 %0d = %0d x %0d）",
                     f_de, EXP_DE, H_DISP, V_DISP);
        end else
            $display("  [ok ] DE 像素数        = %0d = %0d x %0d",
                     f_de, H_DISP, V_DISP);

        // ---- ② HSYNC 低电平 ----
        if (f_hs !== EXP_HS_LOW) begin
            n_err = n_err + 1;
            $display("  [ERR] HSYNC 低电平 = %0d（期望 %0d = %0d x %0d）",
                     f_hs, EXP_HS_LOW, H_SYNC, V_TOTAL);
        end else
            $display("  [ok ] HSYNC 低电平     = %0d = %0d x %0d",
                     f_hs, H_SYNC, V_TOTAL);

        // ---- ③ VSYNC 低电平 ----
        if (f_vs !== EXP_VS_LOW) begin
            n_err = n_err + 1;
            $display("  [ERR] VSYNC 低电平 = %0d（期望 %0d = %0d x %0d）",
                     f_vs, EXP_VS_LOW, V_SYNC, H_TOTAL);
        end else
            $display("  [ok ] VSYNC 低电平     = %0d = %0d x %0d",
                     f_vs, V_SYNC, H_TOTAL);

        // ---- ⑤⑥ ----
        if (len_bad != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] DE 连续长度不等于 %0d 的次数 = %0d", H_DISP, len_bad);
        end else
            $display("  [ok ] DE 每行连续 %0d 拍无断点（共 %0d 行）", H_DISP, n_de_run);

        if (xy_bad != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] x/y 遍历错误 %0d 处", xy_bad);
        end else
            $display("  [ok ] x 每行 0->%0d 连续，y 每行 +1 到 %0d",
                     H_DISP - 1, V_DISP - 1);

        // ---- ⑦ ----
        if (align_bad != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] rgb/同步 对齐错误 %0d 处", align_bad);
        end else
            $display("  [ok ] rgb_out 与 de 同拍，DE 之外恒为 0，同步脉冲不侵入有效区");

        if (cyc_bad != 0) n_err = n_err + 1;

        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  480x272 时序七项检查全部守恒");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 类错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

    // 超时保护
    initial begin
        #50_000_000;
        $display(" 结果       : *** FAIL ***  超时");
        $finish;
    end

endmodule
