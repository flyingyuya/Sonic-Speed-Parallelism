//=============================================================================
// tb_i2s_bclk_if.v - i2s_bclk_if 的【独立】验证
//-----------------------------------------------------------------------------
// ⚠️⚠️ 【当前状态：这个 TB 是 FAIL 的，还没有加进 run_iv.sh】⚠️⚠️
//   2026-10 首次运行：RX 读回全是 0，TX 发出也全是 0（两边都 0）。
//   这正是它存在的意义 —— 把"新模块对不对"和"集成 TB 接线对不对"分开。
//
//   下一步（很便宜）：在这个 TB 里把 DUT 的内部信号 dump 出来看
//     u_dut.lr_d / u_dut.rbit / u_dut.sr / u_dut.ash / u_dut.tsr
//   三个 $display 就能定位。修好之后【才】把它加进 scripts/sim/run_iv.sh。
//
// 【为什么先写这个】

//   上一次我直接把这个模块接进 audio_top，结果卡在 TB 基础设施上：
//   同时调试"DUT 对不对"和"TB 接线对不对"两个未知数，白白烧掉一整轮。
//   正确顺序是：先给新模块写个最小独立 TB，把它单独证明是对的，
//   再去动集成。这个文件就是那一步。
//
// 【本 TB 自己产生 BCLK/LRCLK】—— 不依赖 audio_top 里任何东西。
//   严格按 I2S 时序：
//     · BCLK 周期 80ns（真实是 325.5ns，逻辑无关，只为跑得快）
//     · LRCK 在 BCLK【下降沿】翻转；低 = 左，高 = 右
//     · 数据 MSB 在 LRCK 翻转后第一个上升沿被采样
//       -> 发送方必须在【翻转的那个下降沿】就把 MSB 放上线
//
// 【验证项】
//   ① RX 基本解码     左/右声道各喂不同的值，看能不能原样读回来
//   ② RX 位对齐      喂 1<<23（只有 MSB 置位）。错一位就会变成 1<<22，
//                     这是专门抓"位对齐差一"的判据
//   ③ RX 负数/极值    0x800000（最小负）、0x7FFFFF（最大正）
//   ④ TX 基本发送     在 clk 域给值，从 dacdat 上按 I2S 时序收回来比对
//   ⑤ TX 位对齐       同样用 1<<23
//   ⑥ TX 换声道正确   左右给不同值，确认没有串道
//=============================================================================
`timescale 1ns/1ps

module tb_i2s_bclk_if;

    localparam integer DW   = 24;
    localparam integer SLOT = 32;
    localparam integer PAD  = SLOT - DW;

    localparam real TBCLK = 80.0;         // BCLK 周期
    localparam real TCLK  = 20.8333;      // clk_sys 周期

    integer n_err = 0;
`define CHK(cond, msg) \
        if (cond) $display("  [ok ] %0s", msg); \
        else begin n_err = n_err + 1; $display("  [ERR] %0s", msg); end

    //=========================================================================
    // 时钟
    //=========================================================================
    reg clk = 0;
    always #(TCLK/2.0) clk = ~clk;

    reg rst_n = 0;

    //=========================================================================
    // BCLK / LRCLK 发生器（本 TB 自己产生，就是"codec 主机"）
    //=========================================================================
    reg     bclk  = 1'b0;
    reg     lrclk = 1'b0;
    integer mb    = 0;

    initial begin
        forever begin
            #(TBCLK/2.0);
            bclk = 1'b1;
            #(TBCLK/2.0);
            bclk = 1'b0;
            mb   = (mb == 2*SLOT - 1) ? 0 : mb + 1;
            lrclk = (mb >= SLOT);          // ← LRCK 在下降沿翻转（标准 I2S）
        end
    end

    //=========================================================================
    // 本 TB 扮演 codec 的 ADC：把 adc_l/adc_r 串行推给 DUT 的 adcdat
    //=========================================================================
    reg signed [DW-1:0] adc_l = 24'sd0, adc_r = 24'sd0;
    reg                 adcdat = 1'b0;

    // ⚠️ 这两个寄存器【必须初始化】。不初始化的话 a_sh 是 X，
    //    adcdat 就一直是 X，DUT 那边 sr 也全是 X —— 症状是"读回全 0"，
    //    但根本原因在激励侧，不在 DUT。这个 TB 第一版就栽在这儿。
    reg [SLOT-1:0] a_sh   = {SLOT{1'b0}};
    reg            a_lr_d = 1'b0;
    wire           a_lr_chg = (lrclk ^ a_lr_d);
    wire [SLOT-1:0] a_new   = lrclk ? {adc_r, {PAD{1'b0}}} : {adc_l, {PAD{1'b0}}};

    always @(negedge bclk) begin
        a_lr_d <= lrclk;
        if (a_lr_chg) begin
            adcdat <= a_new[SLOT-1];
            a_sh   <= {a_new[SLOT-2:0], 1'b0};
        end else begin
            adcdat <= a_sh[SLOT-1];
            a_sh   <= {a_sh[SLOT-2:0], 1'b0};
        end
    end

    // ── DUT 的 dacdat 要先声明（下面 DAC 采集块要用；Verilog 没有前置声明）──
    wire dacdat;

    //=========================================================================
    // 本 TB 扮演 codec 的 DAC：按 I2S 时序从 DUT 的 dacdat 收回数据
    //=========================================================================
    reg [SLOT-1:0]      d_sh   = {SLOT{1'b0}};
    reg                 d_lr_r = 1'b0;
    reg signed [DW-1:0] cap_l, cap_r;
    reg                 cap_valid;

    wire d_lr_chg = (lrclk ^ d_lr_r);

    always @(posedge bclk) begin
        d_lr_r    <= lrclk;
        cap_valid <= 1'b0;
        if (d_lr_chg) begin
            if (d_lr_r == 1'b0) cap_l <= d_sh[SLOT-1 -: DW];   // 左声道收完
            else begin
                cap_r     <= d_sh[SLOT-1 -: DW];               // 右声道收完 = 一帧完成
                cap_valid <= 1'b1;
            end
            d_sh <= {SLOT{1'b0}};
        end else begin
            d_sh <= {d_sh[SLOT-2:0], dacdat};
        end
    end

    //=========================================================================
    // DUT
    //=========================================================================
    wire signed [DW-1:0] rx_l, rx_r;
    wire                 rx_valid;
    reg  signed [DW-1:0] tx_l = 24'sd0, tx_r = 24'sd0;
    reg                  tx_en = 1'b0;

    i2s_bclk_if #(.SLOT(SLOT), .DATA_BITS(DW), .DW(DW)) u_dut (
        .bclk       (bclk),
        .lrclk      (lrclk),
        .adcdat     (adcdat),
        .dacdat     (dacdat),
        .clk        (clk),
        .rst_n      (rst_n),
        .rx_l       (rx_l),
        .rx_r       (rx_r),
        .rx_valid   (rx_valid),
        .tx_l       (tx_l),
        .tx_r       (tx_r),
        .tx_en      (tx_en),
        .dbg_rx_seen(),
        .dbg_tx_lr  ()
    );

    //=========================================================================
    // 调试：每帧起点（LRCK 下降沿）打印一次 DUT 内部状态
    //   这一类问题（收不到数据）光看接口是看不出来的，必须把内部打出来。
    //=========================================================================
    integer dbg_n = 0;
    always @(negedge lrclk) begin
        if (rst_n && dbg_n < 12) begin
            dbg_n = dbg_n + 1;
            $display("    [dbg%0d] lr_d=%b rbit=%0d sr=%06h l_acc=%06h r_acc=%06h",
                     dbg_n, u_dut.lr_d, u_dut.rbit,
                     u_dut.sr[23:0], u_dut.l_acc, u_dut.r_acc);
            $display("            rx_tog=%b | tsr=%08h | adcdat=%b",
                     u_dut.rx_tog, u_dut.tsr, adcdat);
        end
    end

    // 前 40 个 BCLK 逐个打印：看清 TB 的激励到底出了什么
    integer pcn = 0;
    always @(negedge bclk) begin
        if (pcn < 40) begin
            $display("      [bclk%02d] lrclk=%b a_lr_chg=%b a_new31=%b adcdat=%b a_sh=%08h",
                     pcn, lrclk, a_lr_chg, a_new[SLOT-1], adcdat, a_sh);
            pcn = pcn + 1;
        end
    end

    //=========================================================================
    // 工具任务
    //=========================================================================
    // 等在 clk 域收到 n 帧
    task wait_rx;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1) begin
                @(posedge clk);
                while (!rx_valid) @(posedge clk);
                @(negedge clk);              // 让 rx_l/rx_r 稳定后再读
            end
        end
    endtask

    // 等一帧 TX 完成（cap_valid 在 bclk 域，用它当节拍）
    task wait_tx;
        begin
            @(posedge cap_valid);
            @(negedge clk);
        end
    endtask

    integer i;

    //=========================================================================
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_i2s_bclk_if.vcd");
            $dumpvars(0, tb_i2s_bclk_if);
        end

        $display("");
        $display("============================================================");
        $display(" i2s_bclk_if：I2S 接口（BCLK 直接当时钟）");
        $display("============================================================");
        $display("  BCLK 周期 %.0f ns，clk %.0f ns，槽 %0d 位，数据 %0d 位",
                 TBCLK, TCLK, SLOT, DW);
        $display("");

        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;

        //---------------------------------------------------------------------
        $display(" [1] RX 基本解码：左右各喂一个值，应原样读回");
        adc_l = 24'sd1234567;
        adc_r = -24'sd7654321;
        wait_rx(2);
        $display("      喂 L=%0d R=%0d  ->  读回 L=%0d R=%0d",
                 adc_l, adc_r, rx_l, rx_r);
        `CHK(rx_l == adc_l && rx_r == adc_r, "左右声道都原样读回");

        //---------------------------------------------------------------------
        $display("");
        $display(" [2] ⭐ RX 位对齐：喂 1<<23（只有 MSB 置位）");
        //   错一位就会读成 1<<22 —— 这是专门抓"位对齐差一"的判据
        adc_l = 24'sh800000;
        adc_r = 24'sd0;
        wait_rx(2);
        $display("      喂 0x800000  ->  读回 0x%06X", rx_l[23:0]);
        `CHK(rx_l == 24'sh800000, "MSB 位置正确（没有差一位）");

        //---------------------------------------------------------------------
        $display("");
        $display(" [3] RX 极值：最小负 / 最大正");
        adc_l = -24'sh800000;
        adc_r =  24'sh7FFFFF;
        wait_rx(2);
        $display("      喂 L=0x800000 R=0x7FFFFF  ->  读回 L=0x%06X R=0x%06X",
                 rx_l[23:0], rx_r[23:0]);
        `CHK(rx_l == -24'sh800000 && rx_r == 24'sh7FFFFF, "负满量程和正满量程都对");

        //---------------------------------------------------------------------
        $display("");
        $display(" [4] ⭐ TX 基本发送 + 位对齐");
        tx_l = 24'sh800000;             // 同样用 MSB-only 抓差一位
        tx_r = -24'sd1357246;
        tx_en = 1'b1;
        @(posedge clk);
        tx_en = 1'b0;                    // 送一次就够（模块会保持）
        wait_tx;
        $display("      喂 0x800000  ->  收回 0x%06X", cap_l[23:0]);
        `CHK(cap_l == 24'sh800000, "TX 的 MSB 位置正确");

        //---------------------------------------------------------------------
        $display("");
        $display(" [5] TX 换声道：左右不能串道");
        tx_l =  24'sd1111111;
        tx_r = -24'sd2222222;
        tx_en = 1'b1;
        @(posedge clk);
        tx_en = 1'b0;
        wait_tx;
        wait_tx;                         // 多等一帧，确保这次的值已经出完
        $display("      喂 L=%0d R=%0d  ->  收回 L=%0d R=%0d",
                 24'sd1111111, -24'sd2222222, cap_l, cap_r);
        `CHK(cap_l == 24'sd1111111 && cap_r == -24'sd2222222, "左右没有串道");

        //---------------------------------------------------------------------
        $display("");
        $display(" [6] RX 连续多帧：换值要能跟上（没有卡死）");
        begin : multi
            integer bad;
            bad = 0;
            for (i = 0; i < 10; i = i + 1) begin
                adc_l = i * 24'sd100003 - 24'sd500000;
                adc_r = -i * 24'sd77777;
                wait_rx(2);
                if (rx_l !== adc_l || rx_r !== adc_r) begin
                    bad = bad + 1;
                    $display("      第 %0d 帧：喂 L=%0d R=%0d 读回 L=%0d R=%0d",
                             i, adc_l, adc_r, rx_l, rx_r);
                end
            end
            `CHK(bad == 0, "连续 10 帧换值全部跟上");
        end

        //---------------------------------------------------------------------
        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  RX 解码/位对齐/极值 + TX 发送/位对齐/换声道 全对");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

    // 超时保护
    initial begin
        #2_000_000;
        $display("  [超时] TB 卡住了");
        $finish;
    end

endmodule
