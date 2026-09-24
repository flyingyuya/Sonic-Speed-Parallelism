//=============================================================================
// tb_clk_gen.v - clk_gen 的仿真测试平台
//-----------------------------------------------------------------------------
// 【为什么这个 TB 不能用 iverilog 跑】
//   clk_gen 内部例化了 IBUFDS / MMCME2_BASE / BUFG 三个 Xilinx 原语，
//   iverilog 没有它们的仿真模型，会报 "unknown module"。
//   必须在 Vivado 里跑（xsim 会自动链接 unisims_ver 库）。
//
// 【这个 TB 验证什么】
//   1. MMCM 能不能锁定（参数非法时永远不会锁）
//   2. 输出频率对不对（在固定时间窗内数周期，比肉眼量波形可靠）
//   注：用 $realtime 而非 $time/$t —— xsim 的 %t 是按仿真精度(ps)打印的，
//       容易把 "1258000" 误读成 1.258 ms（其实是 1258 ns）。
//
// 【预期结果】
//   clk_sys : 48.000 MHz
//   clk_pix : 12.500 MHz
//=============================================================================
`timescale 1ns/1ps

module tb_clk_gen;

    //-------------------------------------------------------------------------
    // 被测信号
    //-------------------------------------------------------------------------
    reg  clk_200m_p = 1'b0;
    reg  clk_200m_n = 1'b1;
    reg  rst_btn_n  = 1'b0;

    wire clk_sys;
    wire clk_pix;
    wire mmcm_locked;

    //-------------------------------------------------------------------------
    // 200 MHz 差分时钟源
    //   周期 5 ns -> 半周期 2.5 ns，_n 恒为 _p 的反相
    //-------------------------------------------------------------------------
    always begin
        #2.5 clk_200m_p = ~clk_200m_p;
             clk_200m_n = ~clk_200m_p;
    end

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    clk_gen u_dut (
        .clk_200m_p  (clk_200m_p),
        .clk_200m_n  (clk_200m_n),
        .rst_btn_n   (rst_btn_n),
        .clk_sys     (clk_sys),
        .clk_pix     (clk_pix),
        .mmcm_locked (mmcm_locked)
    );

    //-------------------------------------------------------------------------
    // 频率测量：在固定时间窗内数上升沿个数
    //-------------------------------------------------------------------------
    localparam integer MEAS_NS = 100_000;      // 测量窗口 100 us

    integer cyc_sys = 0;
    integer cyc_pix = 0;

    always @(posedge clk_sys) cyc_sys = cyc_sys + 1;
    always @(posedge clk_pix) cyc_pix = cyc_pix + 1;

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    integer lock_wait;

    initial begin
        $display("=========================================================");
        $display(" clk_gen 仿真：200MHz 差分 -> 48MHz + 12.5MHz");
        $display("=========================================================");

        // 复位保持 10 个 200MHz 周期（MMCM 要求 RST 至少 3 个 CLKIN 周期）
        repeat (10) @(posedge clk_200m_p);
        rst_btn_n = 1'b1;
        $display("[%0.1f ns] 释放复位", $realtime);

        // 等 MMCM 锁定（带超时，避免参数非法时仿真卡死）
        lock_wait = 0;
        while (!mmcm_locked && lock_wait < 2_000_000) begin
            @(posedge clk_200m_p);
            lock_wait = lock_wait + 1;
        end

        if (!mmcm_locked) begin
            $display("[%0.1f ns] *** 失败：MMCM 一直没锁定 ***", $realtime);
            $display("  可能原因：MMCM 参数非法（VCO 超出 600~1200MHz 等）");
            $display("  -> 看 Vivado 综合日志里的 MMCM 相关 CRITICAL WARNING");
            $finish;
        end
        $display("[%0.1f ns] MMCM 已锁定（等待 %0d 个 200MHz 周期）", $realtime, lock_wait);

        // 从锁定后开始测，先清零计数器
        cyc_sys = 0;
        cyc_pix = 0;

        #(MEAS_NS);

        // 窗口 100us 内的周期数 -> 频率(MHz) = 周期数 / 100
        $display("---------------------------------------------------------");
        $display(" 测量窗口            : %0d ns", MEAS_NS);
        $display(" clk_sys  周期数     : %0d", cyc_sys);
        $display("          -> 实测频率: %0.4f MHz   (期望 48.0000)", cyc_sys / 100.0);
        $display(" clk_pix  周期数     : %0d", cyc_pix);
        $display("          -> 实测频率: %0.4f MHz   (期望 12.5000)", cyc_pix / 100.0);
        $display("---------------------------------------------------------");

        if (cyc_sys == 4800 && cyc_pix == 1250)
            $display(" 结果 : *** PASS ***  两路时钟频率都精确正确");
        else
            $display(" 结果 : *** FAIL ***  频率不符，检查 MMCM 参数");

        $display("=========================================================");
        $finish;
    end

    //-------------------------------------------------------------------------
    // 波形转储（Vivado 仿真默认会自己存 wdb，这行是为了兼容其他仿真器）
    //-------------------------------------------------------------------------
    initial begin
        $dumpfile("tb_clk_gen.vcd");
        $dumpvars(0, tb_clk_gen);
    end

endmodule
