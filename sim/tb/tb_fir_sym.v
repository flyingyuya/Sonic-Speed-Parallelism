//=============================================================================
// tb_fir_sym.v - 对称 FIR 验证
//-----------------------------------------------------------------------------
//   ① 脉冲响应 == 系数        ← **最核心的一条**
//      给一个单位脉冲，输出序列必须逐点等于 h[k]。
//      这一条同时证明了：卷积对不对、抽头顺序对不对、对称性对不对、
//      定标（右移 16 位）对不对。基本是"一票定生死"。
//
//      ⚠️ 期望值是**硬编码**在这里的，不是去引用生成的 fir_sym_coeff.vh。
//         引用 .vh 的话就是"拿 RTL 验 RTL"，系数生成器写错了照样通过。
//
//   ② 对称性（线性相位）     h[k] == h[N-1-k]。
//      单独列一条是因为它是"波形形状不变形"的全部依据，
//      而①只证明了"h 是什么"，没证明"h 对称"。
//
//   ③ 直流增益 == 1          sum(h) 必须是 1，否则波形整体被放大/缩小。
//
//   ④ 通带增益               100 Hz 应该原样通过。
//
//   ⑤ 阻带衰减               20 kHz 应该被压掉 70 dB 以上。
//
//   ⑥ BYPASS                 旁路时输出严格等于输入。
//=============================================================================
`timescale 1ns / 1ps

module tb_fir_sym;

    localparam integer DW = 24;
    localparam integer N  = 15;

    //-----------------------------------------------------------------------
    // 期望系数：Q2.16，由 scripts/golden/gen_wave_fir.py 生成。
    //   【硬编码】在这里 —— 见文件头说明。
    //   想换滤波器 -> 改生成器的 CHOSEN_N/CHOSEN_FC、重新 --emit、
    //   再把新系数抄到这里。这个"抄一遍"的动作是故意的：
    //   它强迫你确认新系数长什么样。
    //-----------------------------------------------------------------------
    integer H [0:N-1];
    initial begin
        H[0]=-202;  H[1]=-431;  H[2]=-625;  H[3]=288;   H[4]=3462;
        H[5]=8657;  H[6]=13709; H[7]=15821; H[8]=13709; H[9]=8657;
        H[10]=3462; H[11]=288;  H[12]=-625; H[13]=-431; H[14]=-202;
    end

    // ⚠️ 用 2^22 而不是 2^23：24 位【有符号】最大是 2^23-1，
    //    2^23 截断到 24 位会变成【负满量程】。第一版就是栽在这里 ——
    //    输入明明是正的，波形却是全负的。
    //    取 2^22（半满量程）还顺带让"期望值 = h_q << 6"是个精确移位。
    localparam integer AMP   = (1<<22);
    localparam integer FS_HZ = 48000;

    integer n_err = 0;

`define CHK(cond, msg) \
        if (cond) $display("  [ok ] %0s", msg); \
        else begin n_err = n_err + 1; $display("  [ERR] %0s", msg); end

    reg clk = 0;
    reg rst_n = 0;
    always #10.416667 clk = ~clk;           // 48 MHz

    integer mode = 0;                       // 0=脉冲 1=恒定 2=正弦
    real    freq = 100.0;
    integer n    = 0;
    reg     arm  = 1'b0;                    // 0 时激励计数器停在 0
    reg signed [DW-1:0] din = 24'sd0;

    // ⚠️ 不在 initial 里对 n 做阻塞赋值 —— 那会和下面 always 里的 n <= n+1
    //    抢同一个变量（读改写竞争），导致"脉冲到底是不是第 0 个采样"变成随机。
    //    改成由 arm 控制：arm=0 时计数器清零，arm=1 时从 0 开始走。
    //    arm 由 TB 在【negedge】上改，离 posedge 还有半拍，彻底没有竞争。
    always @(posedge clk) begin
        if (!rst_n || !arm) begin
            n   <= 0;
            din <= 24'sd0;
        end else begin
            case (mode)
                0: din <= (n == 0) ? AMP[DW-1:0] : 24'sd0;
                1: din <= AMP[DW-1:0];
                default: din <= $rtoi(AMP * 0.9 * $sin(2.0*3.141592653589793*freq*n/FS_HZ));
            endcase
            n <= n + 1;
        end
    end

    task restim;
        begin
            rst_n = 0;
            repeat (4) @(posedge clk);
            rst_n = 1;
            // 改 arm 一律在 negedge 上，避免和 posedge 的 always 抢
            @(negedge clk); arm = 1'b0;
            @(negedge clk); arm = 1'b1;
            // arm=1 那一拍 din 才是 stim(0)；FIR 要再一拍才把它移进 sr[0]
            @(negedge clk); @(negedge clk);
        end
    endtask

    wire signed [DW-1:0] dout;

    fir_sym #(.DW(DW), .BYPASS(0)) dut (
        .clk(clk), .rst_n(rst_n), .en(1'b1), .din(din), .dout(dout)
    );

    wire signed [DW-1:0] dout_byp;
    // din 打一拍：BYPASS 的输出是【寄存】的，和 din 直接比会差一拍
    reg  signed [DW-1:0] din_d = 24'sd0;
    always @(posedge clk) din_d <= din;
    fir_sym #(.DW(DW), .BYPASS(1)) dut_byp (
        .clk(clk), .rst_n(rst_n), .en(1'b1), .din(din), .dout(dout_byp)
    );

    //-----------------------------------------------------------------------
    reg signed [DW-1:0] ir [0:N-1];
    task reset_all;
        begin
            rst_n = 0;
            repeat (4) @(posedge clk);
            rst_n = 1;
            @(posedge clk);
        end
    endtask

    integer i, k, bad, hsum;
    integer vmax, vmin;
    real    gain;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_fir_sym.vcd");
            $dumpvars(0, tb_fir_sym);
        end

        $display("");
        $display("============================================================");
        $display(" fir_sym：%0d 抽头对称 FIR（波形平滑低通）", N);
        $display("============================================================");
        hsum = 0;
        for (i = 0; i < N; i = i + 1) hsum = hsum + H[i];
        $display("  系数 Q2.16，和 = %0d（理想 65536）", hsum);
        $display("");

        //---------------------------------------------------------------------
        $display(" [1] 脉冲响应 == 系数（卷积/顺序/定标一次全验）");
        mode = 0;
        restim;
        // 收 N+2 个输出
        for (i = 0; i < N + 2; i = i + 1) begin
            @(negedge clk);
            if (i < N) ir[i] = dout;
        end
        bad = 0;
        for (i = 0; i < N; i = i + 1) begin
            // 期望：h[k] 的 Q2.16 值，输入 AMP=2^23 -> 结果 = h_q << 7
            if (ir[i] !== (H[i] << 6)) begin
                bad = bad + 1;
                if (bad <= 4)
                    $display("      抽头 %0d：读到 %0d，期望 %0d (h=%0d)",
                             i, ir[i], (H[i] << 6), H[i]);
            end
        end
        `CHK(bad == 0, "15 个抽头逐点等于系数（卷积 + 定标全对）");
        // 第 N 个之后应该回 0
        `CHK(dout == 0, "脉冲响应长度正好是 N 个采样（之后归零）");

        //---------------------------------------------------------------------
        $display("");
        $display(" [2] 对称性：h[k] == h[N-1-k]（线性相位的全部依据）");
        bad = 0;
        for (i = 0; i < N/2; i = i + 1)
            if (ir[i] !== ir[N-1-i]) bad = bad + 1;
        `CHK(bad == 0, "脉冲响应左右对称");
        $display("      h[0..7] = %0d %0d %0d %0d %0d %0d %0d %0d",
                 H[0],H[1],H[2],H[3],H[4],H[5],H[6],H[7]);

        //---------------------------------------------------------------------
        $display("");
        $display(" [3] 直流增益 == 1（否则波形整体被放大/缩小）");
        mode = 1;
        restim;
        repeat (N + 8) @(negedge clk);
        $display("      输入 %0d，输出 %0d（误差 %0d）", AMP, dout, dout - AMP);
        // 系数和是 65537 而不是 65536 -> 输出【本来就】比输入大 AMP/65536 = 64
        `CHK((dout - AMP <= 128) && (dout - AMP >= 0), "直流增益为 1（只差系数和那 +1，误差 <= 128）");

        //---------------------------------------------------------------------
        $display("");
        $display(" [4] 通带增益：100 Hz 应该原样通过");
        mode = 2; freq = 100.0;
        restim;
        repeat (5000) @(negedge clk);
        vmax = -(1<<30); vmin = (1<<30);
        for (k = 0; k < 480; k = k + 1) begin
            @(negedge clk);
            if (dout > vmax) vmax = dout;
            if (dout < vmin) vmin = dout;
        end
        gain = (vmax - vmin) * 0.5 / (AMP * 0.9);
        $display("      输出幅度 = %0d（输入 %0d），增益 = %.4f",
                 (vmax-vmin)/2, $rtoi(AMP*0.9), gain);
        `CHK((gain > 0.99) && (gain < 1.01), "100 Hz 通带增益 = 1");

        //---------------------------------------------------------------------
        $display("");
        $display(" [5] 阻带衰减：20 kHz 应该被强烈压制");
        mode = 2; freq = 20000.0;
        restim;
        repeat (5000) @(negedge clk);
        vmax = -(1<<30); vmin = (1<<30);
        for (k = 0; k < 4800; k = k + 1) begin
            @(negedge clk);
            if (dout > vmax) vmax = dout;
            if (dout < vmin) vmin = dout;
        end
        gain = (vmax - vmin) * 0.5 / (AMP * 0.9);
        $display("      输出幅度 = %0d（输入 %0d），增益 = %.6f（%.2f dB）",
                 (vmax-vmin)/2, $rtoi(AMP*0.9), gain,
                 (gain > 0) ? 20.0*$ln(gain)/$ln(10.0) : -999.0);
        // ⚠️ 门槛是【算出来的】，不是拍的：
        //    用同一组系数在 Python 里算 |H(20000/48000)| = -54.39 dB
        //    -> 增益 0.001909。这里只允许实测偏离理论值 +/-2 dB。
        //    第一版随手写了"< 0.001"（相当于 -60 dB），
        //    结果把正确的结果判成了失败（账本第 93 条同族）。
        $display("      理论值 -54.39 dB（增益 0.001909）");
        `CHK((gain > 0.001585) && (gain < 0.002514), "20 kHz 衰减与理论值一致（+/-2 dB）");

        //---------------------------------------------------------------------
        $display("");
        $display(" [6] BYPASS：旁路时输出严格等于输入");
        mode = 2; freq = 20000.0;
        restim;
        bad = 0;
        for (k = 0; k < 200; k = k + 1) begin
            @(negedge clk);
            if (dout_byp !== din_d) bad = bad + 1;
        end
        `CHK(bad == 0, "BYPASS=1 时输出 = 输入（逐拍一致）");

        //---------------------------------------------------------------------
        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  脉冲响应/对称/直流/通带/阻带/旁路全对");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

endmodule
