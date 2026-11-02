//=============================================================================
// tb_dc_block.v - 直流阻断器验证
//-----------------------------------------------------------------------------
// 判据分四层，从"数学对不对"到"真实用例管不管用"：
//
//   ① 阶跃时间常数  tau = 2^SH 个采样。阶跃响应是 y[n] = DC * R^n，
//                   所以第 1024 个采样应该约等于 DC/e = 36.77%。
//                   ← 这一条同时验证了"极点位置对不对"
//   ② 直流稳态归零  5*tau 个采样后，残差应 < 1%。
//                   ← 这一条才是"直流被拿掉了"本身
//   ③ 通带增益      1 kHz（远高于 7.46 Hz 截止）应该几乎原样通过。
//                   理论值：|H| = 1.00079，也就是误差 0.08%。
//   ④ 真实用例      直流偏置 + 正弦（就是 ADC 实际输出的样子）
//                   -> 输出应该是一个【居中】的正弦。
//                   ← 如果只测①②，可能做出一个"能去直流但把信号也弄坏"的滤波器
//
//   ⑤ 满量程方波  检查饱和逻辑方向没搞反（负溢出不能 saturate 到 +MAX）
//=============================================================================
`timescale 1ns / 1ps

module tb_dc_block;

    localparam integer DW = 24;
    localparam integer SH = 10;
    localparam integer GW = 2;

    localparam real    TAU   = 1024.0;                  // 2^SH
    localparam real    FS_HZ = 48000.0;
    localparam integer FS_A  = 4194304;                 // 2^22 = 半个满量程
    localparam integer OFF_A = 2097152;                 // 2^21 = 直流偏置 1/4 满量程
    localparam real    PI    = 3.141592653589793;

    integer n_err = 0;

`define CHK(cond, msg) \
        if (cond) $display("  [ok ] %0s", msg); \
        else begin n_err = n_err + 1; $display("  [ERR] %0s", msg); end

    reg clk = 0;
    reg rst_n = 0;
    always #10.416667 clk = ~clk;                       // 48 MHz

    //----------------------------------------------------------- 激励发生器 ---
    //   模式 0：0 -> +FS_A 的阶跃
    //   模式 1：0 -> -FS_A 的阶跃
    //   模式 2：1 kHz 正弦（幅度 FS_A）
    //   模式 3：直流偏置 OFF_A + 1 kHz 正弦（幅度 FS_A）  <- 真实用例
    //   模式 4：满量程方波（周期 8 个采样，专门压饱和逻辑）
    integer mode = 0;
    integer n    = 0;                                   // 采样序号
    reg signed [DW-1:0] din = 24'sd0;

    function signed [DW-1:0] gen;
        input integer m;
        input integer k;
        real ang;
        begin
            ang = 2.0 * PI * 1000.0 * k / FS_HZ;        // 1 kHz
            case (m)
                0: gen = (k >= 0) ? FS_A : 0;
                1: gen = (k >= 0) ? -FS_A : 0;
                2: gen = $rtoi(FS_A * $sin(ang));
                3: gen = OFF_A + $rtoi(FS_A * $sin(ang));
                4: gen = ((k % 8) < 4) ? FS_A : -FS_A;
                default: gen = 0;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (!rst_n) begin
            n   <= 0;
            din <= 24'sd0;
        end else begin
            din <= gen(mode, n);
            n   <= n + 1;
        end
    end

    //--------------------------------------------------------------- 被测 ---
    wire signed [DW-1:0] dout;

    dc_block #(.DW(DW), .SH(SH), .GW(GW)) dut (
        .clk(clk), .rst_n(rst_n), .en(1'b1), .din(din), .dout(dout)
    );

    //----------------------------------------------------------- 观测工具 ---
    //   记录输出极值（用于测幅度），以及"第 k 个采样的输出"（用于测时间常数）
    integer   vmax, vmin;
    integer   y_at_tau;
    integer   i, bad;
    real      gain;

    task reset_dut;
        begin
            rst_n = 0;
            repeat (4) @(posedge clk);
            rst_n = 1;
            @(posedge clk);
            // ⚠️ 不在这里动 n —— 它由 always 块用非阻塞赋值驱动，
            //    TB 里再阻塞赋值会造成读写竞争（账本里栽过）。
            vmax = 0; vmin = 0;
        end
    endtask

    //=========================================================================
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_dc_block.vcd");
            $dumpvars(0, tb_dc_block);
        end

        $display("");
        $display("============================================================");
        $display(" dc_block：一阶高通（DC blocker）");
        $display("============================================================");
        $display("  R = 1 - 2^-%0d，fs = %.0f Hz", SH, FS_HZ);
        $display("  截止频率 f_c = 2^-%0d * fs / (2*pi) = %.2f Hz",
                 SH, 1.0/(1<<SH) * FS_HZ / (2.0*PI));
        $display("  时间常数 tau = 2^%0d / fs = %.2f ms", SH, TAU/FS_HZ*1000.0);
        $display("");

        //---------------------------------------------------------------------
        $display(" [1] 阶跃响应：第 tau=%0d 个采样应该约等于 DC/e = 36.77%%", 1<<SH);
        mode = 0;
        reset_dut;
        begin : step_resp
            integer k;
            for (k = 0; k <= (1<<SH); k = k + 1) begin
                @(negedge clk);
                if (k == (1<<SH)) y_at_tau = dout;
            end
        end
        gain = y_at_tau * 1.0 / FS_A;
        $display("      输入 DC = %0d，第 %0d 个采样输出 = %0d（比值 %.4f）",
                 FS_A, 1<<SH, y_at_tau, gain);
        `CHK((gain > 0.34) && (gain < 0.40), "阶跃在 tau 处衰减到 1/e 附近");

        //---------------------------------------------------------------------
        $display("");
        $display(" [2] 直流稳态：5*tau = %0d 个采样后残差应小于 1%%", 5*(1<<SH));
        begin : dc_settle
            integer k;
            integer y5;
            for (k = 0; k < 5*(1<<SH); k = k + 1) @(negedge clk);
            y5 = dout;
            $display("      5*tau 后输出 = %0d（%.4f%% 满量程）", y5, y5*100.0/FS_A);
            `CHK((y5 >= -(FS_A/100)) && (y5 <= (FS_A/100)), "直流被彻底拿掉");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [3] 负阶跃的对称性：0 -> -FS 也应该衰减到 0");
        mode = 1;
        reset_dut;
        begin : neg_step
            integer y5;
            repeat (5*(1<<SH)) @(negedge clk);
            y5 = dout;
            $display("      5*tau 后输出 = %0d", y5);
            `CHK((y5 >= -(FS_A/100)) && (y5 <= (FS_A/100)), "负直流同样被拿掉（对称）");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [4] 通带增益：1 kHz 正弦应该原样通过（理论 |H| = 1.00079）");
        mode = 2;
        reset_dut;
        begin : passband
            integer k;
            // 先让它稳定（跳过前 20000 个采样）
            repeat (20000) @(negedge clk);
            vmax = -(1<<30); vmin = (1<<30);
            for (k = 0; k < 48; k = k + 1) begin      // 1 kHz 一个周期 = 48 个采样
                @(negedge clk);
                if (dout > vmax) vmax = dout;
                if (dout < vmin) vmin = dout;
            end
            gain = (vmax - vmin) * 0.5 / FS_A;
            $display("      输出幅度 = %0d（输入 %0d），增益 = %.5f",
                     (vmax-vmin)/2, FS_A, gain);
            `CHK((gain > 0.99) && (gain < 1.02), "1 kHz 通带增益约等于 1（误差 < 2%）");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [5] 真实用例：直流偏置 + 正弦 -> 输出必须是【居中的】正弦");
        mode = 3;
        reset_dut;
        begin : real_case
            integer k;
            integer dc_avg;
            repeat (20000) @(negedge clk);
            vmax = -(1<<30); vmin = (1<<30);
            dc_avg = 0;
            for (k = 0; k < 48; k = k + 1) begin
                @(negedge clk);
                if (dout > vmax) vmax = dout;
                if (dout < vmin) vmin = dout;
                dc_avg = dc_avg + dout;
            end
            dc_avg = dc_avg / 48;
            gain = (vmax - vmin) * 0.5 / FS_A;
            $display("      输入 = 偏置 %0d + 正弦 %0d", OFF_A, FS_A);
            $display("      输出：峰值 %0d / %0d，一个周期的均值 = %0d，幅度 = %0d",
                     vmax, vmin, dc_avg, (vmax-vmin)/2);
            $display("      输出中点 = %0d（输入中点 %0d）",
                     (vmax+vmin)/2, OFF_A);
            `CHK((((vmax+vmin)/2) >= -(OFF_A/5)) && (((vmax+vmin)/2) <= (OFF_A/5)),
                 "输出中点被拉回 0 附近（直流偏置被拿掉了）");
            `CHK((dc_avg >= -(OFF_A/5)) && (dc_avg <= (OFF_A/5)),
                 "一个周期的均值接近 0（不会把触发点顶偏）");
            `CHK((gain > 0.99) && (gain < 1.02), "交流幅度没有损失");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [6] 满量程方波：只许饱和（削平），不许回绕（跳变）");
        mode = 4;
        reset_dut;
        begin : saturation
            integer k;
            integer prev, d;
            integer maxjump;
            prev = 0; maxjump = 0;
            repeat (2000) @(negedge clk);
            for (k = 0; k < 4000; k = k + 1) begin
                @(negedge clk);
                d = dout - prev;
                if (d < 0) d = -d;
                if (d > maxjump) maxjump = d;
                prev = dout;
            end
            // ⚠️ 判据要说清"预期值"和"故障值"分别多大：
            //   方波自己就在 +/-半满量程之间跳 -> 正常跳变约 2*FS_A = 8.39e6
            //   符号回绕会从 +8.39e6 直接翻到 -8.39e6 -> 跳变约 2^24 = 16.8e6
            //   门槛取中间（3*2^22 = 12.6e6）。第一版门槛写成 2^23 = 8.39e6，
            //   比正常跳变还小，于是"本来正常的信号"被判成失败。
            $display("      相邻采样最大跳变 = %0d（正常约 %0d，回绕约 %0d）",
                     maxjump, 2*FS_A, 1<<24);
            `CHK(maxjump < 3*(1<<22), "没有出现符号回绕（饱和方向正确）");
            `CHK((dout <= (1<<23)-1) && (dout >= -(1<<23)), "输出始终在 24 位有符号范围内");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [7] 复位：rst_n 拉低后输出清零");
        begin : rst_check
            reset_dut;
            mode = 0;
            repeat (100) @(negedge clk);
            `CHK(dout != 0, "复位后跑起来，输出非零（有信号）");
            rst_n = 0;
            @(negedge clk); @(negedge clk);
            $display("      rst_n=0 后输出 = %0d", dout);
            `CHK(dout == 0, "复位把输出清零");
            rst_n = 1;
        end

        //---------------------------------------------------------------------
        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  时间常数/去直流/通带/真实用例/饱和全对");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

endmodule
