//=============================================================================
// tb_status_line.v - 状态行生成器自检
//-----------------------------------------------------------------------------
// 直接收它吐出来的字符流，拼成字符串和期望值比较。
// 期望值是可以【独立陈述】的："V7 S0 H6 G8 B0 D0" 这种格式一眼就能核对。
//=============================================================================
`timescale 1ns/1ps

module tb_status_line;

    localparam integer NLEN = 17;

    reg        clk = 0, rst_n = 0;
    reg [7:0]  cfg_view = 8'h07, cfg_style = 8'h00, cfg_hue_spd = 8'h06;
    reg [7:0]  cfg_wave_gain = 8'h08, cfg_bg_mode = 8'h00, cfg_demo = 8'h00;
    wire       we;
    wire [15:0] waddr;
    wire [7:0]  wdata;

    integer n_err = 0;
    integer i;

    status_line #(.NLEN(NLEN)) dut (
        .clk(clk), .rst_n(rst_n),
        .cfg_view(cfg_view), .cfg_style(cfg_style), .cfg_hue_spd(cfg_hue_spd),
        .cfg_wave_gain(cfg_wave_gain), .cfg_bg_mode(cfg_bg_mode),
        .cfg_demo(cfg_demo),
        .we(we), .waddr(waddr), .wdata(wdata)
    );

    always #10.4167 clk = ~clk;

    // ⚠️ 别把这个数组叫 buf —— `buf` 是 Verilog 的【内建门原语】，
    //   不能当标识符。iverilog 报的是毫无帮助的 "syntax error"，
    //   而它自己也只在报错信息里提到 "variable list"，查起来非常费劲。
    //   遇到"平平无奇的声明报语法错"，先怀疑是不是撞了关键字/原语名。
    reg [7:0] line_buf [0:63];
    integer   n_wr;

    // 收集写入
    always @(posedge clk) begin
        if (rst_n && we) begin
            line_buf[waddr[5:0]] = wdata;
            n_wr = n_wr + 1;
        end
    end

    // 和期望字符串比较
    // ⚠️ 别把这个任务叫 expect —— 它是 SystemVerilog 的关键字（并发断言），
    //   Verible 会直接报语法错。iverilog 反而不报（它只认 Verilog），
    //   所以这种"两边标准不一样"的名字要小心。
    task want_line;
        input [8*NLEN-1:0] want;
        reg [7:0] w;
        begin
            for (i = 0; i < NLEN; i = i + 1) begin
                w = want[8*(NLEN-1-i) +: 8];
                if (line_buf[i] !== w) begin
                    n_err = n_err + 1;
                    $display("  [ERR] 第 %0d 个字符是 '%c'(%02h)，期望 '%c'(%02h)",
                             i, line_buf[i], line_buf[i], w, w);
                end
            end
        end
    endtask

    task show;
        begin
            $write("      实测: \"");
            for (i = 0; i < NLEN; i = i + 1) $write("%c", line_buf[i]);
            $write("\"\n");
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" status_line 自检（配置 -> 一行文字）");
        $display("============================================================");

        n_wr = 0;
        repeat (5) @(posedge clk);
        rst_n = 1;

        //---------------------------------------------------------------------
        $display("");
        $display(" [1] 上电后自动写一次（默认 V7 S0 H6 G8 B0 D0）");
        repeat (60) @(posedge clk);
        if (n_wr < NLEN) begin
            n_err = n_err + 1;
            $display("  [ERR] 只写了 %0d 个字符（应 >= %0d）", n_wr, NLEN);
        end else
            $display("  [ok ] 上电自动写入 %0d 个字符", n_wr);
        show();
        want_line("V7 S0 H6 G8 B0 D0");
        if (n_err == 0) $display("  [ok ] 内容与期望 'V7 S0 H6 G8 B0 D0' 一致");

        //---------------------------------------------------------------------
        $display("");
        $display(" [2] 配置没变时不应该重写");
        begin : no_rewrite
            integer n0;
            n0 = n_wr;
            repeat (200) @(posedge clk);
            if (n_wr != n0) begin
                n_err = n_err + 1;
                $display("  [ERR] 配置没变却又写了 %0d 次", n_wr - n0);
            end else
                $display("  [ok ] 200 拍内一次都没重写（按需刷新生效）");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [3] 改一个字段就重写，且内容跟着变");
        cfg_view = 8'h02;
        repeat (60) @(posedge clk);
        show();
        want_line("V2 S0 H6 G8 B0 D0");
        if (n_err == 0) $display("  [ok ] V 变成 2");

        cfg_wave_gain = 8'h0F;      // 也测一下 A-F 的十六进制
        repeat (60) @(posedge clk);
        show();
        want_line("V2 S0 H6 GF B0 D0");
        if (n_err == 0) $display("  [ok ] 增益 0F 显示成 'F'（十六进制大写）");

        cfg_demo = 8'h03;
        repeat (60) @(posedge clk);
        show();
        want_line("V2 S0 H6 GF B0 D3");
        if (n_err == 0) $display("  [ok ] D 字段跟着变");

        //---------------------------------------------------------------------
        $display("");
        $display(" [4] 再改回原值也要重写（判据是「和上次不同」，不是「和默认不同」）");
        begin : again
            integer n0;
            n0 = n_wr;
            cfg_view = 8'h07;
            repeat (60) @(posedge clk);
            if (n_wr - n0 < NLEN) begin
                n_err = n_err + 1;
                $display("  [ERR] 改回原值没有触发重写");
            end else begin
                $display("  [ok ] 改回原值触发了重写");
                show();
            end
        end

        //---------------------------------------------------------------------
        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  内容/按需刷新/十六进制全部正确");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

endmodule
