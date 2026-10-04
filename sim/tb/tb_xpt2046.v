//=============================================================================
// tb_xpt2046.v - XPT2046 SPI 驱动自检
//-----------------------------------------------------------------------------
// 接一个 XPT2046 行为模型（sim/tb/xpt2046_model.v），验证：
//   ① 空闲电平：nCS 高、DCLK 低（SPI 模式 0）
//   ② 命令与坐标：读 X 发 0xD0、读 Y 发 0x90，读回值和模型设的一致
//   ③ 一次 start 恰好 2 次转换
//   ④ 连续两次采样都拿到新值（不是只有第一次对）
//   ⑤ DCLK 周期（约 1 us -> 1 MHz）
//   ⑥ busy / valid 时序（valid 必须单拍）
//
// 【这个 TB 抓到过的真 bug，都记在问题账本里】
//   · DUT 在两次转换之间【没有抬起 nCS】—— XPT2046 只在 nCS 下降沿之后的
//     头 8 位采样 DIN，保持 CS 低继续打时钟只会用旧命令再转同一个通道，
//     换不了通道。现象是 x 和 y 读回同一个值。
//   · 模型自身两处 off-by-one：通道位取成 [5:3]（应 [6:4]）、忙位差一拍。
//     -> **行为模型也要被怀疑**，它和 DUT 都会错。
//   · 本 TB 自己的两个坑：用 task 传中文串会乱码（要用宏）；
//     先 run_once 再抓 DCLK 边沿会永远等下去（事务已结束）。
//=============================================================================
`timescale 1ns/1ps

module tb_xpt2046;

    localparam integer CLK_HZ  = 48_000_000;
    localparam integer SCLK_HZ = 1_000_000;
    localparam integer DCLK_NS = 1000;      // 48e6/(2*1e6) = 24 clk = 1us

    reg         clk = 0, rst_n = 0;
    reg         start = 0;
    wire        busy, valid;
    wire [11:0] x_pos, y_pos;
    wire        tp_dclk, tp_cs_n, tp_din, tp_dout;

    reg [11:0]  force_x = 12'h123;
    reg [11:0]  force_y = 12'hABC;
    wire [7:0]  last_cmd;
    wire [3:0]  n_cmd;
    wire [7:0]  n_dclk;

    integer n_err = 0;
    integer i;
    integer nbusy, nvalid;

    // 判据宏。
    //   ⚠️ 不要写成 `task chk(input [8*64-1:0] msg)` —— iverilog 对过宽的
    //   中文字符串参数处理有问题，打印出来全是问号，还会让人怀疑判据本身。
    //   Verilog-2001 里传字符串就用宏，实测可靠。
`define CHK(cond, msg) \
        if (cond) $display("  [ok ] %0s", msg); \
        else begin n_err = n_err + 1; $display("  [ERR] %0s", msg); end

    xpt2046 #(.CLK_HZ(CLK_HZ), .SCLK_HZ(SCLK_HZ)) dut (
        .clk(clk), .rst_n(rst_n),
        .start(start), .busy(busy), .valid(valid),
        .x_pos(x_pos), .y_pos(y_pos),
        .tp_dclk(tp_dclk), .tp_cs_n(tp_cs_n), .tp_din(tp_din), .tp_dout(tp_dout)
    );

    xpt2046_model u_model (
        .tp_dclk(tp_dclk), .tp_cs_n(tp_cs_n), .tp_din(tp_din), .tp_dout(tp_dout),
        .force_x(force_x), .force_y(force_y),
        .last_cmd(last_cmd), .n_cmd(n_cmd), .n_dclk(n_dclk)
    );

    always #10.4167 clk = ~clk;     // 48 MHz

    task do_start;
        begin
            @(negedge clk);
            start = 1'b1;
            @(negedge clk);
            start = 1'b0;
        end
    endtask

    // 起一次采样，然后在【同一个循环里】同时数 busy 和 valid。
    //   不要"先等一会儿再找 valid"—— 整个转换只要约 2300 拍，
    //   等回来的时候单拍脉冲早就过去了。
    task run_once;
        begin
            do_start();
            nbusy  = 0;
            nvalid = 0;
            for (i = 0; i < 6000; i = i + 1) begin
                @(posedge clk);
                if (busy)  nbusy  = nbusy  + 1;
                if (valid) nvalid = nvalid + 1;
            end
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" xpt2046 自检（SPI 驱动 + 从机模型）");
        $display("   DCLK 目标 %0d kHz", SCLK_HZ/1000);
        $display("============================================================");

        repeat (10) @(posedge clk);
        rst_n = 1;
        repeat (10) @(posedge clk);

        //---------------------------------------------------------------------
        $display("");
        $display(" [1] 空闲电平");
        `CHK(tp_cs_n === 1'b1, "空闲时 nCS = 1（器件能进掉电）");
        `CHK(tp_dclk === 1'b0, "空闲时 DCLK = 0（SPI 模式 0）");
        `CHK(busy    === 1'b0, "空闲时 busy = 0");

        //---------------------------------------------------------------------
        $display("");
        $display(" [2] 一次 start：读 X 再读 Y，值必须对");
        force_x = 12'h123;
        force_y = 12'hABC;
        run_once();
        $display("      读回 x=%03h  y=%03h（模型给的 %03h / %03h）",
                 x_pos, y_pos, force_x, force_y);
        `CHK(x_pos === force_x, "x 读回正确");
        `CHK(y_pos === force_y, "y 读回正确");
        `CHK(n_cmd === 4'd2,    "一次 start 恰好 2 次转换（X 然后 Y）");

        //---------------------------------------------------------------------
        $display("");
        $display(" [3] 换一组坐标，必须跟着变（不是硬编码）");
        force_x = 12'h7FF;
        force_y = 12'h001;
        run_once();
        $display("      读回 x=%03h  y=%03h", x_pos, y_pos);
        `CHK(x_pos === 12'h7FF && y_pos === 12'h001, "坐标跟着模型变");

        //---------------------------------------------------------------------
        $display("");
        $display(" [4] 连续两次采样都要拿到新值");
        begin : twice
            reg [11:0] x1, y1;
            force_x = 12'h0F0; force_y = 12'h00F;
            run_once();
            x1 = x_pos; y1 = y_pos;
            force_x = 12'h5A5; force_y = 12'h3C3;
            run_once();
            $display("      第一次 %03h/%03h，第二次 %03h/%03h", x1, y1, x_pos, y_pos);
            `CHK(x1 === 12'h0F0 && y1 === 12'h00F, "第一次采样正确");
            `CHK(x_pos === 12'h5A5 && y_pos === 12'h3C3,
                 "第二次采样也正确（不是只有第一次对）");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [5] DCLK 周期");
        begin : freq
            time t_a, t_b;
            integer period_ns;
            // ⚠️ 不能先 run_once 再抓边沿：那时事务已结束、DCLK 静止，
            //    @(posedge tp_dclk) 会永远等下去（本 TB 一开始就是这么超时的）。
            //    正确做法是自己发 start，在事务【进行中】抓两个边沿。
            do_start();
            @(posedge tp_dclk); t_a = $time;
            @(posedge tp_dclk); t_b = $time;
            // $time 在 `timescale 1ns/1ps 下已经是 ns，不用再换算
            period_ns = t_b - t_a;
            $display("      相邻两个 DCLK 上升沿间隔 %0d ns（期望 %0d ns）",
                     period_ns, DCLK_NS);
            `CHK(period_ns >= DCLK_NS-20 && period_ns <= DCLK_NS+20,
                 "DCLK 周期符合设定");
            repeat (6000) @(posedge clk);       // 让这次事务跑完
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [6] busy / valid 时序");
        force_x = 12'h111;
        force_y = 12'h222;
        run_once();
        $display("      busy 拉高 %0d 拍，valid 出现 %0d 次", nbusy, nvalid);
        `CHK(nbusy > 0,    "转换期间 busy 确实拉高");
        `CHK(nvalid === 1, "valid 恰好一次（单拍脉冲）");
        `CHK(x_pos === 12'h111 && y_pos === 12'h222, "这次的值也对");

        //---------------------------------------------------------------------
        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  命令/坐标/时序/DCLK/握手全部正确");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

    initial begin
        #40_000_000;
        $display("  [ERR] 超时");
        $display(" 结果       : *** FAIL ***  超时");
        $finish;
    end

endmodule
