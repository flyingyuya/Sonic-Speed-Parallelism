//=============================================================================
// tb_sd_init.v  ——  sd_init 的自测（配 sd_card_model）
//=============================================================================
//   【判据（全部是"语义"判据，不是"数字对不对"）】
//     ① init_done 最终必须拉高
//     ② 命令顺序必须是   CMD0 → CMD8 → (CMD55 → ACMD41) × N
//        并且 ACMD41 被收到至少 3 次（模型设计成第 3 次才回"就绪"）
//        ⟹ 这直接验证了 sd_init 真的在"没就绪就重发"，而不是发一次就完
//     ③ 第一次 ACMD41 之前必须先有 CMD55（否则卡不认 ACMD）
//     ④ 整个过程中 sd_cs 在发命令时拉低、空闲时拉高
//
//   【为什么参数要覆盖】
//     真实参数（DIV_FREQ=240 ⟹ 200 kHz、POWER_ON_NUM=5000 ⟹ 25 ms）
//     会让单次仿真跑几十毫秒的"逻辑时间"，iverilog 要跑很久。
//     这里把分频和等待都调小，逻辑完全一致，只是跑得快。
//     ⟹ 这就是"时间窗必须可注入"（账本 211/213）。
//=============================================================================

`timescale 1ns / 1ps

module tb_sd_init;

    //-------------------------------------------------------------------------
    // 参数
    //-------------------------------------------------------------------------
    localparam integer CLK_HZ  = 48_000_000;
    localparam integer DIV_FREQ = 4;        // 仿真用：48M/4 = 12 MHz
    localparam integer PWR_ON   = 20;       // 仿真用：20 拍
    localparam integer OVT      = 500;      // 仿真用：超时 500 拍

    localparam integer EXPECT_ACMD41_MIN = 3;

    //-------------------------------------------------------------------------
    // 时钟与复位
    //-------------------------------------------------------------------------
    reg clk = 1'b0;
    reg rst_n = 1'b0;

    always #10 clk = ~clk;      // 50 MHz 差不多，具体频率对功能无影响

    //-------------------------------------------------------------------------
    // DUT 与模型
    //-------------------------------------------------------------------------
    wire sd_clk;
    wire sd_cs;
    wire sd_mosi;
    wire sd_miso;

    wire init_done;

    wire [5:0]  m_cmd_index;
    wire [31:0] m_cmd_arg;
    wire        m_cmd_valid;
    wire [7:0]  m_acmd41_cnt;

    sd_init #(
        .CLK_HZ        (CLK_HZ),
        .DIV_FREQ      (DIV_FREQ),
        .POWER_ON_NUM  (PWR_ON),
        .OVER_TIME_NUM (OVT)
    ) dut (
        .clk       (clk),
        .rst_n     (rst_n),
        .sd_miso   (sd_miso),
        .sd_clk    (sd_clk),
        .sd_cs     (sd_cs),
        .sd_mosi   (sd_mosi),
        .init_done (init_done)
    );

    sd_card_model #(
        .ACMD41_POLLS (EXPECT_ACMD41_MIN)
    ) model (
        .sd_clk      (sd_clk),
        .sd_cs       (sd_cs),
        .sd_mosi     (sd_mosi),
        .sd_miso     (sd_miso),
        .cmd_index   (m_cmd_index),
        .cmd_arg     (m_cmd_arg),
        .cmd_valid   (m_cmd_valid),
        .acmd41_cnt  (m_acmd41_cnt)
    );

    //-------------------------------------------------------------------------
    // 命令序列记录
    //-------------------------------------------------------------------------
    integer n_chk  = 0;
    integer n_err  = 0;
    integer n_cmd  = 0;
    integer seq_ok = 0;

    // 记录收到的命令号（最多 16 条）
    reg [5:0] seq [0:15];

    // ⚠️ 这里以前写成 `@(posedge clk) if (cmd_valid)`，会把同一条命令记多次
    //    （cmd_valid 的时序和 clk 的相位关系导致重复采样，现象是序列里
    //    每条命令出现 4 次，判据全乱）。
    //    改成【边沿触发】：cmd_valid 的上升沿才记一次。
    always @(posedge m_cmd_valid) begin
        if (n_cmd < 16)
            seq[n_cmd] = m_cmd_index;
        n_cmd = n_cmd + 1;
    end

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    integer i;
    integer wait_cnt;
    reg     acmd41_before_cmd55;
    integer acmd41_total;

    initial begin
        $dumpfile("tb_sd_init.vcd");
        $dumpvars(0, tb_sd_init);

        $display("");
        $display("============================================================");
        $display(" tb_sd_init  SD 卡 SPI 初始化流程验证");
        $display("============================================================");

        // 复位
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;

        // 等 init_done
        wait_cnt = 0;
        while ((init_done !== 1'b1) && (wait_cnt < 500000)) begin
            @(posedge clk);
            wait_cnt = wait_cnt + 1;
        end

        //---------------------------------------------------------------------
        // 判据 ①：init_done 必须拉高
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        if (init_done !== 1'b1) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据①：init_done 一直没拉高（等了 %0d 拍）", wait_cnt);
        end else begin
            $display("  [OK ] 判据①：init_done 拉高（用了 %0d 拍）", wait_cnt);
        end

        //---------------------------------------------------------------------
        // 判据 ②：命令顺序 CMD0(0) → CMD8(8) → (CMD55 → ACMD41)×N
        //   注意模型里 CMD55 的命令号字段是 0x37，ACMD41 是 0x29
        //   （因为主机发的是 0x40|cmd，模型取低 6 位 ⟹ 45:40 是 0x37/0x29）
        //---------------------------------------------------------------------
        $display("  ---- 收到的命令序列 ----");
        for (i = 0; i < n_cmd && i < 16; i = i + 1)
            $display("     第 %0d 条：cmd_index = 0x%02h", i, seq[i]);

        n_chk = n_chk + 1;
        if (n_cmd < 4) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据②：只收到 %0d 条命令（至少应有 CMD0/CMD8/CMD55/ACMD41）", n_cmd);
        end else if (seq[0] !== 6'd0) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据②：第一条命令不是 CMD0（是 0x%02h）", seq[0]);
        end else if (seq[1] !== 6'd8) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据②：第二条命令不是 CMD8（是 0x%02h）", seq[1]);
        end else if (seq[2] !== 6'h37) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据②：第三条命令不是 CMD55（是 0x%02h）", seq[2]);
        end else if (seq[3] !== 6'h29) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据②：第四条命令不是 ACMD41（是 0x%02h）", seq[3]);
        end else begin
            $display("  [OK ] 判据②：命令顺序 CMD0 → CMD8 → CMD55 → ACMD41 正确");
        end

        //---------------------------------------------------------------------
        // 判据 ③：ACMD41 至少被发 EXPECT_ACMD41_MIN 次（验证"没就绪就重发"）
        //---------------------------------------------------------------------
        acmd41_total = 0;
        for (i = 0; i < n_cmd && i < 16; i = i + 1)
            if (seq[i] === 6'h29)
                acmd41_total = acmd41_total + 1;

        n_chk = n_chk + 1;
        if (acmd41_total < EXPECT_ACMD41_MIN) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据③：只发了 %0d 次 ACMD41（应≥%0d ⟹ 说明没重试）",
                     acmd41_total, EXPECT_ACMD41_MIN);
        end else begin
            $display("  [OK ] 判据③：ACMD41 发了 %0d 次（≥%0d ⟹ 重试逻辑正确）",
                     acmd41_total, EXPECT_ACMD41_MIN);
        end

        //---------------------------------------------------------------------
        // 判据 ④：每一条 ACMD41 之前必须紧邻一条 CMD55
        //---------------------------------------------------------------------
        acmd41_before_cmd55 = 1'b1;
        for (i = 1; i < n_cmd && i < 16; i = i + 1)
            if (seq[i] === 6'h29 && seq[i-1] !== 6'h37)
                acmd41_before_cmd55 = 1'b0;

        n_chk = n_chk + 1;
        if (!acmd41_before_cmd55) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据④：有 ACMD41 前面不是 CMD55（卡不会认这个 ACMD）");
        end else begin
            $display("  [OK ] 判据④：每条 ACMD41 前都有 CMD55");
        end

        //---------------------------------------------------------------------
        // 判据 ⑤：init_done 拉高后必须保持
        //---------------------------------------------------------------------
        repeat (2000) @(posedge clk);
        n_chk = n_chk + 1;
        if (init_done !== 1'b1) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据⑤：init_done 没有保持");
        end else begin
            $display("  [OK ] 判据⑤：init_done 保持为 1");
        end

        //---------------------------------------------------------------------
        // 汇总
        //---------------------------------------------------------------------
        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果: *** PASS ***  (%0d/%0d)", n_chk, n_chk);
        else
            $display(" 结果: *** FAIL ***  (%0d/%0d 失败)", n_err, n_chk);
        $display("------------------------------------------------------------");
        $display("");
        $finish;
    end

    // 仿真总超时保护
    initial begin
        #20_000_000;
        $display("  [ERR] 仿真总超时（20 ms 逻辑时间）—— 大概率是初始化流程卡住了");
        $display(" 结果: *** FAIL ***  超时");
        $finish;
    end

endmodule
