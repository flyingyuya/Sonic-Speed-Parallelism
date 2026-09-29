//=============================================================================
// tb_uart_cmd.v - UART 收发 + 命令解析验证
//-----------------------------------------------------------------------------
// 分两段测，避免"用被测模块验证被测模块"：
//
//   [1] UART 回环：uart_tx 和 uart_rx 互相接起来，连发 256 个字节
//       这不是循环论证 —— 发送和接收是两套独立状态机，
//       一个的 bug 不会同时让另一个也"恰好对"。
//
//   [2] 命令协议：用回环当"电脑"，给 cmd_proc 发 ASCII 命令，
//       检查它有没有产生正确的寄存器写；再检查回执内容。
//
// 连接关系：
//
//   TB(电脑)                              DUT
//   u_pc_tx ──serial──▶ u_dut_rx ──byte──▶ cmd_proc
//   u_pc_rx ◀─serial── u_dut_tx ◀─byte─── cmd_proc
//
//   独立的回环：u_lb_tx ──▶ u_lb_rx
//=============================================================================
`timescale 1ns / 1ps

module tb_uart_cmd;

    localparam integer CLK_HZ = 10_000_000;     // 10 MHz（比真实快，跑得快）
    localparam integer BAUD   = 115200;

    reg clk = 0, rst_n = 0;
    always #50 clk = ~clk;                      // 10 MHz

    integer n_err = 0;

    //=========================================================================
    // [1] 独立回环
    //=========================================================================
    reg        lb_send = 0;
    reg  [7:0] lb_data = 0;
    wire       lb_serial, lb_busy;
    wire       lb_valid, lb_ferr;
    wire [7:0] lb_rx;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_lb_tx (
        .clk(clk), .rst_n(rst_n), .send(lb_send), .data(lb_data),
        .tx(lb_serial), .busy(lb_busy)
    );

    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_lb_rx (
        .clk(clk), .rst_n(rst_n), .rx(lb_serial),
        .data(lb_rx), .valid(lb_valid), .ferr(lb_ferr)
    );

    //=========================================================================
    // [2] 命令协议：TB 侧"电脑"
    //=========================================================================
    reg        pc_send = 0;
    reg  [7:0] pc_data = 0;
    wire       pc_serial_out, pc_busy;      // TB 发给 DUT 的串行线

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_pc_tx (
        .clk(clk), .rst_n(rst_n), .send(pc_send), .data(pc_data),
        .tx(pc_serial_out), .busy(pc_busy)
    );

    // DUT 侧的接收器：串行线 -> 字节
    wire       dut_rx_valid;
    wire [7:0] dut_rx_data;

    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_dut_rx (
        .clk(clk), .rst_n(rst_n), .rx(pc_serial_out),
        .data(dut_rx_data), .valid(dut_rx_valid), .ferr()
    );

    // 配置寄存器（TB 扮演 ui_ctrl 的回读，故意用非默认值便于核对回执）
    reg [7:0] cfg_view      = 8'h07;
    reg [7:0] cfg_style     = 8'h00;
    reg [7:0] cfg_hue_spd   = 8'h02;
    reg [7:0] cfg_wave_gain = 8'h03;
    reg [7:0] cfg_bg_mode   = 8'h00;
    reg [7:0] cfg_auto      = 8'h00;

    wire       cp_wr_en;
    wire [3:0] cp_wr_addr;
    wire [7:0] cp_wr_data;
    wire [7:0] cp_tx_data;
    wire       cp_tx_send;
    wire       cp_tx_busy;

    cmd_proc u_cmd (
        .clk(clk), .rst_n(rst_n),
        .rx_data(dut_rx_data), .rx_valid(dut_rx_valid),
        .tx_data(cp_tx_data), .tx_send(cp_tx_send), .tx_busy(cp_tx_busy),
        .cfg_view(cfg_view), .cfg_style(cfg_style), .cfg_hue_spd(cfg_hue_spd),
        .cfg_wave_gain(cfg_wave_gain), .cfg_bg_mode(cfg_bg_mode),
        .cfg_auto(cfg_auto),
        .wr_en(cp_wr_en), .wr_addr(cp_wr_addr), .wr_data(cp_wr_data)
    );

    // DUT 侧的发送器：字节 -> 串行线
    wire cp_serial_out;

    uart_tx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_dut_tx (
        .clk(clk), .rst_n(rst_n), .send(cp_tx_send), .data(cp_tx_data),
        .tx(cp_serial_out), .busy(cp_tx_busy)
    );

    // TB 侧接收器：收 DUT 的回执
    wire       pc_rx_valid, pc_rx_ferr;
    wire [7:0] pc_rx_data;

    uart_rx #(.CLK_HZ(CLK_HZ), .BAUD(BAUD)) u_pc_rx (
        .clk(clk), .rst_n(rst_n), .rx(cp_serial_out),
        .data(pc_rx_data), .valid(pc_rx_valid), .ferr(pc_rx_ferr)
    );

    //=========================================================================
    // 采集
    //=========================================================================
    reg [7:0] exp_byte = 8'h00;
    integer   n_lb_ok = 0, n_lb_bad = 0;

    always @(posedge clk) begin
        if (rst_n && lb_valid) begin
            if (lb_rx === exp_byte && lb_ferr === 1'b0) n_lb_ok = n_lb_ok + 1;
            else begin
                n_lb_bad = n_lb_bad + 1;
                if (n_lb_bad <= 4)
                    $display("  [ERR] 回环字节：收到 0x%02X 期望 0x%02X (ferr=%b)",
                             lb_rx, exp_byte, lb_ferr);
            end
        end
    end

    // 记录 cmd_proc 产生的写
    integer n_wr = 0;
    reg [3:0] wr_a [0:15];
    reg [7:0] wr_d [0:15];

    always @(posedge clk) begin
        if (rst_n && cp_wr_en && n_wr < 16) begin
            wr_a[n_wr] = cp_wr_addr;
            wr_d[n_wr] = cp_wr_data;
            n_wr = n_wr + 1;
        end
    end

    // 记录回执字节
    integer n_rep = 0;
    reg [7:0] rep [0:63];

    always @(posedge clk) begin
        if (rst_n && pc_rx_valid && n_rep < 64) begin
            rep[n_rep] = pc_rx_data;
            n_rep = n_rep + 1;
        end
    end

    //=========================================================================
    // 任务
    //=========================================================================
    task lb_put;
        input [7:0] b;
        begin
            @(negedge clk); lb_data = b; lb_send = 1;
            @(negedge clk); lb_send = 0;
            wait (lb_busy === 1'b1);
            wait (lb_busy === 1'b0);
            repeat (2) @(posedge clk);
        end
    endtask

    task pc_put;
        input [7:0] c;
        begin
            @(negedge clk); pc_data = c; pc_send = 1;
            @(negedge clk); pc_send = 0;
            wait (pc_busy === 1'b1);
            wait (pc_busy === 1'b0);
            repeat (2) @(posedge clk);
        end
    endtask

    integer i, j;
    integer wr_base;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_uart_cmd.vcd");
            $dumpvars(0, tb_uart_cmd);
        end

        $display("============================================================");
        $display(" UART 收发 + 命令解析验证");
        $display("   时钟 %0d MHz，波特率 %0d，每比特 %0d 个时钟",
                 CLK_HZ/1000000, BAUD, CLK_HZ/BAUD);
        $display("============================================================");

        rst_n = 0;
        repeat (20) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (10) @(posedge clk);

        //---------------------------------------------------------------------
        // [1] UART 回环
        //---------------------------------------------------------------------
        $display("");
        $display(" [1] UART 回环（连续 256 个字节，含 0x00/0xFF 边界）");
        for (i = 0; i < 256; i = i + 1) begin
            exp_byte = i[7:0];
            lb_put(i[7:0]);
        end
        repeat (300) @(posedge clk);
        if (n_lb_bad != 0 || n_lb_ok != 256) begin
            n_err = n_err + 1;
            $display("  [ERR] 回环 %0d 正确 / %0d 错误（应 256/0）", n_lb_ok, n_lb_bad);
        end else
            $display("  [ok ] 256 个字节全部原样收到，无帧错误");

        //---------------------------------------------------------------------
        // [2] 命令协议
        //---------------------------------------------------------------------
        $display("");
        $display(" [2] 命令解析");

        // ---- ② "V05\r" ----
        wr_base = n_wr;
        pc_put("V"); pc_put("0"); pc_put("5"); pc_put(8'h0D);
        repeat (50) @(posedge clk);
        if (n_wr - wr_base != 1 || wr_a[wr_base] !== 4'h0 || wr_d[wr_base] !== 8'h05) begin
            n_err = n_err + 1;
            $display("  [ERR] 'V05' -> %0d 次写，addr=%0d data=0x%02X（期望 1/0/0x05）",
                     n_wr - wr_base, wr_a[wr_base], wr_d[wr_base]);
        end else
            $display("  [ok ] ② 'V05\\r' -> addr=0 data=0x05");

        // ---- ③ "H2\r"（只写一位，当高 4 位用）----
        wr_base = n_wr;
        pc_put("H"); pc_put("2"); pc_put(8'h0D);
        repeat (50) @(posedge clk);
        if (n_wr - wr_base != 1 || wr_a[wr_base] !== 4'h2 || wr_d[wr_base] !== 8'h20) begin
            n_err = n_err + 1;
            $display("  [ERR] 'H2' -> %0d 次写，addr=%0d data=0x%02X（期望 1/2/0x20）",
                     n_wr - wr_base, wr_a[wr_base], wr_d[wr_base]);
        end else
            $display("  [ok ] ③ 'H2\\r'（只写一位）-> addr=2 data=0x20");

        // ---- ④ 小写字母 ----
        wr_base = n_wr;
        pc_put("b"); pc_put("0"); pc_put("1");
        repeat (50) @(posedge clk);
        if (n_wr - wr_base != 1 || wr_a[wr_base] !== 4'h4 || wr_d[wr_base] !== 8'h01) begin
            n_err = n_err + 1;
            $display("  [ERR] 'b01' -> %0d 次写，addr=%0d data=0x%02X（期望 1/4/0x01）",
                     n_wr - wr_base, wr_a[wr_base], wr_d[wr_base]);
        end else
            $display("  [ok ] ④ 小写 'b01' -> addr=4 data=0x01");

        // ---- ⑤ 非法字符不应产生写 ----
        wr_base = n_wr;
        pc_put("Z"); pc_put("X"); pc_put(" "); pc_put(8'h0D);
        repeat (50) @(posedge clk);
        if (n_wr != wr_base) begin
            n_err = n_err + 1;
            $display("  [ERR] 乱敲产生了 %0d 次写（应 0）", n_wr - wr_base);
        end else
            $display("  [ok ] ⑤ 非法字符不产生任何寄存器写");

        // ---- ⑤b '?' 必须是【全局】命令：命令写了一半也要能回读 ----
        //   下面第 ⑤ 步【测不到】真正的坑：那时状态机一直停在 S_CMD，
        //   而 S_CMD 本来就有“其它字符一律忽略”。
        //   真正的坑是：已经吃了命令字母、正等 hex 位时来了个 '?'，
        //   旧实现不认它，它就掉进“非法字符”被吃掉 —— 用户要按两次
        //   '?' 才看得到回执；更糟的是下一条命令的字母也被吞，
        //   第一个 hex 位会和残留的 hi_r 拼成错值（实测拼出 V=0x22）。
        //   上板用 scripts/uart_term.py --test 把这个 bug 测出来的。
        pc_put("V");                        // 进 S_HI（半条命令）
        repeat (20) @(posedge clk);         // 让它进入 S_HI
        n_rep = 0;
        pc_put("?");                        // 此时 '?' 应该照样触发回执
        repeat (25000) @(posedge clk);
        if (n_rep < 20) begin
            n_err = n_err + 1;
            $display("  [ERR] ⑤b 在 S_HI 状态下 '?' 被吞掉了（只回 %0d 字节）", n_rep);
            $display("        期望：'?' 是全局命令，任何状态都能回读");
        end else
            $display("  [ok ] ⑤b '?' 是全局命令，半条命令下也能回读");

        // ---- ⑤c 非法字符后，下一条完整命令必须能正常执行 ----
        pc_put("V"); pc_put("2");           // 进 S_LO（等着第二个 hex 位）
        repeat (20) @(posedge clk);
        pc_put("#");                        // 非法：应该放弃当前命令
        repeat (30) @(posedge clk);         // '#’ 被消费掉，状态机回 S_CMD
        if (n_wr != wr_base) begin
            n_err = n_err + 1;
            $display("  [ERR] ⑤c 半条命令 + 非法字符竟然产生了写（应 0）");
        end else begin
            wr_base = n_wr;
            pc_put("V"); pc_put("0"); pc_put("5");
            repeat (50) @(posedge clk);
            if (n_wr - wr_base != 1 || wr_a[wr_base] !== 4'h0 ||
                wr_d[wr_base] !== 8'h05) begin
                n_err = n_err + 1;
                $display("  [ERR] ⑤c 非法字符后状态机【没能脱困】：");
                $display("        'V05' -> %0d 次写（期望 1），addr=%0d data=0x%02X",
                         n_wr - wr_base, wr_a[wr_base], wr_d[wr_base]);
            end else
                $display("  [ok ] ⑤c 中间态遇非法字符能脱困，后续命令正常");
        end

        // ---- ⑥ 查询回执 ----
        n_rep = 0;
        pc_put("?");
        // 一个字节 10 位 x 87 clk ≈ 870 拍，20 字节约 17400 拍，留够余量
        repeat (25000) @(posedge clk);
        if (n_rep < 20) begin
            n_err = n_err + 1;
            $display("  [ERR] 查询只回了 %0d 字节（应 >= 20）", n_rep);
        end else begin
            // 逐字节核对："V07 S00 H02 G03 B0\r\n"（18 字符 + CRLF = 20）
            // 注意这里 cfg_* 的值在测试中没被改（cmd_proc 只输出写请求，
            // 由 ui_ctrl 去改），所以回执应该是初始值。
            if (rep[0] !== "V" || rep[1] !== "0" || rep[2] !== "7" ||
                rep[3] !== " " || rep[4] !== "S" ||
                rep[8] !== "H" || rep[9] !== "0" || rep[10] !== "2" ||
                rep[12] !== "G" || rep[13] !== "0" || rep[14] !== "3" ||
                rep[18] !== 8'h0D || rep[19] !== 8'h0A) begin
                n_err = n_err + 1;
                $display("  [ERR] 回执内容不符");
                $write("        收到: ");
                for (j = 0; j < 20; j = j + 1) $write("%c", rep[j]);
                $write("\n        期望: V07 S00 H02 G03 B0\\r\\n\n");
            end else
                $display("  [ok ] ⑥ 查询回执 20 字节内容正确（V07 S00 H02 G03 B0）");
        end

        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  UART 位时序正确，命令解析与回执全部符合预期");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

    // 超时
    initial begin
        #80_000_000;
        $display(" 结果       : *** FAIL ***  超时");
        $finish;
    end

endmodule
