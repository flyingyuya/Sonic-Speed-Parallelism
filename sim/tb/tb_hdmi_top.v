//=============================================================================
// tb_hdmi_top.v —— HDMI 输出包装层的测试（像素流 -> TMDS）
//=============================================================================
// 【本 TB 的定位】
//   第一版 hdmi_top 自带 800x600 时序和彩条图案，那个 TB 验的是"时序+图案"。
//   现在 hdmi_top 已经退化成纯物理层包装（像素流进来、TMDS 出去），
//   时序和图案由上游 disp_top 负责（它的 TB 已经在验了）。
//   所以本 TB 只验【这一层自己要负责的事】：
//     ① hdmi_out_en 恒 0（板上低有效）
//     ② 送进已知像素时，三条 TMDS 数据线不是 X（编码器+串行器在动）
//     ③ 消隐期（de=0）蓝通道出的是控制码，不是像素
//     ④ 时钟通道 = 像素时钟（不编码、不串行化）
//
// 【不验】串行位序、DDR 相位、差分电平 —— 只能上板（责任边界第一版就定过）。
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_hdmi_top;

    reg        rst_n = 1'b0;
    reg        clk_hdmi = 1'b0;
    reg        clk_5x   = 1'b0;

    reg  [23:0] pix_rgb = 24'h000000;
    reg         pix_de = 1'b0;
    reg         pix_hs = 1'b1;
    reg         pix_vs = 1'b1;

    wire c_p, c_n, d0_p, d0_n, d1_p, d1_n, d2_p, d2_n, oen;

    integer n_fail = 0;
    integer n_chk  = 0;

    hdmi_top dut (
        .rst_n(rst_n),
        .clk_hdmi(clk_hdmi), .clk_5x(clk_5x),
        .pix_rgb(pix_rgb), .pix_de(pix_de), .pix_hs(pix_hs), .pix_vs(pix_vs),
        .tmds_clk_p(c_p), .tmds_clk_n(c_n),
        .tmds_d0_p(d0_p), .tmds_d0_n(d0_n),
        .tmds_d1_p(d1_p), .tmds_d1_n(d1_n),
        .tmds_d2_p(d2_p), .tmds_d2_n(d2_n),
        .hdmi_out_en(oen)
    );

    always #12.5 clk_hdmi = ~clk_hdmi;
    always #2.5  clk_5x   = ~clk_5x;

    task chk;
        input [1023:0] name;
        input          got;
        input          exp;
        begin
            n_chk = n_chk + 1;
            if (got !== exp) begin
                n_fail = n_fail + 1;
                $display("  [ERR] %0s : 得到 %0b，期望 %0b", name, got, exp);
            end else
                $display("  [OK ] %0s : %0b", name, got);
        end
    endtask

    initial begin
        $display("==================== tb_hdmi_top ====================");

        repeat (4) @(negedge clk_hdmi);
        rst_n = 1'b1;
        repeat (8) @(negedge clk_hdmi);

        //---------------------------------------------------------------------
        // ① 使能
        //---------------------------------------------------------------------
        chk("hdmi_out_en 恒 0（板上低有效）", oen, 1'b0);

        //---------------------------------------------------------------------
        // ② 像素期：送入已知颜色，TMDS 不应是 X
        //---------------------------------------------------------------------
        pix_de = 1'b1; pix_hs = 1'b1; pix_vs = 1'b1; pix_rgb = 24'hFFFFFF;
        repeat (10) @(negedge clk_hdmi);
        n_chk = n_chk + 1;
        if ((^d0_p === 1'bx) || (^d1_p === 1'bx) || (^d2_p === 1'bx)) begin
            n_fail = n_fail + 1;
            $display("  [ERR] 像素期 TMDS 数据线出现 X");
        end else
            $display("  [OK ] 像素期 TMDS 三条数据线都是确定值");

        // 编码结果应该等于"白色"的编码（三个通道同一个值，但各自独立算）
        $display("       白色 -> 蓝 bd=%010b 绿 gd=%010b 红 rd=%010b",
                 dut.u_tmds.bd, dut.u_tmds.gd, dut.u_tmds.rd);
        n_chk = n_chk + 1;
        if ((dut.u_tmds.bd === dut.u_tmds.gd) && (dut.u_tmds.gd === dut.u_tmds.rd)) begin
            $display("  [OK ] 三通道同色时编码结果相同（符合预期）");
        end else begin
            n_fail = n_fail + 1;
            $display("  [ERR] 三通道同色但编码不同（de 或数据通路接错？）");
        end

        //---------------------------------------------------------------------
        // ③ 消隐期：蓝通道出控制码
        //
        //   ⚠️ 索引顺序是 {C1, C0}，而蓝通道接的是 C0=hsync、C1=vsync。
        //      所以 hsync=0 / vsync=1 对应 {c1,c0} = 2'b10 -> 0101010100。
        //      第一版我按 {c0,c1} 的心算写了 0010101011（那是 hsync=1/vsync=0），
        //      判据反而帮我纠正了这个顺序错误。
        //      对照表（DVI/HDMI 通用控制码）：
        //        {c1,c0} = 00 -> 1101010100
        //                  01 -> 0010101011
        //                  10 -> 0101010100
        //                  11 -> 1010101011
        //---------------------------------------------------------------------
        pix_de = 1'b0; pix_hs = 1'b0; pix_vs = 1'b1;
        repeat (10) @(negedge clk_hdmi);
        n_chk = n_chk + 1;
        if (dut.u_tmds.bd !== 10'b0101010100) begin
            n_fail = n_fail + 1;
            $display("  [ERR] 消隐期蓝通道编码 = %010b，期望 0101010100（{c1,c0}=10）",
                     dut.u_tmds.bd);
        end else
            $display("  [OK ] 消隐期 {c1,c0}=10 -> 蓝通道 0101010100（控制码正确）");
        // 绿/红通道的控制位固定为 0，所以是 c1c0=00 -> 1101010100
        n_chk = n_chk + 1;
        if (dut.u_tmds.gd !== 10'b1101010100) begin
            n_fail = n_fail + 1;
            $display("  [ERR] 消隐期绿通道编码 = %010b，期望 1101010100", dut.u_tmds.gd);
        end else
            $display("  [OK ] 消隐期绿/红通道 1101010100（c1c0=00）");

        //---------------------------------------------------------------------
        // ④ 时钟通道 = 像素时钟
        //---------------------------------------------------------------------
        @(negedge clk_hdmi); #1;
        n_chk = n_chk + 1;
        if (c_p !== clk_hdmi) begin
            n_fail = n_fail + 1;
            $display("  [ERR] 时钟通道 %0b 与像素时钟 %0b 不一致", c_p, clk_hdmi);
        end else
            $display("  [OK ] 时钟通道 = 像素时钟（不编码不串行化）");

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
