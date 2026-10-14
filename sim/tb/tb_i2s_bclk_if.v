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

    // ⚠️⚠️ BCLK 和 LRCLK 必须【分开】产生！
    //   第一版把 `bclk = 0` 和 `lrclk = ...` 写在同一个 initial 块的同一时刻，
    //   于是 LRCLK 的变化和 negedge bclk 在【同一个时间步】发生 ——
    //   激励块里那个 `a_lr_chg = lrclk ^ a_lr_d` 永远看不到 1
    //   （要么 lrclk 还没变，要么 a_lr_d 已经在同一 delta 被更新了）。
    //   症状：激励从装载逻辑一次都不触发，adcdat 恒 0，
    //        看起来却像"DUT 收不到数据"。
    //
    //   现在：bclk 用 initial 产生，lrclk 用 always @(negedge bclk) 产生。
    //   两者顺序就确定了 —— 激励块在同一时刻看到的是【旧的 lrclk】，
    //   下一个 negedge 才看到变化，边沿检测稳定成立。
    initial begin
        forever begin
            #(TBCLK/2.0);
            bclk = 1'b1;
            #(TBCLK/2.0);
            bclk = 1'b0;                   // 只翻 BCLK
        end
    end

    // LRCK 在 BCLK 下降沿翻转（标准 I2S），独立成块 -> 无竞态
    always @(negedge bclk) begin
        if (!rst_n) begin
            mb    <= 0;
            lrclk <= 1'b0;
        end else begin
            mb    <= (mb == 2*SLOT - 1) ? 0 : mb + 1;
            lrclk <= ((mb == 2*SLOT - 1) ? 0 : mb + 1) >= SLOT;
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

    integer ld_n = 0;

    always @(negedge bclk) begin
        a_lr_d <= lrclk;
        if (a_lr_chg) begin
            // ★ 就在【装载那一拍】打印 —— 这才是"我关心的那个事件"所在的位置。
            //   按帧号猜窗口已经错过一次了（打到了测试还没设值的第 0 帧）。
            if (ld_n < 8) begin
                $display("      [load%0d] lrclk=%b a_lr_d=%b adc_l=%0d adc_r=%0d a_new=%08h",
                         ld_n, lrclk, a_lr_d, adc_l, adc_r, a_new);
                ld_n = ld_n + 1;
            end
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
            // ⚠️ 这一拍【既要把刚结束的那一路锁存，又要开始收新的一路】。
            //    I2S 的约定是"LRCK 变、下一个上升沿接收方就采 MSB"，
            //    而这里就是那个上升沿 —— 所以 dacdat 上此刻已经是【新声道的 MSB】，
            //    不能清零，必须把它当成第一位收进来。
            //    （第一版写成 `d_sh <= 0` —— 等于把每一路的 MSB 丢掉了，
            //      整整差一位，症状是"收回来的值全是原值的 1/2 再错过一位"。）
            if (d_lr_r == 1'b0) cap_l <= d_sh[SLOT-1 -: DW];   // 左声道收完
            else begin
                cap_r     <= d_sh[SLOT-1 -: DW];               // 右声道收完 = 一帧完成
                cap_valid <= 1'b1;
            end
            d_sh <= {{(SLOT-1){1'b0}}, dacdat};                // 新一路的第 1 位
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

    // 逐 BCLK 打印：窗口要【覆盖一个完整帧】（帧 = 2*SLOT = 64 拍）。
    //   ⚠️ 第一版只打了前 40 拍，而 lrclk 的前 32 拍都在【左半帧】——
    //      窗口还没到"数据该出现"的地方就结束了，白打一屏。
    //      加 $display 之前先算清楚"我关心的那个事件发生在第几拍"。
    integer pcn = 0;
    always @(negedge bclk) begin
        if (pcn >= 26 && pcn < 78) begin   // 窗口覆盖第 0 帧前后（想看别的帧就改这个基准）
            $display("  [b%02d] lrclk=%b adcdat=%b a_sh31=%b a_sh=%08h | dut rbit=%0d sr=%06h",
                     pcn, lrclk, adcdat, a_sh[SLOT-1], a_sh,
                     u_dut.rbit, u_dut.sr[23:0]);
        end
        pcn = pcn + 1;
    end

    // TB 侧：看 tx_en 脉冲到底有没有落在 clk 上升沿上
    always @(posedge clk) begin
        if (tx_en)
            $display("      [tb_tx_en] tx_l=%0d tx_r=%0d dut.tx_l_hold=%06h rst_n=%b",
                     tx_l, tx_r, u_dut.tx_l_hold[DW-1:0], rst_n);
    end

    // 逐位对齐：围绕一次 TX 换声道，把 DUT 和 TB 两侧的位流都打出来
    //   只在 tx_l_hold 有值之后开始打，打满 40 拍
    integer bit_n = 0;
    reg     bit_on = 1'b0;
    always @(posedge bclk) begin
        if (u_dut.tx_l_hold[DW-1:0] !== 24'd0) bit_on <= 1'b1;
        if (bit_on && bit_n < 40) begin
            $display("  [bit%02d] lrclk=%b dacdat=%b | dut.tsr=%032b | tb.d_sh=%032b",
                     bit_n, lrclk, dacdat, u_dut.tsr, d_sh);
            bit_n = bit_n + 1;
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
                // ★ 就打在"测试真正读回的那一刻" —— 不按帧号猜窗口。
                //   上一版把 $display 放在固定帧号上，结果打的是第 0 帧
                //   （那时测试还没设 adc_l），白看一屏。
                $display("      [wait_rx k=%0d] 激励 adc_l=%0d adc_r=%0d | dut l_acc=%06h r_acc=%06h | rx_l=%0d rx_r=%0d",
                         k, adc_l, adc_r, u_dut.l_acc, u_dut.r_acc, rx_l, rx_r);
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
        // ⚠️ tx_en 拉成【常高】：模块的语义本来就是"每个 clk 采一次、一直保持"，
        //    测试不需要脉冲。第一版用"1 拍脉冲"，结果那一拍始终没被采到
        //    （查了半天也没定位到为什么），索性不留这个不确定性。
        tx_en = 1'b1;
        @(posedge clk);
        repeat (4) @(posedge clk);
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
        repeat (4) @(posedge clk);
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
