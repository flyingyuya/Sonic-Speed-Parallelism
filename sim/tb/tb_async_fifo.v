//=============================================================================
// tb_async_fifo.v - 异步 FIFO 验证
//-----------------------------------------------------------------------------
// 验证策略（不是随便灌数据，每条都针对一个具体失效模式）：
//
//   ① 数据完整性   —— 递增序列 + 记分板队列，逐笔比对，抓"搬错/丢/重"
//   ② show-ahead   —— 在【读时钟中点】检查：只要 !empty，dout 当拍就必须
//                     等于期望队首。这是 show-ahead FIFO 最容易写错的地方
//                     （写成寄存器输出时，数据会晚一拍，普通对拍发现不了）
//   ③ 满保护       —— 写满时 wr_en 继续拉高，验证数据【不被覆盖】
//   ④ 空保护       —— 空时 rd_en 继续拉高，验证【不产生幽灵数据】
//   ⑤ 指针回绕     —— 跑够轮数让 PW 位指针回绕多次，抓"只差一圈"的判据错误
//   ⑥ 占用数单调性 —— wr_level 必须是真实值的上界、rd_level 是下界
//                     （指针同步是滞后的，方向搞反就是漏/假满）
//   ⑦ 时钟比失衡   —— 用 4 组差异极大的时钟比跑，覆盖"写远快于读"和
//                     "读远快于写"两个极端
//
// 参数化后由 scripts/sim/run_iv.sh 用不同 -P 值跑 4 组。
//=============================================================================
`timescale 1ns/1ps

module tb_async_fifo;

    parameter integer DW     = 24;
    parameter integer DEPTH  = 16;
    parameter real    WPER   = 10.0;    // 写时钟周期 (ns)
    parameter real    RPER   = 7.4;     // 读时钟周期 (ns)
    parameter integer WR_PCT = 70;      // 写概率 (%)
    parameter integer RD_PCT = 60;      // 读概率 (%)
    parameter integer NMAX   = 4000;    // 写满这么多笔后开始收尾

    localparam integer AW   = $clog2(DEPTH);
    localparam integer QMAX = 65536;

    reg          wclk = 1'b0;
    reg          rclk = 1'b0;
    reg          wrst_n = 1'b0;
    reg          rrst_n = 1'b0;
    reg          wr_en = 1'b0;
    reg          rd_en = 1'b0;
    reg  [DW-1:0] din  = {DW{1'b0}};

    wire [DW-1:0]          dout;
    wire                   full, empty;
    wire [AW:0]            wr_level, rd_level;
    wire [7:0]             wr_drop;

    async_fifo #(.DW(DW), .DEPTH(DEPTH)) dut (
        .wclk     (wclk),
        .wrst_n   (wrst_n),
        .wr_en    (wr_en),
        .din      (din),
        .full     (full),
        .wr_level (wr_level),
        .wr_drop  (wr_drop),
        .rclk     (rclk),
        .rrst_n   (rrst_n),
        .rd_en    (rd_en),
        .dout     (dout),
        .empty    (empty),
        .rd_level (rd_level)
    );

    //-------------------------------------------------------------------------
    // 时钟（周期故意取非整数比，避免两个时钟长期锁相而漏掉某些相位）
    //-------------------------------------------------------------------------
    always #(WPER / 2.0) wclk = ~wclk;
    always #(RPER / 2.0) rclk = ~rclk;

    //-------------------------------------------------------------------------
    // 记分板
    //-------------------------------------------------------------------------
    reg  [DW-1:0] q [0:QMAX-1];
    integer q_head = 0;         // 下一个期望读出的位置
    integer q_tail = 0;         // 下一个写入位置
    integer n_wr = 0, n_rd = 0;
    integer n_err = 0;
    integer n_rd_empty = 0, n_wr_full = 0;
    integer max_wl = 0, max_rl = 0;
    integer i;

    //-------------------------------------------------------------------------
    // 伪随机源：自己写 32 位 LFSR，不用 $random
    //   ① $random 是 Verible 禁用的系统函数（且不可综合，不同仿真器行为不一）
    //   ② 自写 LFSR 完全确定性 —— 同一份激励每次跑都一样，便于复现
    //   多项式 x^32 + x^22 + x^2 + x + 1（最大长度，周期 2^32-1）
    //-------------------------------------------------------------------------
    function [31:0] lfsr_next;
        input [31:0] s;
        begin
            lfsr_next = {s[30:0], s[31] ^ s[21] ^ s[1] ^ s[0]};
        end
    endfunction

    //-------------------------------------------------------------------------
    // 写侧激励
    //-------------------------------------------------------------------------
    reg [31:0]   lfsr_w = 32'hACE1_2345;    // 非零种子
    reg [DW-1:0] din_cnt = {DW{1'b0}};
    reg          stop_wr = 1'b1;    // 复位期间先掐住，复位检查通过后再放行

    always @(posedge wclk or negedge wrst_n) begin
        if (!wrst_n) begin
            wr_en   <= 1'b0;
            din     <= {DW{1'b0}};
            din_cnt <= {DW{1'b0}};
            lfsr_w  <= 32'hACE1_2345;
        end else begin
            lfsr_w  <= lfsr_next(lfsr_w);
            wr_en   <= (!stop_wr) && ((lfsr_w[30:0] % 100) < WR_PCT);
            din     <= din_cnt;
            din_cnt <= din_cnt + 1'b1;
        end
    end

    // 写侧记分板：只有"被接受"的写才入队
    always @(posedge wclk) begin
        if (wrst_n && wr_en && !full) begin
            q[q_tail] = din;
            q_tail    = q_tail + 1;
            n_wr      = n_wr + 1;
        end
        if (wrst_n && wr_en && full)
            n_wr_full = n_wr_full + 1;
    end

    //-------------------------------------------------------------------------
    // 读侧激励
    //-------------------------------------------------------------------------
    reg [31:0] lfsr_r = 32'h1357_9BDF;
    reg        stop_rd = 1'b1;

    always @(posedge rclk or negedge rrst_n) begin
        if (!rrst_n) begin
            rd_en  <= 1'b0;
            lfsr_r <= 32'h1357_9BDF;
        end else begin
            lfsr_r <= lfsr_next(lfsr_r);
            rd_en  <= (!stop_rd) && ((lfsr_r[30:0] % 100) < RD_PCT);
        end
    end

    // 读侧记分板：弹出
    always @(posedge rclk) begin
        if (rrst_n && rd_en && !empty) begin
            q_head = q_head + 1;
            n_rd   = n_rd + 1;
        end
        if (rrst_n && rd_en && empty)
            n_rd_empty = n_rd_empty + 1;

        // 检查：绝不能读出比写进去更多的数据
        if (rrst_n && q_head > q_tail) begin
            n_err = n_err + 1;
            if (n_err <= 10)
                $display("  [ERR] t=%0t 读出数超过写入数 (head=%0d tail=%0d)",
                         $time, q_head, q_tail);
        end
    end

    //-------------------------------------------------------------------------
    // 检查②：show-ahead —— 在读时钟【中点】采样（此时所有边沿更新已稳定）
    //-------------------------------------------------------------------------
    always @(negedge rclk) begin
        if (rrst_n && !empty) begin
            if (dout !== q[q_head]) begin
                n_err = n_err + 1;
                if (n_err <= 10)
                    $display("  [ERR] t=%0t show-ahead 不符: 期望 %h 实得 %h (head=%0d)",
                             $time, q[q_head], dout, q_head);
            end
        end
    end

    //-------------------------------------------------------------------------
    // 检查⑥：占用数方向
    //   wr_level 用的是【滞后】的读指针 -> 必须是真实占用数的【上界】
    //   rd_level 用的是【滞后】的写指针 -> 必须是真实占用数的【下界】
    //-------------------------------------------------------------------------
    always @(negedge wclk) begin
        if (wrst_n && (wr_level < (q_tail - q_head))) begin
            n_err = n_err + 1;
            if (n_err <= 10)
                $display("  [ERR] t=%0t wr_level(%0d) < 真实占用(%0d)",
                         $time, wr_level, q_tail - q_head);
        end
        if (wrst_n && (wr_level > max_wl)) max_wl = wr_level;
    end

    always @(negedge rclk) begin
        if (rrst_n && (rd_level > (q_tail - q_head))) begin
            n_err = n_err + 1;
            if (n_err <= 10)
                $display("  [ERR] t=%0t rd_level(%0d) > 真实占用(%0d)",
                         $time, rd_level, q_tail - q_head);
        end
        if (rrst_n && (rd_level > max_rl)) max_rl = rd_level;
    end

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_async_fifo.vcd");
            $dumpvars(0, tb_async_fifo);
        end

        $display("============================================================");
        $display(" 异步 FIFO 验证  DW=%0d DEPTH=%0d  写周期=%0.1fns 读周期=%0.1fns",
                 DW, DEPTH, WPER, RPER);
        $display("                写概率=%0d%%  读概率=%0d%%", WR_PCT, RD_PCT);
        $display("============================================================");

        // 复位（此时 stop_wr/stop_rd 都是 1，不会有任何读写干扰）
        wrst_n = 1'b0;  rrst_n = 1'b0;
        repeat (6) @(posedge wclk);
        @(negedge wclk);  wrst_n = 1'b1;
        @(negedge rclk);  rrst_n = 1'b1;
        repeat (4) @(posedge rclk);
        @(negedge rclk);

        // 检查：复位后、任何读写发生前，必须为空
        if (!empty) begin
            n_err = n_err + 1;
            $display("  [ERR] 复位后 empty 不为 1");
        end

        // 放行激励
        stop_wr = 1'b0;
        stop_rd = 1'b0;

        // ---- 主体：跑到写够 NMAX 笔 ----
        wait (n_wr >= NMAX);
        stop_wr = 1'b1;             // 停止写入

        // ---- 排空：一直读到空为止 ----
        wait (empty);
        repeat (4) @(posedge rclk);
        stop_rd = 1'b1;
        @(negedge rclk);

        // ---- 收尾检查 ----
        if (n_wr !== n_rd) begin
            n_err = n_err + 1;
            $display("  [ERR] 收发数量不等: 写 %0d 读 %0d", n_wr, n_rd);
        end
        if (q_head !== q_tail) begin
            n_err = n_err + 1;
            $display("  [ERR] 记分板收尾不齐: head=%0d tail=%0d", q_head, q_tail);
        end
        if (max_wl < DEPTH) begin
            $display("  [INFO] 本场景未写满（max wr_level=%0d < DEPTH=%0d）；满保护由其他场景覆盖",
                     max_wl, DEPTH);
        end

        // 检查：诊断计数 wr_drop 必须等于"写使能拉高但被满挡住"的次数（8 位循环）
        if (wr_drop !== (n_wr_full % 256)) begin
            n_err = n_err + 1;
            $display("  [ERR] wr_drop(%0d) 与写满次数(%0d%%256=%0d) 不符",
                     wr_drop, n_wr_full, n_wr_full % 256);
        end

        repeat (20) @(posedge rclk);
        $display("------------------------------------------------------------");
        $display("  写入 %0d 笔 / 读出 %0d 笔", n_wr, n_rd);
        $display("  max wr_level=%0d  max rd_level=%0d  (DEPTH=%0d)",
                 max_wl, max_rl, DEPTH);
        $display("  写满被拒 %0d 次 / 空读尝试 %0d 次", n_wr_full, n_rd_empty);
        $display("  wr_drop 计数 %0d（与上面对照）", wr_drop);
        $display("  指针回绕次数 ≈ %0d", n_wr / DEPTH);
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  异步 FIFO 数据完整、show-ahead 成立");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

    // 超时保护
    initial begin
        #2000000;
        $display(" 结果       : *** FAIL ***  超时（可能死锁）");
        $finish;
    end

endmodule
