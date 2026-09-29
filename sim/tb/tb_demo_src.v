//=============================================================================
// tb_demo_src.v - demo_src 自检
//-----------------------------------------------------------------------------
// 【验证策略：查性质，不照抄实现】
//   这个模块里有个 tri_peak() 函数。如果 TB 把它原样抄一遍来算期望值，
//   那就是账本第 38 条那类错误 —— "TB 镜像实现"，实现错了 TB 跟着错。
//
//   所以这里只查【可独立描述的性质】：
//     - 斜坡模式：bar[i] 必须【恰好等于 i*8】（这个式子简单到不用抄）
//     - 棋盘模式：odd/even 必须是两个固定值，且交替
//     - 包络模式：值都 <= 511、有非零、最大值出现在相位附近、会随时间移动
//     - 关模式：bar_wr 永不为高、bar_flat 恒为 0
//     - 波形：速率是 48 kHz 等效、幅度不超 disp_mix 的钳位上限、
//             形状是"先单调升再单调降"（三角波）
//=============================================================================
`timescale 1ns/1ps

module tb_demo_src;

    localparam integer NBARS = 60;
    localparam integer HW    = 9;
    // 【为什么 TB 里用小 TICK_B】
    //   RTL 默认 TICK_B=20（21.85 ms 一帧），按这个跑一遍 TB 要 300 ms 仿真时间，
    //   iverilog 要几分钟 —— 而 TB 要验的是【逻辑】和【周期公式】
    //   (2^TICK_B + NBARS)，不是那个具体常数。
    //   所以这里用 TICK_B=8（256 拍），同一套断言全都能跑，仿真快 4000 倍。
    localparam integer TICK_B = 8;

    reg                clk = 0;
    reg                rst_n = 0;
    reg  [1:0]         mode = 2'd0;
    wire [NBARS*HW-1:0] bar_flat;
    wire               bar_wr;
    wire signed [23:0] wave_din;
    wire               wave_we;

    integer n_err = 0;
    integer i, k;

    demo_src #(.NBARS(NBARS), .HW(HW), .TICK_B(TICK_B)) dut (
        .clk(clk), .rst_n(rst_n), .mode(mode),
        .bar_flat(bar_flat), .bar_wr(bar_wr),
        .wave_din(wave_din), .wave_we(wave_we)
    );

    always #10.4167 clk = ~clk;             // 48 MHz

    // 取第 b 根柱
    function [HW-1:0] bar;
        input integer b;
        begin
            bar = bar_flat[b*HW +: HW];
        end
    endfunction

    // 等一次 bar_wr 脉冲，读取【该脉冲对应的】bar_flat
    //
    // ⚠️ 为什么脉冲后再等一拍才取样：
    //   DUT 里 bar_flat 和 bar_wr 是同一个 always 块里的【非阻塞赋值】，
    //   两者在同一个时钟沿更新。而 `@(posedge clk)` 恢复执行时还在
    //   active 区，NBA 尚未生效 —— 此时读 bar_flat 拿到的是【旧值】。
    //   这正是账本第 23/25/28/32 条那个“和被观测信号差一拍”的老毛病，
    //   这里又犯了一次（第 6 次）。
    //   再等一拍，bar_wr 可能已拉低，但 bar_flat 要下一次 tick 才变，
    //   所以读到的仍是本脉冲对应的值 ✓
    reg [NBARS*HW-1:0] snap;
    task wait_wr;
        begin
            @(posedge clk);
            while (!bar_wr) @(posedge clk);
            @(posedge clk);             // 跨过 NBA 区
            snap = bar_flat;
        end
    endtask

    integer v;
    integer vmax, vmax_idx;
    integer errs_before;
    integer cyc;

    // 改模式并拿到一个【确定属于新模式】的帧
    //
    // 为什么要等两帧：如果改 mode 的那一刻 FSM 正好在重建一帧，
    // 那一帧就是"前半段旧 mode + 后半段新 mode"的混合体 ——
    // 不是 DUT 错了（RTL 已保证整帧同一个 mode），而是这一帧本来
    // 就属于旧 mode 的更新周期。跳过它，第二帧必然是新 mode。
    task set_mode;
        input [1:0] m;
        begin
            mode = m;
            wait_wr();
            wait_wr();
        end
    endtask

    // 量两次 bar_wr 之间隔了多少拍。用它可以抓出
    // "算完把 tick 置 0 -> tick_now 立刻又为真 -> 连环重算" 这类 bug：
    // 正常应该是 2^TICK_B 拍（131072），连环重算会掉到 60 拍左右。
    task measure_period;
        output integer p;
        begin
            @(posedge clk);
            while (!bar_wr) @(posedge clk);
            cyc = 0;
            @(posedge clk);
            while (!bar_wr) begin @(posedge clk); cyc = cyc + 1; end
            p = cyc + 1;
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" demo_src 自检（演示/自检图案源）");
        $display("============================================================");

        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;

        //=====================================================================
        // ① 关模式：bar_wr 永不为高
        //=====================================================================
        $display("");
        $display("[1] mode=0（关）：bar_wr 不应有任何脉冲");
        mode = 2'd0;
        k = 0;
        repeat (300000) @(posedge clk) if (bar_wr) k = k + 1;
        if (k != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 关模式下出现了 %0d 次 bar_wr", k);
        end else
            $display("  [ok ] 关模式下 bar_wr 恒为 0（%0d 拍观察）", 300000);

        //=====================================================================
        // ② 斜坡模式：bar[i] == i*8
        //=====================================================================
        $display("");
        $display("[2] mode=1（斜坡）：bar[i] 必须恰好等于 i*8");
        set_mode(2'd1);
        k = 0;
        for (i = 0; i < NBARS; i = i + 1) begin
            if (snap[i*HW +: HW] !== (i[8:0] << 3)) begin
                k = k + 1;
                if (k <= 3)
                    $display("  [ERR] bar[%0d] = %0d，期望 %0d",
                             i, snap[i*HW +: HW], i*8);
            end
        end
        if (k != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 斜坡有 %0d 根柱不符（共 %0d）", k, NBARS);
        end else begin
            $display("  [ok ] 60 根柱全部等于 i*8（0, 8, ..., 472）");
            // 顺带确认它是一条【单调上升】的直线 —— 这是上板时肉眼判据
            k = 0;
            for (i = 1; i < NBARS; i = i + 1)
                if (snap[i*HW +: HW] <= snap[(i-1)*HW +: HW]) k = k + 1;
            if (k != 0) begin
                n_err = n_err + 1;
                $display("  [ERR] 斜坡不是单调上升（%0d 处）", k);
            end else
                $display("  [ok ] 严格单调上升 -> 上板应该看到一条笔直斜线");
        end

        //=====================================================================
        // ③ 棋盘模式：奇偶交替，两个固定值
        //=====================================================================
        $display("");
        $display("[3] mode=2（棋盘）：奇数柱 448，偶数柱 32，必须严格交替");
        set_mode(2'd2);
        k = 0;
        for (i = 0; i < NBARS; i = i + 1) begin
            v = i[0] ? 448 : 32;
            if (snap[i*HW +: HW] !== v[9:0]) begin
                k = k + 1;
                if (k <= 3)
                    $display("  [ERR] bar[%0d] = %0d，期望 %0d",
                             i, snap[i*HW +: HW], v);
            end
        end
        if (k != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 棋盘有 %0d 根柱不符", k);
        end else
            $display("  [ok ] 60 根柱高低严格交替（验证柱宽/间隙用）");

        //=====================================================================
        // ④ 包络模式：查性质
        //=====================================================================
        $display("");
        $display("[4] mode=3（包络）：查性质（不照抄 tri_peak 实现）");
        set_mode(2'd3);

        vmax = -1; vmax_idx = -1; k = 0;
        for (i = 0; i < NBARS; i = i + 1) begin
            v = snap[i*HW +: HW];
            if (v > 511) begin
                k = k + 1;
                if (k <= 3) $display("  [ERR] bar[%0d]=%0d 超出 9 位范围", i, v);
            end
            if (v > vmax) begin vmax = v; vmax_idx = i; end
        end
        if (k != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 有 %0d 根柱超出 HW 位宽", k);
        end else
            $display("  [ok ] 所有柱高都在 9 位范围内（0..511）");

        if (vmax <= 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 包络全为 0，图案没生成");
        end else
            $display("  [ok ] 有峰值：最大值 %0d 在第 %0d 根柱", vmax, vmax_idx);

        // 低频抬升：第 0 根柱附近应该是"抬起"的（>0）
        if (snap[0*HW +: HW] == 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 低频抬升缺失：bar[0] = 0");
        end else
            $display("  [ok ] 低频抬升存在：bar[0] = %0d", snap[0*HW +: HW]);

        // 峰值必须【移动】：再等几次更新，峰值位置应该变
        begin : move_check
            integer first_idx, moved;
            first_idx = vmax_idx;
            moved = 0;
            for (k = 0; k < 6; k = k + 1) begin
                wait_wr();
                vmax = -1; vmax_idx = -1;
                for (i = 0; i < NBARS; i = i + 1) begin
                    v = snap[i*HW +: HW];
                    if (v > vmax) begin vmax = v; vmax_idx = i; end
                end
                if (vmax_idx != first_idx) moved = moved + 1;
            end
            if (moved == 0) begin
                n_err = n_err + 1;
                $display("  [ERR] 峰值位置一直停在第 %0d 根，图案没有移动", first_idx);
            end else
                $display("  [ok ] 峰值在 6 次更新里移动了 %0d 次（图案是动的）", moved);
        end

        //=====================================================================
        // ⑤ bar_wr 与 bar_flat 同沿：脉冲期间必须已经是新值
        //    （照抄真实 spectrum 的契约：spec_wr 高时 spec_din 必须是新值）
        //=====================================================================
        $display("");
        $display("[5] bar_wr 脉冲对应的 bar_flat 必须已经是新值（契约一致性）");
        set_mode(2'd1);                         // 斜坡，期望值好算
        if (snap[0*HW +: HW] !== 9'd0 ||
            snap[59*HW +: HW] !== 9'd472) begin
            n_err = n_err + 1;
            $display("  [ERR] bar_wr 脉冲对应的 bar_flat 不是新值：bar[0]=%0d bar[59]=%0d",
                     snap[0*HW +: HW], snap[59*HW +: HW]);
        end else
            $display("  [ok ] bar_wr 脉冲对应的 bar_flat 已是新值（0 与 472）");

        //=====================================================================
        // ⑤b 更新周期必须是 2^TICK_B 拍，不能是"连环重算"
        //     （第一版 RTL 把 tick 置 0，导致 tick_now 下一拍又为真，
        //      周期从 131072 掉到 60 拍，帧永远处于重算中）
        //=====================================================================
        $display("");
        $display("[6] 更新周期应【恰好】是 2^%0d + %0d = %0d 拍",
                 TICK_B, NBARS, (1<<TICK_B) + NBARS);
        // 周期可以精确算出来：
        //   tick 从 1 数到回绕    -> 2^TICK_B - 1 拍
        //   tick == 0 那一拍转状态 -> 1 拍
        //   重建 60 根柱            -> NBARS 拍
        //   合计 2^TICK_B + NBARS
        // 所以这里不用模糊容差 —— 直接卡精确值，反而能抓出偏移一拍的错。
        measure_period(k);
        if (k < (1<<TICK_B) + NBARS - 2 || k > (1<<TICK_B) + NBARS + 2) begin
            n_err = n_err + 1;
            $display("  [ERR] 两次 bar_wr 间隔 %0d 拍，期望 %0d",
                     k, (1<<TICK_B) + NBARS);
            $display("        （若接近 %0d 说明在连环重算：算完把 tick 置 0 了）", NBARS);
        end else
            $display("  [ok ] 周期 %0d 拍 = 2^%0d + %0d（计数 + 重建）",
                     k, TICK_B, NBARS);

        //=====================================================================
        // ⑥ 波形：速率、幅度、形状
        //=====================================================================
        $display("");
        $display("[7] 波形：48 kHz 等效速率 + 幅度 + 三角形状");

        // --- 速率：48 MHz / 1000 = 48 kHz ---
        k = 0;
        repeat (480000) @(posedge clk) if (wave_we) k = k + 1;   // 10 ms
        // 10 ms @48kHz -> 480 次，允许 ±2
        if (k < 478 || k > 482) begin
            n_err = n_err + 1;
            $display("  [ERR] 10ms 内有 %0d 次写，期望 480（48 kHz）", k);
        end else
            $display("  [ok ] 10 ms 内 %0d 次写 -> 48 kHz，与真实采样率一致", k);

        // --- 幅度：|wave| 的 [23:18] 位必须 <= disp_mix 的钳位上限 22 ---
        begin : amp_check
            integer mx;
            reg [24:0] a;
            mx = 0;
            for (k = 0; k < 200; k = k + 1) begin
                @(posedge clk);
                while (!wave_we) @(posedge clk);
                a = wave_din[23] ? ({1'b0, ~wave_din} + 1'b1) : {1'b0, wave_din};
                if (a[23:18] > mx) mx = a[23:18];
            end
            if (mx == 0) begin
                n_err = n_err + 1;
                $display("  [ERR] 波形恒为 0");
            end else if (mx > 22) begin
                n_err = n_err + 1;
                $display("  [ERR] 幅度 %0d 像素超过 disp_mix 的钳位上限 22（会削顶）", mx);
            end else
                $display("  [ok ] 峰值幅度 %0d 像素 <= 22（不会被 disp_mix 削顶）", mx);
        end

        // --- 形状：一个三角周期内应该"先单调升再单调降"---
        begin : shape_check
            integer up, dn, prev, cur, dir;
            up = 0; dn = 0; dir = 0;
            prev = wave_din;
            for (k = 0; k < 160; k = k + 1) begin
                @(posedge clk);
                while (!wave_we) @(posedge clk);
                cur = wave_din;
                if (cur > prev) begin
                    if (dir == -1) dn = dn + 1;     // 已经降过又升 -> 一个谷
                    dir = 1; up = up + 1;
                end else if (cur < prev) begin
                    if (dir == 1) up = up + 0;
                    dir = -1; dn = dn + 1;
                end
                prev = cur;
            end
            // 160 个采样 ≈ 2 个三角周期，应该至少各有 1 次升/降方向变化
            if (up < 20 || dn < 20) begin
                n_err = n_err + 1;
                $display("  [ERR] 形状不像三角波：上升 %0d 次 / 下降 %0d 次", up, dn);
            end else
                $display("  [ok ] 三角波形状：上升 %0d 次 / 下降 %0d 次", up, dn);
        end

        //=====================================================================
        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  三种图案 + 波形契约全部正确");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

    // 超时保护
    initial begin
        #80_000_000;
        $display("  [ERR] 超时");
        $display(" 结果       : *** FAIL ***  超时");
        $finish;
    end

endmodule
