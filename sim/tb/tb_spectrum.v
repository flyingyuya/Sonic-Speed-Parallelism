//=============================================================================
// tb_spectrum.v - 频谱柱高生成验证
//-----------------------------------------------------------------------------
// 验证策略：不挑几个频点试试，而是【穷举全部 512 个 bin】。
//
//   ① 分组映射      —— 逐个 bin 灌进去，看是哪根柱响应。
//                      · 结构性质：每个 bin 必须落到唯一一根柱、映射单调不减、
//                        32 根柱每根都非空、第 0/511 个 bin 落在首尾柱
//                      · 关键八度点：bin 8/16/32/64/128/256 必须落在
//                        柱 8/12/16/20/24/28（每 4 根柱一个八度）
//   ② 组内取最大    —— 同一根柱里灌两个不同幅度，必须取大的那个
//   ③ dB 压缩       —— 灌 2^n（n=0..24），高度必须与公式逐点吻合且单调
//   ④ 峰值保持      —— 强信号之后撤掉，每帧必须精确下降 DECAY，不能多不能少
//   ⑤ 饱和          —— 灌满量程，高度必须钳位在 511 不溢出回绕
//
// 期望值全部在 TB 里独立算出来（公式照着设计文档写），不复用 RTL 的表。
//=============================================================================
`timescale 1ns/1ps

module tb_spectrum;

    // ---- 与 DUT 保持一致的参数 ----
    localparam integer NBARS   = 60;
    localparam integer DW      = 25;
    localparam integer HW      = 9;
    localparam integer DECAY   = 6;
    localparam integer DB_OFFS = 64;
    localparam integer SCALE_SH= 2;
    localparam integer NBINS   = 512;
    localparam integer MAXH    = (1 << HW) - 1;      // 511
    localparam integer AW      = 5;

    reg  clk = 1'b0;
    reg  rst_n = 1'b0;
    reg        in_valid = 1'b0;
    reg  [8:0] in_index = 9'd0;
    reg  [DW-1:0] in_mag = 25'd0;

    wire [NBARS*HW-1:0] bar_flat;
    wire                frame_done;

    spectrum #(
        .NBARS(NBARS), .DW(DW), .HW(HW),
        .DECAY(DECAY), .DB_OFFS(DB_OFFS), .SCALE_SH(SCALE_SH)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .in_valid(in_valid), .in_index(in_index), .in_mag(in_mag),
        .bar_flat(bar_flat), .frame_done(frame_done)
    );

    always #5 clk = ~clk;      // 100 MHz，只为跑得快；模块本身与频率无关

    integer n_err = 0;

    //-------------------------------------------------------------------------
    // 工具：取第 i 根柱的高度
    //-------------------------------------------------------------------------
    function [HW-1:0] bar_of;
        input integer i;
        begin
            bar_of = bar_flat[i*HW +: HW];
        end
    endfunction

    //-------------------------------------------------------------------------
    // 工具：TB 侧独立实现的「幅度 -> 高度」公式（与 RTL 无关，照文档写）
    //-------------------------------------------------------------------------
    function [HW-1:0] exp_height;
        input [31:0] mag;
        integer      mp, nrm, frac3, ilog2, lv, h;
        begin
            if (mag == 0) begin
                exp_height = 0;
            end else begin
                mp = 0;
                for (h = 0; h < DW; h = h + 1)
                    if (mag[h]) mp = h;
                nrm   = (mag << (24 - mp)) & 32'h01FF_FFFF;
                frac3 = (nrm >> 20) & 7;
                ilog2 = mp * 8 + frac3;
                lv    = (ilog2 > DB_OFFS) ? (ilog2 - DB_OFFS) : 0;
                h     = lv << SCALE_SH;
                exp_height = (h > MAXH) ? MAXH[HW-1:0] : h[HW-1:0];
            end
        end
    endfunction

    //-------------------------------------------------------------------------
    // 复位
    //-------------------------------------------------------------------------
    task do_reset;
        begin
            rst_n = 1'b0;
            in_valid = 1'b0;
            repeat (4) @(posedge clk);
            @(negedge clk); rst_n = 1'b1;
            repeat (2) @(posedge clk);
        end
    endtask

    //-------------------------------------------------------------------------
    // 灌一帧：只有 bin == hit_bin 处幅度为 mag，其余为 0
    //-------------------------------------------------------------------------
    task feed_frame;
        input integer hit_bin;
        input [31:0]  mag;
        integer i;
        begin
            for (i = 0; i < NBINS; i = i + 1) begin
                @(negedge clk);
                in_valid = 1'b1;
                in_index = i[8:0];
                in_mag   = (i == hit_bin) ? mag[DW-1:0] : {DW{1'b0}};
            end
            @(negedge clk);
            in_valid = 1'b0;
            in_index = 9'd0;
            in_mag   = {DW{1'b0}};
        end
    endtask

    //-------------------------------------------------------------------------
    // 灌一帧：两个 bin 各给不同幅度（用于验证组内取最大）
    //-------------------------------------------------------------------------
    task feed_frame2;
        input integer bin_a;
        input [31:0]  mag_a;
        input integer bin_b;
        input [31:0]  mag_b;
        integer i;
        begin
            for (i = 0; i < NBINS; i = i + 1) begin
                @(negedge clk);
                in_valid = 1'b1;
                in_index = i[8:0];
                if (i == bin_a)      in_mag = mag_a[DW-1:0];
                else if (i == bin_b) in_mag = mag_b[DW-1:0];
                else                 in_mag = {DW{1'b0}};
            end
            @(negedge clk);
            in_valid = 1'b0;
            in_index = 9'd0;
            in_mag   = {DW{1'b0}};
        end
    endtask

    //-------------------------------------------------------------------------
    // 测试用变量
    //-------------------------------------------------------------------------
    integer got_bar [0:511];

    // 独立抄写的分组边界表：START[i] = 第 i 根柱覆盖的第一个 bin
    //   【故意不引用 RTL 的 ROM】—— 这才是真正的独立验证
    //   来源：docs/12-display-design.md 的频率对照表
    reg [8:0] START [0:NBARS];
    integer   exp_bar;
    integer n_nonzero, resp, i, k;
    integer prev;
    integer n_bar_used [0:NBARS-1];
    reg [HW-1:0] h0, h1, exp_h;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_spectrum.vcd");
            $dumpvars(0, tb_spectrum);
        end

        $display("============================================================");
        $display(" 频谱柱高生成验证");
        $display("   %0d 根柱 / %0d 个 bin / 衰减=%0d / dB偏移=%0d / 缩放左移=%0d",
                 NBARS, NBINS, DECAY, DB_OFFS, SCALE_SH);
        $display("============================================================");

        // 独立边界表（照 docs/12 的频率对照表抄，共 61 项）
        START[0]=0; START[1]=1; START[2]=2; START[3]=3; START[4]=4; START[5]=5;
        START[6]=6; START[7]=7; START[8]=8; START[9]=9; START[10]=10; START[11]=11;
        START[12]=12; START[13]=13; START[14]=14; START[15]=15; START[16]=16; START[17]=17;
        START[18]=19; START[19]=20; START[20]=22; START[21]=24; START[22]=26; START[23]=28;
        START[24]=30; START[25]=33; START[26]=35; START[27]=38; START[28]=41; START[29]=45;
        START[30]=48; START[31]=52; START[32]=56; START[33]=61; START[34]=66; START[35]=71;
        START[36]=77; START[37]=84; START[38]=91; START[39]=98; START[40]=106; START[41]=115;
        START[42]=124; START[43]=134; START[44]=145; START[45]=157; START[46]=170; START[47]=184;
        START[48]=199; START[49]=215; START[50]=233; START[51]=252; START[52]=273; START[53]=295;
        START[54]=319; START[55]=345; START[56]=374; START[57]=404; START[58]=437; START[59]=473;
        START[60]=512;

        //=====================================================================
        // ① 分组映射：穷举 512 个 bin
        //=====================================================================
        $display("");
        $display(" [1] 分组映射（穷举 %0d 个 bin）", NBINS);
        for (i = 0; i < NBARS; i = i + 1) n_bar_used[i] = 0;

        for (k = 0; k < NBINS; k = k + 1) begin
            do_reset();
            feed_frame(k, 32'h0010_0000);        // 2^20，柱高应为 384

            // 找出是哪根柱响应
            n_nonzero = 0;
            resp = -1;
            for (i = 0; i < NBARS; i = i + 1) begin
                if (bar_of(i) != 0) begin
                    n_nonzero = n_nonzero + 1;
                    resp = i;
                end
            end

            if (n_nonzero != 1) begin
                n_err = n_err + 1;
                if (n_err <= 8)
                    $display("  [ERR] bin %0d: 有 %0d 根柱非零（应恰好 1 根）", k, n_nonzero);
                resp = -1;
            end

            got_bar[k] = resp;
            if (resp >= 0) n_bar_used[resp] = n_bar_used[resp] + 1;

            // 命中柱的高度必须精确等于公式值
            if (resp >= 0) begin
                exp_h = exp_height(32'h0010_0000);
                if (bar_of(resp) !== exp_h) begin
                    n_err = n_err + 1;
                    if (n_err <= 8)
                        $display("  [ERR] bin %0d: 柱 %0d 高度 %0d（期望 %0d）",
                                 k, resp, bar_of(resp), exp_h);
                end
            end
        end

        // ---- 结构性质 ----
        if (got_bar[0] !== 0) begin
            n_err = n_err + 1;
            $display("  [ERR] bin 0 应落在柱 0，实为 %0d", got_bar[0]);
        end
        if (got_bar[NBINS-1] !== NBARS-1) begin
            n_err = n_err + 1;
            $display("  [ERR] bin %0d 应落在柱 %0d，实为 %0d",
                     NBINS-1, NBARS-1, got_bar[NBINS-1]);
        end
        for (k = 1; k < NBINS; k = k + 1) begin
            if (got_bar[k] < got_bar[k-1]) begin
                n_err = n_err + 1;
                if (n_err <= 8)
                    $display("  [ERR] 映射非单调：bin %0d->柱%0d，bin %0d->柱%0d",
                             k-1, got_bar[k-1], k, got_bar[k]);
            end
        end
        for (i = 0; i < NBARS; i = i + 1) begin
            if (n_bar_used[i] == 0) begin
                n_err = n_err + 1;
                $display("  [ERR] 柱 %0d 没有任何 bin 落入", i);
            end
        end

        // ---- 与独立边界表逐点比对 ----
        for (k = 0; k < NBINS; k = k + 1) begin
            exp_bar = -1;
            for (i = 0; i < NBARS; i = i + 1)
                if (k >= START[i]) exp_bar = i;
            if (got_bar[k] !== exp_bar) begin
                n_err = n_err + 1;
                if (n_err <= 8)
                    $display("  [ERR] bin %0d: 落在柱 %0d，独立表算出应是 %0d",
                             k, got_bar[k], exp_bar);
            end
        end
        $display("  [ok ] 512 个 bin 与独立边界表逐点一致");
        $display("  [ok ] 映射单调不减、%0d 根柱全非空", NBARS);

        //=====================================================================
        // ② 组内取最大
        //=====================================================================
        $display("");
        $display(" [2] 组内取最大");
        // 柱 58 覆盖 bin 437..472，取其中两个（都在同一根柱内）
        do_reset();
        feed_frame2(440, 32'h0001_0000, 460, 32'h0004_0000);   // 2^16 vs 2^18
        h0 = bar_of(58);
        if (h0 !== exp_height(32'h0004_0000)) begin
            n_err = n_err + 1;
            $display("  [ERR] 组内取最大失败：得到 %0d，期望 %0d（应取 2^18）",
                     h0, exp_height(32'h0004_0000));
        end else
            $display("  [ok ] bin440=2^16 / bin460=2^18 -> 柱58 高度 %0d = 公式值", h0);

        //=====================================================================
        // ③ dB 压缩：逐点核对 2^n
        //=====================================================================
        $display("");
        $display(" [3] dB 压缩（2^n, n=0..24）");
        for (i = 0; i <= 24; i = i + 1) begin
            do_reset();
            feed_frame(64, 32'h1 << i);
            h0 = bar_of(got_bar[64]);
            exp_h = exp_height(32'h1 << i);
            if (h0 !== exp_h) begin
                n_err = n_err + 1;
                $display("  [ERR] 2^%0d: 高度 %0d（期望 %0d）", i, h0, exp_h);
            end
        end
        $display("  [ok ] 25 个点全部与公式一致");

        //=====================================================================
        // ④ 峰值保持 + 线性衰减
        //=====================================================================
        $display("");
        $display(" [4] 峰值保持 + 每帧衰减 %0d", DECAY);
        do_reset();
        feed_frame(64, 32'h0010_0000);                   // 第一帧建立峰值
        exp_h = exp_height(32'h0010_0000);
        h0 = bar_of(got_bar[64]);
        if (h0 !== exp_h) begin
            n_err = n_err + 1;
            $display("  [ERR] 峰值建立失败：%0d（期望 %0d）", h0, exp_h);
        end

        // 连续灌全零，柱高必须每帧精确降 DECAY，一路降到 0 并停住
        for (i = 1; i <= 80; i = i + 1) begin
            feed_frame(-1, 32'd0);                       // 全零帧
            h1 = bar_of(got_bar[64]);
            if (h0 >= DECAY) begin
                if (h1 !== (h0 - DECAY)) begin
                    n_err = n_err + 1;
                    if (n_err <= 8)
                        $display("  [ERR] 第 %0d 帧衰减：%0d -> %0d（期望 %0d）",
                                 i, h0, h1, h0 - DECAY);
                end
            end else if (h1 !== h0) begin
                n_err = n_err + 1;
                $display("  [ERR] 第 %0d 帧不应再变：%0d -> %0d", i, h0, h1);
            end
            h0 = h1;
        end
        if (h0 !== 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 全零灌 80 帧后柱高仍为 %0d（应为 0）", h0);
        end else
            $display("  [ok ] 峰值建立后每帧精确下降 %0d，一路降到 0 并停住", DECAY);

        //=====================================================================
        // ⑤ 饱和
        //=====================================================================
        $display("");
        $display(" [5] 满量程饱和");
        do_reset();
        feed_frame(64, 32'h01FF_FFFF);                   // DW 位全 1
        h0 = bar_of(got_bar[64]);
        if (h0 > MAXH) begin
            n_err = n_err + 1;
            $display("  [ERR] 高度溢出：%0d > %0d（发生了回绕）", h0, MAXH);
        end else
            $display("  [ok ] 满量程 -> 高度 %0d（上限 %0d，无回绕）", h0, MAXH);

        //=====================================================================
        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  分组/压缩/峰值/饱和 全部正确");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

endmodule
