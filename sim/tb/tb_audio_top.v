//=============================================================================
// tb_audio_top.v - 音频链路顶层端到端验证
//-----------------------------------------------------------------------------
// 被测路径：codec(ADC) -> i2s_rx -> fifo -> eq_cascade x2 -> fifo -> i2s_tx -> codec(DAC)
//
// 测试方法（冲激响应比对）：
//   1. 通过 band_gain 端口写入演示用增益配置 [ +6, -3, 0, +4, -6 ] dB
//      -> 触发系数装载 FSM 从 eq_coeff_rom 取 25 个系数写进两个声道
//   2. 先送若干静音，再送一个半量程冲激，其后全零
//   3. 从 codec 模型收到的样本流里找出第一个非零样本作为 IR 起点
//   4. 与 Python 定点黄金模型算出的冲激响应逐位比对
//
// 左声道送 +冲激，右声道送 -冲激：这样只要左右声道接反就会被立刻发现。
//=============================================================================
`timescale 1ns/1ps

module tb_audio_top;

    localparam integer DW    = 24;
    localparam integer SLOT  = 32;
    localparam integer DIV   = 2;
    localparam integer NIR   = 256;      // 冲激响应长度
    localparam integer NSEND = 8 + 1 + 700;

    // 演示用增益档位打包：band0=+6dB(16), band1=-3dB(7), band2=0dB(10),
    //                      band3=+4dB(14), band4=-6dB(4)   每档 5bit
    localparam [24:0] GAIN_PACK = 25'd4663536;

    reg clk = 1'b0;
    always #5 clk = ~clk;                // 100 MHz（真实是 12.288MHz，时序等价）

    reg rst_n = 1'b0;

    wire bclk, lrclk, sdin_w, sdout_w;
    wire bclk_rise, bclk_fall, frame_start, half_start, sample_stb;
    wire [5:0] bit_idx;

    reg  [24:0] band_gain = 25'd0;
    reg         cfg_load  = 1'b0;
    wire        cfg_busy, running;

    audio_top #(
        .DW(DW), .CW(18), .CF(16), .AW(48), .NSECT(5),
        .SLOT(SLOT), .DIV(DIV)
    ) dut (
        .clk(clk), .rst_n(rst_n),
        .bclk(bclk), .lrclk(lrclk), .sdin(sdin_w), .sdout(sdout_w),
        .band_gain(band_gain), .cfg_load(cfg_load), .bypass(1'b0),
        .cfg_busy(cfg_busy), .running(running),
        .dbg_bclk_rise(bclk_rise), .dbg_bclk_fall(bclk_fall),
        .dbg_frame_start(frame_start), .dbg_half_start(half_start),
        .dbg_bit_idx(bit_idx), .dbg_sample_stb(sample_stb)
    );

    //-------------------------------------------------------------------------
    // codec 行为模型
    //-------------------------------------------------------------------------
    reg signed [DW-1:0] adc_l = 0, adc_r = 0;
    wire signed [DW-1:0] cap_l, cap_r;
    wire                 cap_valid;

    codec_model #(.DW(DW), .SLOT(SLOT)) u_codec (
        .clk(clk), .rst_n(rst_n),
        .bclk_rise(bclk_rise), .bclk_fall(bclk_fall),
        .frame_start(frame_start), .bit_idx(bit_idx),
        .adc_l(adc_l), .adc_r(adc_r), .sdin(sdin_w),
        .sdout(sdout_w), .cap_l(cap_l), .cap_r(cap_r), .cap_valid(cap_valid)
    );

    //-------------------------------------------------------------------------
    // 参考冲激响应
    //-------------------------------------------------------------------------
    reg signed [DW-1:0] ir_ref [0:NIR-1];
    reg signed [DW-1:0] cap_buf   [0:NSEND-1];   // 左声道
    reg signed [DW-1:0] cap_buf_r [0:NSEND-1];   // 右声道

    integer n_cap = 0;
    integer n_sent = 0;
    integer sent_idx = 0;                // 激励样本序号

    //-------------------------------------------------------------------------
    // 激励生成：在右声道起点准备好下一帧要发送的 ADC 数据
    //（必须比 frame_start 早半帧，否则 codec 装载到的还是上一帧的值）
    //-------------------------------------------------------------------------
    localparam signed [DW-1:0] IMP = 24'sd4194304;   // 半量程

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adc_l   <= {DW{1'b0}};
            adc_r   <= {DW{1'b0}};
            n_sent  <= 0;
            sent_idx<= 0;
        end else if (half_start && running && n_sent < NSEND) begin
            // 第 8 个样本是冲激，其余为静音
            if (sent_idx == 8) begin
                adc_l <=  IMP;
                adc_r <= -IMP;
            end else begin
                adc_l <= {DW{1'b0}};
                adc_r <= {DW{1'b0}};
            end
            n_sent   <= n_sent + 1;
            sent_idx <= sent_idx + 1;
        end
    end

    //-------------------------------------------------------------------------
    // 采集
    //-------------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst_n && cap_valid && n_cap < NSEND) begin
            cap_buf[n_cap]   = cap_l;
            cap_buf_r[n_cap] = cap_r;
            n_cap = n_cap + 1;
        end
    end

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    integer i, k, i0, first_bad;
    integer err_l = 0, err_r = 0;
    integer i0_r;
    integer fd;

    // 右声道单独找起点（用 cap_r 需要另存，这里复用同一流水延迟：
    // 左右声道共享同一 FIFO/EQ 时序，起点必然相同，故直接用 i0）
    initial begin
        if (!$test$plusargs("novcd")) begin
            $dumpfile("sim/build/tb_audio_top.vcd");
            $dumpvars(1, tb_audio_top);
        end

        $readmemh("sim/vectors/ir_ref.hex", ir_ref);
        for (i = 0; i < NSEND; i = i + 1) begin
            cap_buf[i]   = {DW{1'b0}};
            cap_buf_r[i] = {DW{1'b0}};
        end

        $display("=========================================================");
        $display(" audio_top 端到端验证（I2S -> FIFO -> EQ x2 -> FIFO -> I2S）");
        $display(" 输入：静音 x8 + 半量程冲激 + 静音");
        $display(" 预期：RTL 输出冲激响应 == Python 定点黄金模型");
        $display("=========================================================");

        // 复位
        repeat (8) @(posedge clk);
        rst_n <= 1'b1;
        repeat (4) @(posedge clk);

        // 写入增益配置，触发系数装载
        band_gain <= GAIN_PACK;
        @(posedge clk);
        cfg_load  <= 1'b1;
        @(posedge clk);
        cfg_load  <= 1'b0;

        // 等待系数装载完成
        // 注意：必须先等 cfg_busy 起来再等它落下。
        // 如果直接 wait(running)，会在 cfg_load 的同一拍就返回
        // （那一拍 dirty 还没置位，running 仍为 1），导致后续样本
        // 落在系数尚未写完的窗口里 —— 实测会让 band0 用上复位默认系数。
        wait (cfg_busy);
        wait (running);
        $display(" 系数装载完成，cfg_busy=%0b running=%0b", cfg_busy, running);

        // 诊断：导出 RTL 实际装载的 25 个系数
        if ($test$plusargs("dumpcoef")) begin
            $display(" gain_reg=%0d (期望 %0d)  st=%0d ld_cnt=%0d",
                     dut.gain_reg, GAIN_PACK, dut.st, dut.ld_cnt);
            for (i = 0; i < 5; i = i + 1)
                $display("   gain_reg[band%0d] = %0d", i, dut.gain_reg[i*5 +: 5]);
            $display(" RTL 装载的系数（左声道）:");
            for (i = 0; i < 25; i = i + 1)
                $display("   sec%0d k%0d = %0d", i/5, i%5,
                         $signed(dut.u_eq_l.coe[i]));
        end

        // 送完全部激励并收集输出
        wait (n_sent >= NSEND);
        repeat (4000) @(posedge clk);      // 等流水线排空

        // 找第一个非零输出（= 冲激响应起点）
        i0 = -1;
        for (i = 0; i < n_cap; i = i + 1) begin
            if (cap_buf[i] != 0) begin
                i0 = i;
                i = n_cap;
            end
        end

        if (i0 < 0) begin
            $display("  [失败] 输出全为零，EQ 通路未工作");
            $display(" 结果       : *** FAIL ***");
            $finish;
        end

        // 逐位比对
        first_bad = -1;
        for (k = 0; k < NIR; k = k + 1) begin
            if (cap_buf[i0 + k] !== ir_ref[k]) begin
                err_l = err_l + 1;
                if (first_bad < 0) begin
                    first_bad = k;
                    $display("  [左声道错] k=%0d  RTL=%0d  黄金=%0d",
                             k, $signed(cap_buf[i0+k]), $signed(ir_ref[k]));
                end
            end
            if (cap_buf_r[i0 + k] !== -ir_ref[k]) begin
                err_r = err_r + 1;
                if (err_r == 1)
                    $display("  [右声道错] k=%0d  RTL=%0d  黄金=%0d",
                             k, $signed(cap_buf_r[i0+k]), $signed(-ir_ref[k]));
            end
        end

        // 导出全部采集样本，便于离线分析
        fd = $fopen("sim/build/audio_top_cap.hex", "w");
        for (i = 0; i < n_cap; i = i + 1)
            $fdisplay(fd, "%06x %06x", cap_buf[i], cap_buf_r[i]);
        $fclose(fd);

        $display("---------------------------------------------------------");
        $display(" 采集样本数     : %0d", n_cap);
        $display(" 冲激响应起点   : 第 %0d 个输出样本", i0);
        $display(" 端到端延迟     : %0d 帧 (%0d clk)", i0 - 8, (i0 - 8) * 2 * DIV * 2 * SLOT);
        $display(" 左声道 不符点  : %0d / %0d", err_l, NIR);
        $display(" 右声道 不符点  : %0d / %0d", err_r, NIR);
        if (err_l == 0 && err_r == 0)
            $display(" 结果           : *** PASS ***  端到端与黄金模型逐位一致");
        else
            $display(" 结果           : *** FAIL ***");
        $display("---------------------------------------------------------");
        $finish;
    end

    initial begin
        #20000000;
        $display("  [超时] n_sent=%0d n_cap=%0d running=%0b", n_sent, n_cap, running);
        $finish;
    end

endmodule
