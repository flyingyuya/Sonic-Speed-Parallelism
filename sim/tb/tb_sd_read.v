//=============================================================================
// tb_sd_read.v  ——  sd_read（CMD17 单块读）的自测
//=============================================================================
//   【判据】
//     ① busy 在启动后拉高、读完拉低
//     ② dout_valid 恰好出现 512 次
//     ③ 收到的 512 个字节，逐个等于模型预设的 i[7:0]
//        ⟹ 这条最能抓"错位/丢字节/多字节"这类问题
//     ④ 命令字必须是 CMD17（0x51）且参数等于 sec_addr
//        （模型的 [模型] 打印会给出原始比特流，TB 再核对一次）
//
//   【为什么这条 TB 值得写】
//     数据块是【变长前导 + 定长内容】的混合结构：
//       NOP... + 令牌 0xFE + 512B + CRC16
//     只要"令牌剩余 7 位"这类细节错一位，全部 512 字节都会错位。
//     用"第 i 个字节 = i[7:0]"这种自校验图案，错一位立刻暴露。
//=============================================================================

`timescale 1ns / 1ps

module tb_sd_read;

    localparam integer BLOCK_BYTES = 512;
    localparam [31:0]  SEC_ADDR    = 32'd2048;   // 随便挑一个扇区号

    //-------------------------------------------------------------------------
    // 时钟：sd_clk 用一个独立的 20 MHz（本次不测 sd_ctrl_top 的分频）
    //-------------------------------------------------------------------------
    reg sd_clk = 1'b0;
    reg rst_n  = 1'b0;

    always #25 sd_clk = ~sd_clk;      // 50 ns 周期 = 20 MHz

    //-------------------------------------------------------------------------
    // DUT 与模型
    //-------------------------------------------------------------------------
    reg         start = 1'b0;
    wire        busy;
    wire        dout_valid;
    wire [7:0]  dout_data;
    wire        sd_cs;
    wire        sd_mosi;
    wire        sd_miso;

    wire [5:0]  m_cmd_index;
    wire [31:0] m_cmd_arg;
    wire        m_cmd_valid;
    wire [7:0]  m_acmd41_cnt;

    sd_read #(.BLOCKS(1)) dut (   // TB 只测 1 块（多块会跑很久）
        .sd_clk     (sd_clk),
        .rst_n      (rst_n),
        .start      (start),
        .sec_addr   (SEC_ADDR),
        .busy       (busy),
        .dout_valid (dout_valid),
        .dout_data  (dout_data),
        .sd_miso    (sd_miso),
        .sd_cs      (sd_cs),
        .sd_mosi    (sd_mosi)
    );

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
    // 收集收到的字节
    //-------------------------------------------------------------------------
    reg [7:0] got [0:BLOCK_BYTES-1];
    integer   got_n = 0;

    always @(posedge sd_clk) begin
        if (dout_valid) begin
            if (got_n < BLOCK_BYTES)
                got[got_n] = dout_data;
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

    initial begin
        $dumpfile("tb_sd_read.vcd");
        $dumpvars(0, tb_sd_read);

        $display("");
        $display("============================================================");
        $display(" tb_sd_read  CMD17 单块读（512 字节）验证");
        $display("============================================================");

        rst_n = 1'b0;
        repeat (10) @(posedge sd_clk);
        rst_n = 1'b1;
        repeat (5) @(posedge sd_clk);

        // 发一个 start 脉冲
        @(posedge sd_clk);
        start = 1'b1;
        @(posedge sd_clk);
        start = 1'b0;

        // 等 busy 落下
        wait_cnt = 0;
        while ((busy !== 1'b0) && (wait_cnt < 200000)) begin
            @(posedge sd_clk);
            wait_cnt = wait_cnt + 1;
        end
        repeat (20) @(posedge sd_clk);   // 让最后几个字节收完

        //---------------------------------------------------------------------
        // 判据①：busy 必须回到 0
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        if (busy !== 1'b0) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据①：busy 没有回到 0（等了 %0d 拍）", wait_cnt);
        end else begin
            $display("  [OK ] 判据①：busy 已落下（用了 %0d 拍）", wait_cnt);
        end

        //---------------------------------------------------------------------
        // 判据②：字节数必须正好 512
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        if (got_n !== BLOCK_BYTES) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据②：收到 %0d 个字节（应 %0d）", got_n, BLOCK_BYTES);
        end else begin
            $display("  [OK ] 判据②：收到正好 %0d 个字节", got_n);
        end

        //---------------------------------------------------------------------
        // 判据③：逐个字节比对 i[7:0]
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        bad_cnt = 0;
        for (i = 0; i < BLOCK_BYTES; i = i + 1) begin
            if (i < got_n) begin
                if (got[i] !== i[7:0]) begin
                    if (bad_cnt < 6)
                        $display("  [ERR] 判据③：第 %0d 个字节 = 0x%02h（应 0x%02h）",
                                 i, got[i], i[7:0]);
                    bad_cnt = bad_cnt + 1;
                end
            end
        end
        if (bad_cnt != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据③：共 %0d 个字节不对", bad_cnt);
        end else begin
            $display("  [OK ] 判据③：512 个字节逐字节完全一致");
        end

        //---------------------------------------------------------------------
        // 判据④：必须收到且只收到 1 条 CMD17，参数正确
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        if ((m_cmd_index !== 6'h12) || (m_cmd_arg !== SEC_ADDR)) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据④：命令 = 0x%02h arg=0x%08h（应 0x11 / 0x%08h）",
                     m_cmd_index, m_cmd_arg, SEC_ADDR);
        end else begin
            $display("  [OK ] 判据④：CMD18（多块读）arg=0x%08h 正确", m_cmd_arg);
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
        #2_000_000;
        $display("  [ERR] 仿真总超时（2 ms）—— 读流程卡住了");
        $display(" 结果: *** FAIL ***  超时");
        $finish;
    end

endmodule
