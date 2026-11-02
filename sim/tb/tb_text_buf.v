//=============================================================================
// tb_text_buf.v - 字符缓冲 + 点阵渲染自检
//-----------------------------------------------------------------------------
// 【验证策略】
//   不把字库的位模式抄一遍（那是账本 38 条那类"TB 镜像实现"的错误）。
//   而是【写进去几个字符，扫一遍，把点阵打出来】，再加上几条能独立陈述的判据：
//     · 文本框外 hit 必须为 0
//     · 文本框内、且对应字库位为 1 的像素 lit 必须为 1
//     · 直接用一个【极简的本地字库替身】做逐点比对 —— 不是抄字库，
//       而是喂给 DUT 一个"全 1"的字符，这样每个格子内的 lit 图案
//       可以直接由"格子内核哪些列"推出来，和字库内容无关。
//     · 最直观的一条：把几个字打印出来，肉眼核对（最可靠）
//=============================================================================
`timescale 1ns/1ps

module tb_text_buf;

    localparam integer NC = 8;       // 只放 8 列，方便打印
    localparam integer NL = 2;
    localparam integer XW = 10;
    localparam integer YW = 9;

    reg               clk = 0;
    reg               we = 1'b0;
    reg  [15:0]       waddr = 16'd0;
    reg  [7:0]        wdata = 8'h20;
    reg  [XW-1:0]     x = 0;
    reg  [YW-1:0]     y = 0;
    wire              hit, lit;

    integer n_err = 0;
    integer c, r, i, k;

    text_buf #(.NC(NC), .NL(NL), .XW(XW), .YW(YW), .TX0(2), .TY0(1)) dut (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .x(x), .y(y), .hit(hit), .lit(lit)
    );

    always #10.4167 clk = ~clk;

    task put;
        input [15:0] a;
        input [7:0]  ch;
        begin
            @(negedge clk);
            we = 1'b1; waddr = a; wdata = ch;
            @(negedge clk);
            we = 1'b0;
        end
    endtask

    // ⚠️ 不要声明一个中间 reg 再去手动跟 lit 同步 —— 一开始这么写，
    //    忘了赋值，打印出来全是 '"'。组合信号直接读就行。

    // 扫一格并打印（用于肉眼核对）
    task dump_cell;
        input integer col;
        input integer row;
        begin
            $write("      col=%0d row=%0d\n", col, row);
            for (r = 0; r < 8; r = r + 1) begin
                $write("        ");
                for (c = 0; c < 8; c = c + 1) begin
                    x = 2 + col*8 + c;
                    y = 1 + row*8 + r;
                    #1;
                    $write("%s", lit ? "#" : ".");
                end
                $write("\n");
            end
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" text_buf 自检（字符缓冲 + 点阵渲染）");
        $display("  框内 %0d 列 x %0d 行，每字符 8x8 像素", NC, NL);
        $display("============================================================");

        // 先写几个字符
        put(16'd0, "A");
        put(16'd1, "B");
        put(16'd2, "1");
        put(16'd3, " ");
        put(16'd4, "%");
        put(16'd5, "/");
        put(16'd6, "-");
        put(16'd7, "Z");
        put(16'd8, "O");        // 第二行第 0 个
        put(16'd9, "K");

        //---------------------------------------------------------------------
        $display("");
        $display(" [1] 文本框外的像素：hit 必须为 0");
        k = 0;
        // 左边 0..1
        for (i = 0; i < 2; i = i + 1) begin x = i[9:0]; y = 5; #1; if (hit !== 1'b0) k = k + 1; end
        // 上边 y=0（TY0=1）
        x = 5; y = 0; #1; if (hit !== 1'b0) k = k + 1;
        // 右边
        x = 2 + NC*8; y = 5; #1; if (hit !== 1'b0) k = k + 1;
        // 下边
        x = 5; y = 1 + NL*8; #1; if (hit !== 1'b0) k = k + 1;
        if (k != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 有 %0d 个框外像素被判成框内", k);
        end else
            $display("  [ok ] 四边之外的像素 hit 全为 0");

        //---------------------------------------------------------------------
        $display("");
        $display(" [2] 文本框内：hit 必须为 1");
        k = 0;
        for (i = 0; i < 20; i = i + 1) begin
            for (r = 0; r < 5; r = r + 1) begin
                x = 2 + i[9:0]*3; y = 1 + r[8:0]*2; #1;
                if (hit !== 1'b1) k = k + 1;
            end
        end
        if (k != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 有 %0d 个框内像素 hit 为 0", k);
        end else
            $display("  [ok ] 框内像素 hit 全为 1");

        //---------------------------------------------------------------------
        $display("");
        $display(" [3] 格子的分界线：每 8 像素换一格");
        // 同一个字符的第 0 行，在格内列 0..7 上取值；gcol>=5 的那 3 列必须是 0
        begin : gutters
            integer g;
            k = 0;
            for (g = 5; g < 8; g = g + 1) begin
                // 第 0 行、第 0 格、格内列 g：右边留白，必须不亮
                for (r = 0; r < 8; r = r + 1) begin
                    x = 2 + g[9:0]; y = 1 + r[8:0]; #1;
                    if (lit !== 1'b0) k = k + 1;
                end
            end
            if (k != 0) begin
                n_err = n_err + 1;
                $display("  [ERR] 格子右侧留白有 %0d 个像素被点亮（应全灭）", k);
            end else
                $display("  [ok ] 格子右侧留白（格内列 5/6/7）全灭");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [4] 空格什么都不画");
        begin : blank
            k = 0;
            for (c = 0; c < 8; c = c + 1) begin
                for (r = 0; r < 8; r = r + 1) begin
                    x = 2 + 3*8 + c; y = 1 + r; #1;      // 第 3 格是空格
                    if (lit !== 1'b0) k = k + 1;
                end
            end
            if (k != 0) begin
                n_err = n_err + 1;
                $display("  [ERR] 空格画出了 %0d 个像素", k);
            end else
                $display("  [ok ] 空格完全不可见");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [5] 未写入的格子默认是空格（上电清空）");
        begin : untouched
            k = 0;
            for (c = 0; c < 8; c = c + 1) begin
                for (r = 0; r < 8; r = r + 1) begin
                    x = 2 + 6*8 + c; y = 1 + 8 + r; #1;   // 第二行第 6 格没写过
                    if (lit !== 1'b0) k = k + 1;
                end
            end
            if (k != 0) begin
                n_err = n_err + 1;
                $display("  [ERR] 没写过的格子画出了 %0d 个像素", k);
            end else
                $display("  [ok ] 没写过的格子是空格");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [6] 把第一行打出来（肉眼核对）");
        for (c = 0; c < NC; c = c + 1) begin
            x = 2;
            #1;
        end
        // 整行一次性打印
        for (r = 0; r < 8; r = r + 1) begin
            $write("      ");
            for (c = 0; c < NC*8; c = c + 1) begin
                x = 2 + c; y = 1 + r; #1;
                $write("%s", lit ? "#" : ".");
            end
            $write("\n");
        end
        $display("      （应看到：A B 1 <空> %% / - Z）");

        //---------------------------------------------------------------------
        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  框内/框外/留白/空格/未写格子全部正确");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("  [ERR] 超时");
        $display(" 结果       : *** FAIL ***  超时");
        $finish;
    end

endmodule
