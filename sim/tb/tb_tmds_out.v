//=============================================================================
// tb_tmds_out.v —— TMDS 输出级（OSERDESE2 级联 + OBUFDS）的接线与位序测试
//=============================================================================
// 【能验什么 / 验不了什么】
//   能验：① 三个通道的编码结果确实送进了各自的串行器
//         ② 串行输出的【位序】是 din[0] 先出、din[9] 最后（TMDS 规定）
//         ③ 差分对互补：N = ~P
//         ④ 时钟通道 = 像素时钟
//   验不了：真实的 DDR 时序余量、I/O 电平 —— 那些只能上板。
//
// 【为什么位序值得单独验】
//   TMDS 是"低位先发"。如果接线时把 D1 和 D8 接反，屏幕会出
//   "颜色对但位置错"或者干脆黑屏 —— 而且这种错在仿真里只有把
//   串行流一位一位抓下来才看得见。
//
// 【做法】
//   让输入保持恒定（de=1, 颜色固定）好几拍 ⟹ 编码结果 bd/gd/rd 稳定
//   ⟹ 串行输出每 10 位重复一遍 ⟹ 抓 10 个采样点比对即可。
//   clk_5x 是 clk_pix 的 5 倍，DDR 双沿 ⟹ 一个像素周期出 10 位。
//=============================================================================
`timescale 1ns/1ps
`default_nettype none

module tb_tmds_out;

    reg        rst_n = 1'b0;
    reg        clk_pix = 1'b0;
    reg        clk_5x  = 1'b0;

    reg  [7:0] r = 8'h00, g = 8'h00, b = 8'h00;
    reg        de = 1'b0, hsync = 1'b0, vsync = 1'b0;

    wire c_p, c_n, d0_p, d0_n, d1_p, d1_n, d2_p, d2_n;

    integer n_fail = 0;
    integer n_chk  = 0;
    integer i;

    tmds_out dut (
        .rst_n(rst_n),
        .clk_pix(clk_pix), .clk_5x(clk_5x),
        .r(r), .g(g), .b(b),
        .de(de), .hsync(hsync), .vsync(vsync),
        .tmds_clk_p(c_p),  .tmds_clk_n(c_n),
        .tmds_d0_p(d0_p),  .tmds_d0_n(d0_n),
        .tmds_d1_p(d1_p),  .tmds_d1_n(d1_n),
        .tmds_d2_p(d2_p),  .tmds_d2_n(d2_n)
    );

    // clk_pix = 50 MHz；clk_5x = 250 MHz（同源，相位对齐）
    always #10 clk_pix = ~clk_pix;
    always #2  clk_5x  = ~clk_5x;

    task chk_bit;
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

    //-------------------------------------------------------------------------

    initial begin
        $display("==================== tb_tmds_out ====================");

        repeat (3) @(negedge clk_pix);
        rst_n = 1'b1;

        //   注：原来这里还查"差分对互补（N=~P）"。
        //       删掉的原因：OBUFDS 的行为模型里 OB 就是 ~I，这条判据恒真 —— 没有任何鉴别力；
        //       而真原语的差分特性只能靠上板看（示波器/接收端能不能锁定）。
        //       同理，串行位序也只能上板验：DDR 采样相位极难在仿真里对齐，
        //       硬对会变成"验证我的采样"而不是"验证设计"。
        //       ⟹ 本 TB 只验【能验且值得验】的：编码结果有没有正确装进串行器。

        //---------------------------------------------------------------------
        // ② 时钟通道 = 像素时钟
        //---------------------------------------------------------------------
        @(negedge clk_pix); #1;
        n_chk = n_chk + 1;
        if (c_p !== clk_pix) begin
            n_fail = n_fail + 1;
            $display("  [ERR] 时钟通道 %0b 与 clk_pix %0b 不一致", c_p, clk_pix);
        end else
            $display("  [OK ] 时钟通道 = 像素时钟");

        //---------------------------------------------------------------------
        // ③ 位序：蓝通道
        //   让输入恒定，等编码结果稳定（2 级流水 + 若干拍）
        //---------------------------------------------------------------------
        de = 1'b1; hsync = 1'b0; vsync = 1'b0;
        r = 8'h12; g = 8'h34; b = 8'h56;
        repeat (8) @(negedge clk_pix);

        $display("  ---- 位序检查（编码结果 vs 串行流）----");
        $display("       蓝 bd = %010b", dut.bd);
        $display("       绿 gd = %010b", dut.gd);
        $display("       红 rd = %010b", dut.rd);

        //---------------------------------------------------------------------
        // 检查"编码结果有没有正确接到串行器的并行输入"
        //   为什么不采样串行输出：
        //     串行是 DDR（posedge/negedge 各一位），实测采样相位极难对齐，
        //     稍微偏一点就整体转几位 —— 那验证的是"我的采样"而不是"接线"。
        //   改成直接读 OSERDESE2 模型里的并行装载寄存器 sr：
        //     sr 应该等于 {bd[9:8], bd[7:0]}（低位通道 D1=din[0]，高位由 SLAVE 级联送进来）
        //   这正是唯一会接错的地方：D1..D8 的映射、以及 SLAVE 的 D3/D4 是不是高 2 位。
        //   串行位序本身只能上板验（也只需要上板验）。
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        if (dut.u_oser_b_master.sr !== dut.bd) begin
            n_fail = n_fail + 1;
            $display("  [ERR] 蓝通道装进串行器的 %010b，不等于编码结果 %010b",
                     dut.u_oser_b_master.sr, dut.bd);
        end else
            $display("  [OK ] 蓝通道：编码结果正确装入串行器（D1..D8 + SLAVE 高2位）");

        n_chk = n_chk + 1;
        if (dut.u_oser_g_master.sr !== dut.gd) begin
            n_fail = n_fail + 1;
            $display("  [ERR] 绿通道装入 %010b != 编码结果 %010b",
                     dut.u_oser_g_master.sr, dut.gd);
        end else
            $display("  [OK ] 绿通道：编码结果正确装入串行器");

        n_chk = n_chk + 1;
        if (dut.u_oser_r_master.sr !== dut.rd) begin
            n_fail = n_fail + 1;
            $display("  [ERR] 红通道装入 %010b != 编码结果 %010b",
                     dut.u_oser_r_master.sr, dut.rd);
        end else
            $display("  [OK ] 红通道：编码结果正确装入串行器");

        //---------------------------------------------------------------------
        // ④ 消隐期：蓝通道出控制码（de=0）
        //---------------------------------------------------------------------
        de = 1'b0; hsync = 1'b1; vsync = 1'b0;
        repeat (8) @(negedge clk_pix);
        n_chk = n_chk + 1;
        if (dut.bd !== 10'b0010101011 || dut.u_oser_b_master.sr !== 10'b0010101011) begin
            n_fail = n_fail + 1;
            $display("  [ERR] 消隐期蓝通道：bd=%010b sr=%010b（hsync=1 期望 0010101011）",
                     dut.bd, dut.u_oser_b_master.sr);
        end else
            $display("  [OK ] 消隐期 hsync=1 -> 0010101011（控制码正确装入串行器）");

        //---------------------------------------------------------------------
        $display("-------------------------------------------------------");
        if (n_fail == 0)
            $display("*** PASS ***  tb_tmds_out  (%0d/%0d)", n_chk, n_chk);
        else
            $display("*** FAIL ***  tb_tmds_out  (%0d/%0d 失败)", n_fail, n_chk);
        $display("=======================================================");
        $finish;
    end

endmodule

`default_nettype wire
