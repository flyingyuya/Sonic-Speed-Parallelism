//=============================================================================
// tb_sd_ctrl_top.v  ——  SD 卡子系统整链验证
//=============================================================================
//   【验证什么】
//     ① sd_init 在 sd_ctrl_top 里能完成初始化（init_done 拉高）
//     ② 初始化完成后时钟/引脚正确切换到 sd_read
//     ③ 发一个 rd_start ⟹ 读回 512 个字节，逐字节等于 i[7:0]
//     ④ rd_busy 拉高再落下
//
//   【为什么这条 TB 比单独测两个模块更有价值】
//     它验证的是【组合】：时钟切换、CS/MOSI 归属、start 的跨域同步。
//     这些恰恰是两个模块单独测时完全覆盖不到的部分
//     （账本 178：TB 只测子模块 ⟹ 接线错误永远测不到）。
//
//   【仿真参数】
//     CLK_HZ 设成 400 kHz（而不是真实的 48 MHz）
//     ⟹ sd_init 的分频系数变成 2，初始化时钟 200 kHz
//     ⟹ 逻辑完全一致，只是跑得快，仿真时间从"几十毫秒"降到"几毫秒"
//=============================================================================

`timescale 1ns / 1ps

module tb_sd_ctrl_top;

    localparam integer CLK_HZ     = 400_000;   // 仿真用（真实是 48 MHz）
    localparam integer CLK_PERIOD = 2500;      // 2.5 us ⟹ 400 kHz
    localparam integer BLOCK_BYTES = 512;
    localparam [31:0]  SEC_ADDR    = 32'd2048;

    //-------------------------------------------------------------------------
    // 时钟与复位
    //-------------------------------------------------------------------------
    reg clk   = 1'b0;
    reg rst_n = 1'b0;

    always #(CLK_PERIOD/2) clk = ~clk;

    //-------------------------------------------------------------------------
    // DUT
    //-------------------------------------------------------------------------
    wire        sd_clk;
    wire        sd_cs;
    wire        sd_mosi;
    wire        sd_miso;

    reg         rd_start = 1'b0;
    wire        rd_busy;
    wire        rd_valid;
    wire [7:0]  rd_data;
    wire        init_done;

    sd_ctrl_top #(
        .CLK_HZ        (CLK_HZ),
        .FAST_DIV      (4),
        .INIT_HZ       (200_000),
        .POWER_ON_NUM  (20),        // 仿真用：20 拍
        .OVER_TIME_NUM (500),       // 仿真用
        .BLOCKS        (1)          // 仿真只读 1 块
    ) dut (
        .clk         (clk),
        .rst_n       (rst_n),
        .sd_clk      (sd_clk),
        .sd_cs       (sd_cs),
        .sd_mosi     (sd_mosi),
        .sd_miso     (sd_miso),
        .rd_start    (rd_start),
        .rd_sec_addr (SEC_ADDR),
        .rd_busy     (rd_busy),
        .rd_valid    (rd_valid),
        .rd_data     (rd_data),
        .init_done   (init_done)
    );

    //-------------------------------------------------------------------------
    // SD 卡模型
    //-------------------------------------------------------------------------
    wire [5:0]  m_cmd_index;
    wire [31:0] m_cmd_arg;
    wire        m_cmd_valid;
    wire [7:0]  m_acmd41_cnt;

    sd_card_model #(
        .ACMD41_POLLS (3),
        .BLOCKS       (1)
    ) model (
        .sd_clk     (sd_clk),
        .sd_cs      (sd_cs),
        .sd_mosi    (sd_mosi),
        .sd_miso    (sd_miso),
        .cmd_index  (m_cmd_index),
        .cmd_arg    (m_cmd_arg),
        .cmd_valid  (m_cmd_valid),
        .acmd41_cnt (m_acmd41_cnt)
    );

    //-------------------------------------------------------------------------
    // 收集读到的字节
    //-------------------------------------------------------------------------
    reg [7:0] got [0:BLOCK_BYTES-1];
    integer   got_n = 0;

    always @(posedge clk) begin
        if (rd_valid) begin
            if (got_n < BLOCK_BYTES)
                got[got_n] = rd_data;
            got_n = got_n + 1;
        end
    end

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    integer i;
    integer n_chk = 0;
    integer n_err = 0;
    integer wait_cnt;
    integer bad_cnt;
    reg     busy_seen;

    initial begin
        $dumpfile("tb_sd_ctrl_top.vcd");
        $dumpvars(0, tb_sd_ctrl_top);

        $display("");
        $display("============================================================");
        $display(" tb_sd_ctrl_top  SD 子系统整链（初始化 + 读 512 字节）");
        $display("============================================================");

        rst_n = 1'b0;
        repeat (20) @(posedge clk);
        rst_n = 1'b1;

        //---------------------------------------------------------------------
        // 等初始化完成
        //---------------------------------------------------------------------
        wait_cnt = 0;
        while ((init_done !== 1'b1) && (wait_cnt < 300000)) begin
            @(posedge clk);
            wait_cnt = wait_cnt + 1;
        end

        n_chk = n_chk + 1;
        if (init_done !== 1'b1) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据①：init_done 没拉高（等了 %0d 拍）", wait_cnt);
            $display(" 结果: *** FAIL ***  初始化失败，后续不再检查");
            $finish;
        end else begin
            $display("  [OK ] 判据①：init_done 拉高（用了 %0d 拍）", wait_cnt);
        end

        repeat (50) @(posedge clk);

        //---------------------------------------------------------------------
        // 发读请求
        //---------------------------------------------------------------------
        @(posedge clk);
        rd_start = 1'b1;
        @(posedge clk);
        rd_start = 1'b0;

        // 观察 busy 是否拉高
        busy_seen = 1'b0;
        wait_cnt  = 0;
        while (wait_cnt < 40000) begin
            @(posedge clk);
            wait_cnt = wait_cnt + 1;
            if (rd_busy === 1'b1)
                busy_seen = 1'b1;
            if (busy_seen && (rd_busy === 1'b0) && (got_n >= BLOCK_BYTES))
                wait_cnt = 40000;    // 读完了
        end
        repeat (50) @(posedge clk);

        //---------------------------------------------------------------------
        // 判据②：busy 必须出现过并落下
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        if (!busy_seen || (rd_busy !== 1'b0)) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据②：busy 握手异常（出现过=%b，当前=%b）", busy_seen, rd_busy);
        end else begin
            $display("  [OK ] 判据②：busy 拉高后已落下");
        end

        //---------------------------------------------------------------------
        // 判据③：字节数
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        if (got_n !== BLOCK_BYTES) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据③：收到 %0d 个字节（应 %0d）", got_n, BLOCK_BYTES);
        end else begin
            $display("  [OK ] 判据③：收到正好 %0d 个字节", got_n);
        end

        //---------------------------------------------------------------------
        // 判据④：逐字节比对
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        bad_cnt = 0;
        for (i = 0; i < BLOCK_BYTES; i = i + 1) begin
            if (i < got_n) begin
                if (got[i] !== i[7:0]) begin
                    if (bad_cnt < 6)
                        $display("  [ERR] 判据④：第 %0d 个字节 = 0x%02h（应 0x%02h）",
                                 i, got[i], i[7:0]);
                    bad_cnt = bad_cnt + 1;
                end
            end
        end
        if (bad_cnt != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据④：共 %0d 个字节不对", bad_cnt);
        end else begin
            $display("  [OK ] 判据④：512 个字节逐字节完全一致");
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

    // 总超时保护
    initial begin
        #50_000_000;
        $display("  [ERR] 仿真总超时");
        $display(" 结果: *** FAIL ***  超时");
        $finish;
    end

endmodule
