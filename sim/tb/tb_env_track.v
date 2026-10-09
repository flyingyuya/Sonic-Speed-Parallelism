//=============================================================================
// tb_env_track.v - 包络跟踪 / 自适应门限验证
//-----------------------------------------------------------------------------
//   ① 静音 -> 门限 = TH_MIN（下限兜底，防止噪声乱触发）
//      ← 这是自适应门限最容易翻车的地方，必须单独验
//   ② 满量程正弦 -> 门限 ~= A/8（包络跟到峰值 A）
//   ③ **小信号 -> 门限跟着变小** ← 这就是"自适应"本身
//   ④ 快攻慢放：幅度突变上去要跟得快，掉下来要放得慢
//   ⑤ 突变到静音后，门限是【慢慢】降回 TH_MIN，不是立刻
//=============================================================================
`timescale 1ns / 1ps

module tb_env_track;
    localparam integer DW = 24;
    localparam integer AS = 6, DS = 12, KP = 3, TH_MIN = 4096;
    localparam integer FS_HZ = 48000;

    integer n_err = 0;
`define CHK(cond, msg) \
        if (cond) $display("  [ok ] %0s", msg); \
        else begin n_err = n_err + 1; $display("  [ERR] %0s", msg); end

    reg clk = 0; always #10.416667 clk = ~clk;      // 48 MHz
    reg rst_n = 0;

    integer amp  = 0;          // 正弦幅度
    real    freq = 1000.0;
    reg     on   = 0;          // 0 = 静音
    integer n    = 0;
    reg signed [DW-1:0] din = 24'sd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            n   <= 0;
            din <= 24'sd0;
        end else begin
            din <= on ? $rtoi(amp * $sin(2.0*3.141592653589793*freq*n/FS_HZ)) : 24'sd0;
            n   <= n + 1;
        end
    end

    wire signed [DW-1:0] th;
    wire [DW-1:0]        env;

    env_track #(.DW(DW), .AS(AS), .DS(DS), .KP(KP), .TH_MIN(TH_MIN)) dut (
        .clk(clk), .rst_n(rst_n), .en(1'b1), .din(din), .th(th), .env(env)
    );

    integer i;
    task reset_dut;
        begin
            rst_n = 0; on = 0;
            repeat (4) @(posedge clk);
            rst_n = 1;
            repeat (4) @(posedge clk);
        end
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_env_track.vcd");
            $dumpvars(0, tb_env_track);
        end
        $display("");
        $display("============================================================");
        $display(" env_track：自适应触发门限（快攻 AS=%0d / 慢放 DS=%0d / TH=env>>%0d）", AS, DS, KP);
        $display("============================================================");
        $display("  时间常数：攻击 2^%0d = %0d 采样 = %.1f ms；释放 2^%0d = %0d 采样 = %.0f ms",
                 AS, 1<<AS, (1<<AS)*1000.0/FS_HZ, DS, 1<<DS, (1<<DS)*1000.0/FS_HZ);
        $display("");

        //---------------------------------------------------------------------
        $display(" [1] 静音 -> 门限 = TH_MIN = %0d（下限兜底）", TH_MIN);
        reset_dut; on = 0; amp = 0;
        repeat (20000) @(negedge clk);
        $display("      静音 20000 拍后：env = %0d，th = %0d", env, th);
        `CHK(th == TH_MIN, "静音时门限被 TH_MIN 托住（不会掉到 0）");

        //---------------------------------------------------------------------
        $display("");
        $display(" [2] 满量程正弦 -> 门限 ~= A/8（包络跟到峰值）");
        amp = (1<<22); freq = 1000.0; n = 0; on = 1;
        repeat (40000) @(negedge clk);
        $display("      幅度 %0d：env = %0d，th = %0d（A/8 = %0d）", amp, env, th, amp/8);
        // ⚠️ 期望值不是理想化的 A/8：攻击是【一阶指数】，包络稳定在峰值附近
        //    但到不了 100%（1 kHz 正弦、AS=6 时实测 93%）。
        //    所以带宽按 amp/12 .. amp/6 给，并在注释里写明实测比例。
        //    （这类"门槛拍脑袋"的错这一轮已经犯了 3 次，见账本 93/100/101。）
        `CHK((th > amp/12) && (th < amp/6), "门限在峰值的 1/12 ~ 1/6 之间（实测约 1/8.6）");

        //---------------------------------------------------------------------
        $display("");
        $display(" [3] 【核心】小信号 -> 门限自动跟着变小");
        amp = (1<<18); n = 0;                 // 比上面小 16 倍
        repeat (40000) @(negedge clk);
        $display("      幅度 %0d（小了 16 倍）：env = %0d，th = %0d", amp, env, th);
        `CHK((th > amp/12) && (th < amp/6), "门限跟着缩到同样的比例 —— 小信号也能触发了");
        `CHK(th < (1<<19), "门限确实降下来了（不是被固定值卡住）");

        //---------------------------------------------------------------------
        $display("");
        $display(" [4] 快攻慢放：幅度突变上去立刻跟，掉下来慢慢放");
        reset_dut;
        amp = (1<<20); n = 0; on = 1;
        repeat (40000) @(negedge clk);        // 先稳定在小信号
        begin : fast_attack
            integer env_before;
            env_before = env;
            amp = (1<<22); n = 0;             // 突然放大 4 倍
            repeat (200) @(negedge clk);      // 200 拍 = 3 个攻击时间常数
            $display("      放大 4 倍后 200 拍：env %0d -> %0d", env_before, env);
            `CHK(env > (1<<20)*3, "攻击很快（200 拍就追上去了）");
        end
        begin : slow_release
            integer env_before;
            env_before = env;
            amp = (1<<18); n = 0;             // 突然掉回小信号
            repeat (500) @(negedge clk);      // 500 拍，远小于释放常数 4096
            $display("      掉回 1/16 后 500 拍：env %0d -> %0d（释放常数 %0d 拍）",
                     env_before, env, 1<<DS);
            `CHK(env > env_before/2, "释放很慢（500 拍几乎没降下来）");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [5] 突变到静音：门限慢慢降，不是立刻掉到 TH_MIN");
        on = 0; n = 0;
        repeat (1000) @(negedge clk);
        $display("      静音 1000 拍后 th = %0d（还远高于 TH_MIN=%0d）", th, TH_MIN);
        `CHK(th > TH_MIN, "静音初期门限仍然偏高（慢放，不会瞬间失灵）");
        repeat (40000) @(negedge clk);
        $display("      静音 40000 拍后 th = %0d", th);
        `CHK(th == TH_MIN, "长时间静音后回到 TH_MIN");

        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  下限/跟随/自适应/快攻慢放全对");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end
endmodule
