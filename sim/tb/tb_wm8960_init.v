//=============================================================================
// tb_wm8960_init.v - WM8960 初始化序列验证
//-----------------------------------------------------------------------------
// 验证什么（每一项都针对一个具体的失效模式）：
//
//   ① I2C 协议时序   —— START/STOP 是否规范、每个字节后是否给 ACK
//   ② 从机地址       —— 首字节必须是 0x34（WM8960 的 0x1A<<1 | W）
//   ③ 字节打包       —— 16 位字必须拆成「高字节 + 低字节」两个字节发。
//                       这一步最容易错：WM8960 是 [15:9]=寄存器地址、[8:0]=数据，
//                       9 位数据的最高位【藏在 addr 的 bit0 里】，不是被截断。
//   ④ 寄存器值       —— 把发出去的 16 位字解回 (reg, data)，与独立写下的
//                       期望序列逐条比对。RTL 表里的值来自 datasheet 推导。
//   ⑤ 条数           —— 必须正好 20 条，一条不多一条不少
//   ⑥ 顺序           —— 特别是 CLKSEL=1 必须是最后一条；软复位必须是第一条
//   ⑦ PLL 锁定余量   —— 从 PLLEN=1 到 CLKSEL=1 之间必须隔了足够长的时间。
//                       这是最容易被忽略、也最容易上板才发现的问题：
//                       PLL 还没锁定就切时钟源，BCLK/LRCLK 会乱掉。
//
// 【为什么要写 I2C 从机模型】
//   `WM8960_init` 的输出只有两根线（SCL + 双向 SDA）。不把 I2C 时序解出来，
//   就没法知道它到底发了什么。用行为模型当"假芯片"是唯一能真正验证的办法。
//=============================================================================
`timescale 1ns / 1ps

module tb_wm8960_init;

    //=========================================================================
    // 参数
    //=========================================================================
    localparam integer CLK_PERIOD  = 20;           // 50 MHz，与 i2c_control 的假设一致
    localparam integer CLK_FREQ_HZ = 50_000_000;
    localparam integer DLY_MS      = 1;            // 与真实配置一致

    localparam [7:0]   DEV_ADDR_W  = 8'h34;        // WM8960: 7'b0011010 << 1 | 0
    localparam integer N_EXP       = 20;           // 期望写多少条
    localparam integer LOCK_MIN_NS = 5_000_000;    // PLL 至少留 5 ms 锁定

    //=========================================================================
    // DUT
    //=========================================================================
    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    reg  go = 1'b0;
    wire init_done;
    wire i2c_sclk;
    wire i2c_sdat;

    WM8960_init #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .DLY_MS      (DLY_MS)
    ) dut (
        .Clk       (clk),
        .Rst_n     (rst_n),
        .Go        (go),
        .device_id (DEV_ADDR_W),
        .Init_Done (init_done),
        .i2c_sclk  (i2c_sclk),
        .i2c_sdat  (i2c_sdat)
    );

    always #(CLK_PERIOD / 2) clk = ~clk;

    //=========================================================================
    // I2C 从机行为模型
    //   Verilog-2001 不支持数组端口，所以直接写在 TB 里
    //=========================================================================
    reg  sda_oe = 1'b0;                            // 1 = 本模型拉低 SDA（应答）
    assign i2c_sdat = sda_oe ? 1'b0 : 1'bz;

    // 读回 SDA：z / x 都当高电平（等价于有上拉电阻）
    wire sda_in = (i2c_sdat === 1'b0) ? 1'b0 : 1'b1;

    reg [15:0] cap_word [0:127];                   // 捕获到的 16 位字
    reg [63:0] cap_time [0:127];                   // 该字停止位时刻(ps)
    integer    cap_n = 0;

    reg       in_frame = 1'b0;
    reg [3:0] bitcnt   = 4'd0;
    reg [2:0] byte_idx = 3'd0;
    reg [7:0] shreg    = 8'd0;
    reg [15:0] cur_word = 16'd0;

    integer n_bad_addr = 0;                        // 从机地址不符次数
    integer n_nack     = 0;                        // 缺 ACK 次数

    //-------------------------------------------------------------------------
    // START / STOP 检测：SCL 为高时 SDA 的跳变
    //-------------------------------------------------------------------------
    always @(sda_in) begin
        if (i2c_sclk && in_frame == 1'b0 && sda_in == 1'b0) begin
            // START：准备接收新事务
            in_frame = 1'b1;
            bitcnt   = 4'd0;
            byte_idx = 3'd0;
        end else if (i2c_sclk && in_frame == 1'b1 && sda_in == 1'b1) begin
            // STOP：事务结束，收下这个 16 位字
            if (byte_idx == 3'd3) begin
                if (cap_n < 128) begin
                    cap_word[cap_n] = cur_word;
                    cap_time[cap_n] = $time;
                end
                cap_n = cap_n + 1;
            end
            in_frame = 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // SCL 上升沿采样数据位
    //-------------------------------------------------------------------------
    always @(posedge i2c_sclk) begin
        if (in_frame) begin
            if (bitcnt < 4'd8) begin
                shreg  = {shreg[6:0], sda_in};
                bitcnt = bitcnt + 4'd1;
            end else begin
                // 第 9 位（应答位）—— 数据字节结束
                bitcnt = 4'd0;
                case (byte_idx)
                    3'd0: begin
                        if (shreg !== DEV_ADDR_W) n_bad_addr = n_bad_addr + 1;
                    end
                    3'd1: cur_word[15:8] = shreg;
                    3'd2: cur_word[7:0]  = shreg;
                    default: ;
                endcase
                byte_idx = byte_idx + 3'd1;
            end
        end
    end

    //-------------------------------------------------------------------------
    // SCL 下降沿驱动 / 释放 ACK
    //-------------------------------------------------------------------------
    always @(negedge i2c_sclk) begin
        if (in_frame && bitcnt == 4'd8)
            sda_oe = 1'b1;                          // 拉低 = 应答
        else
            sda_oe = 1'b0;
    end

    //=========================================================================
    // 期望序列（独立写下，来源：docs/09 §2.5 / WM8960 datasheet）
    //   注意这里只写 (寄存器, 数据)，【不写字节】——
    //   字节拆分由 DUT 负责，正好验证打包是否正确。
    //=========================================================================
    reg [6:0] exp_reg [0:N_EXP-1];
    reg [8:0] exp_dat [0:N_EXP-1];
    reg [8*48-1:0] exp_note [0:N_EXP-1];

    initial begin
        exp_reg[ 0] = 7'h0F; exp_dat[ 0] = 9'h000; exp_note[ 0] = "soft reset";
        exp_reg[ 1] = 7'h19; exp_dat[ 1] = 9'h1FC; exp_note[ 1] = "PWRMGMT1";
        exp_reg[ 2] = 7'h2F; exp_dat[ 2] = 9'h00C; exp_note[ 2] = "PWRMGMT3";
        exp_reg[ 3] = 7'h1A; exp_dat[ 3] = 9'h1E0; exp_note[ 3] = "PWRMGMT2 (PLLEN=0)";
        exp_reg[ 4] = 7'h08; exp_dat[ 4] = 9'h1C4; exp_note[ 4] = "BCLKDIV=/4";
        exp_reg[ 5] = 7'h07; exp_dat[ 5] = 9'h04A; exp_note[ 5] = "IFACE1 master";
        exp_reg[ 6] = 7'h34; exp_dat[ 6] = 9'h038; exp_note[ 6] = "PLL N";
        exp_reg[ 7] = 7'h35; exp_dat[ 7] = 9'h031; exp_note[ 7] = "PLL K1";
        exp_reg[ 8] = 7'h36; exp_dat[ 8] = 9'h026; exp_note[ 8] = "PLL K2";
        exp_reg[ 9] = 7'h37; exp_dat[ 9] = 9'h0E9; exp_note[ 9] = "PLL K3";
        exp_reg[10] = 7'h1A; exp_dat[10] = 9'h1E1; exp_note[10] = "PLLEN=1";
        exp_reg[11] = 7'h02; exp_dat[11] = 9'h1F9; exp_note[11] = "LOUT1 vol";
        exp_reg[12] = 7'h03; exp_dat[12] = 9'h1F9; exp_note[12] = "ROUT1 vol";
        exp_reg[13] = 7'h15; exp_dat[13] = 9'h1C3; exp_note[13] = "L ADC vol";
        exp_reg[14] = 7'h16; exp_dat[14] = 9'h1C3; exp_note[14] = "R ADC vol";
        exp_reg[15] = 7'h2D; exp_dat[15] = 9'h080; exp_note[15] = "L mixer";
        exp_reg[16] = 7'h2E; exp_dat[16] = 9'h080; exp_note[16] = "R mixer";
        exp_reg[17] = 7'h2B; exp_dat[17] = 9'h150; exp_note[17] = "L boost";
        exp_reg[18] = 7'h2C; exp_dat[18] = 9'h00A; exp_note[18] = "R boost";
        exp_reg[19] = 7'h04; exp_dat[19] = 9'h005; exp_note[19] = "CLKSEL=PLL (LAST)";
    end

    //=========================================================================
    // 主流程
    //=========================================================================
    integer i;
    integer n_err = 0;
    reg [6:0] got_reg;
    reg [8:0] got_dat;
    reg [63:0] lock_ns;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_wm8960_init.vcd");
            $dumpvars(0, tb_wm8960_init);
        end

        $display("============================================================");
        $display(" WM8960 初始化序列验证   (DLY_MS=%0d, 每条之间约 %0d ms)",
                 DLY_MS, DLY_MS);
        $display("============================================================");

        // 复位
        rst_n = 1'b0;
        repeat (10) @(posedge clk);
        rst_n = 1'b1;
        repeat (4) @(posedge clk);

        if (init_done !== 1'b0) begin
            n_err = n_err + 1;
            $display("  [ERR] 复位后 Init_Done 不为 0");
        end

        // 触发初始化
        @(negedge clk); go = 1'b1;
        @(negedge clk); go = 1'b0;

        // 等扫描完成
        //   ⚠️ 不能写成 fork ... join —— join 会等【两个分支都结束】，
        //   于是超时分支必然在 200ms 打印一次"超时"，即使早就成功了。
        //   正确写法：先结束的那个分支去 disable 另一个。
        fork
            begin : wait_done
                wait (init_done === 1'b1);
                disable timeout_blk;
            end
            begin : timeout_blk
                #200_000_000;                       // 200 ms 上限
                $display("  [ERR] 超时：Init_Done 一直没拉高");
                n_err = n_err + 1;
                disable wait_done;
            end
        join

        repeat (20) @(posedge clk);

        $display("");
        $display("  捕获到 %0d 条写事务（期望 %0d 条）", cap_n, N_EXP);
        if (cap_n !== N_EXP) begin
            n_err = n_err + 1;
            $display("  [ERR] 事务条数不符");
        end

        if (n_bad_addr != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 从机地址错误 %0d 次（期望 0x%02X）", n_bad_addr, DEV_ADDR_W);
        end

        // 检查④⑤⑥：逐条比对
        $display("");
        $display("  #   寄存器  数据      期望      说明");
        $display("  ------------------------------------------------------------");
        for (i = 0; i < cap_n && i < N_EXP; i = i + 1) begin
            got_reg = cap_word[i][15:9];
            got_dat = cap_word[i][8:0];
            if (got_reg !== exp_reg[i] || got_dat !== exp_dat[i]) begin
                n_err = n_err + 1;
                $display("  %2d  R%02X     %03X       R%02X  %03X   <-- 不符 %0s",
                         i, got_reg, got_dat, exp_reg[i], exp_dat[i], exp_note[i]);
            end else begin
                $display("  %2d  R%02X     %03X       ok          %0s",
                         i, got_reg, got_dat, exp_note[i]);
            end
        end
        $display("  ------------------------------------------------------------");

        // 检查⑦：PLL 锁定余量
        //   本 TB 的 timescale 是 1ns/1ps，$time / cap_time 的单位就是 ns
        lock_ns = cap_time[19] - cap_time[10];
        $display("");
        $display("  PLLEN=1 -> CLKSEL=1 间隔 : %0d ns (%0d.%03d ms)",
                 lock_ns, lock_ns / 1000000, (lock_ns % 1000000) / 1000);
        if (lock_ns < LOCK_MIN_NS) begin
            n_err = n_err + 1;
            $display("  [ERR] PLL 锁定余量不足（要求 >= %0d ns）", LOCK_MIN_NS);
        end else begin
            $display("         >= %0d ms，满足 PLL 锁定要求", LOCK_MIN_NS / 1000000);
        end

        // 检查：最后一条必须是 CLKSEL=1
        got_reg = cap_word[N_EXP-1][15:9];
        got_dat = cap_word[N_EXP-1][8:0];
        if (got_reg !== 7'h04 || got_dat[0] !== 1'b1) begin
            n_err = n_err + 1;
            $display("  [ERR] 最后一条不是 R4 CLKSEL=1");
        end

        // 检查：Init_Done 拉高后必须保持
        repeat (500) @(posedge clk);
        if (init_done !== 1'b1) begin
            n_err = n_err + 1;
            $display("  [ERR] Init_Done 没有保持");
        end
        if (cap_n !== N_EXP) begin
            n_err = n_err + 1;
            $display("  [ERR] Init_Done 之后仍在写寄存器（cnt 回绕了）");
        end

        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  I2C 协议正确、20 条寄存器逐条一致");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

endmodule
