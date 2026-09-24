//=============================================================================
// tb_i2s_loopback.v - I2S 收发闭环验证
//-----------------------------------------------------------------------------
// 用一个行为级"codec 模型"同时扮演 ADC 和 DAC：
//   ADC 侧：按 I2S 时序把已知样本串行推到 sdin
//   DAC 侧：按 I2S 时序从 sdout 采样并拼回 32bit 槽
//
// 两条独立校验路径：
//   (1) 接收校验：i2s_rx 解出的样本 == ADC 当帧发出的样本
//   (2) 发送校验：DAC 从 sdout 解出的样本 == 喂给 i2s_tx 的样本
//
// 这同时覆盖了：BCLK/LRCLK 分频比、LRCLK 与 MSB 的对齐关系（Philips I2S）、
//               收发两侧位下标一致性、24bit 数据在 32bit 槽内的高位对齐。
//=============================================================================
`timescale 1ns/1ps

module tb_i2s_loopback;

    localparam integer DW    = 24;
    localparam integer SLOT  = 32;
    localparam integer DIV   = 2;
    localparam integer NFRAME = 2 * SLOT;
    localparam integer NSAMP = 64;

    reg clk = 1'b0;
    always #5 clk = ~clk;               // 100 MHz

    reg rst_n = 1'b0;

    wire bclk, lrclk, sdin_w, sdout_w;
    wire bclk_rise, bclk_fall, frame_start, half_start, sample_stb;
    wire [5:0] bit_idx;

    i2s_clkgen #(.DIV(DIV), .SLOT(SLOT)) u_clkgen (
        .clk(clk), .rst_n(rst_n),
        .bclk(bclk), .lrclk(lrclk),
        .bclk_rise(bclk_rise), .bclk_fall(bclk_fall),
        .frame_start(frame_start), .half_start(half_start),
        .bit_idx(bit_idx), .sample_stb(sample_stb)
    );

    wire signed [DW-1:0] rx_l, rx_r;
    wire                 rx_valid;

    i2s_rx #(.SLOT(SLOT), .DATA_BITS(DW), .DW(DW)) u_rx (
        .clk(clk), .rst_n(rst_n),
        .bclk_rise(bclk_rise), .bclk_fall(bclk_fall), .bit_idx(bit_idx),
        .sdin(sdin_w),
        .l_data(rx_l), .r_data(rx_r), .sample_valid(rx_valid)
    );

    //-------------------------------------------------------------------------
    // 行为级 codec 模型
    //-------------------------------------------------------------------------
    reg [SLOT-1:0]   adc_l, adc_r;
    reg [2*SLOT-1:0] adc_sr;
    reg              sdin_r;
    assign sdin_w = sdin_r;

    wire [5:0] idx_nxt = frame_start ? 6'd0 : (bit_idx + 6'd1);
    wire [2*SLOT-1:0] adc_frame = {adc_l, adc_r};
    wire [2*SLOT-1:0] adc_sr_nxt = frame_start ? adc_frame : adc_sr;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adc_sr <= {2*SLOT{1'b0}};
            sdin_r <= 1'b0;
        end else if (bclk_fall) begin
            adc_sr <= adc_sr_nxt;
            sdin_r <= adc_sr_nxt[2*SLOT-1 - idx_nxt];
        end
    end

    // DAC 侧：在 BCLK 上升沿采样
    reg [2*SLOT-1:0]  dac_sr;
    wire [2*SLOT-1:0] dac_nxt = {dac_sr[2*SLOT-2:0], sdout_w};

    reg signed [DW-1:0] cap_l, cap_r;
    reg                 cap_valid;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dac_sr    <= {2*SLOT{1'b0}};
            cap_l     <= {DW{1'b0}};
            cap_r     <= {DW{1'b0}};
            cap_valid <= 1'b0;
        end else begin
            cap_valid <= 1'b0;
            if (bclk_rise) begin
                dac_sr <= dac_nxt;
                if (bit_idx == NFRAME-1) begin
                    cap_l     <= dac_nxt[2*SLOT-1 -: DW];
                    cap_r     <= dac_nxt[SLOT-1   -: DW];
                    cap_valid <= 1'b1;
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // 发送端激励（由 TB 直接喂给 i2s_tx，与 ADC 数据同源）
    //-------------------------------------------------------------------------
    reg signed [DW-1:0] tx_l, tx_r;

    i2s_tx #(.SLOT(SLOT), .DATA_BITS(DW), .DW(DW)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .bclk_fall(bclk_fall), .frame_start(frame_start), .bit_idx(bit_idx),
        .l_data(tx_l), .r_data(tx_r), .data_en(1'b1),
        .sdout(sdout_w)
    );

    //-------------------------------------------------------------------------
    // 测试图案
    //-------------------------------------------------------------------------
    function [DW-1:0] pat_l;
        input integer n;
        integer v;
        begin
            v = ((n * 7919) % 65536) - 32768;
            pat_l = v[DW-1:0] <<< 8;
        end
    endfunction

    function [DW-1:0] pat_r;
        input integer n;
        integer v;
        begin
            v = ((n * 104729) % 65536) - 32768;
            pat_r = v[DW-1:0] <<< 8;
        end
    endfunction

    //-------------------------------------------------------------------------
    // 数据准备 + 校验（同一个 always 块，顺序明确）
    //-------------------------------------------------------------------------
    integer fidx     = 0;
    integer n_chk    = 0;
    integer err_rx   = 0;
    integer err_tx   = 0;

    reg signed [DW-1:0] exp_l, exp_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fidx    <= 0;
            n_chk   <= 0;
            err_rx  <= 0;
            err_tx  <= 0;
            adc_l   <= {SLOT{1'b0}};
            adc_r   <= {SLOT{1'b0}};
            tx_l    <= {DW{1'b0}};
            tx_r    <= {DW{1'b0}};
            exp_l   <= {DW{1'b0}};
            exp_r   <= {DW{1'b0}};
        end else begin
            // 右声道起点准备下一帧数据：ADC 与 TX 用同一组图案
            if (half_start) begin
                fidx  <= fidx + 1;
                adc_l <= {pat_l(fidx + 1), {(SLOT-DW){1'b0}}};   // 数据高位对齐到槽
                adc_r <= {pat_r(fidx + 1), {(SLOT-DW){1'b0}}};
                tx_l  <= pat_l(fidx + 1);
                tx_r  <= pat_r(fidx + 1);
            end

            // 整帧起点：确定本帧实际发送的样本，作为本帧的预期值
            // （必须在 frame_start 锁存，不能在 half_start 锁存：
            //   下一帧的 half_start 早于本帧的帧尾捕获，会导致预期值提前一拍）
            if (frame_start) begin
                exp_l <= adc_l[SLOT-1 -: DW];
                exp_r <= adc_r[SLOT-1 -: DW];
            end

            // 整帧结束时校验
            if (cap_valid) begin
                n_chk <= n_chk + 1;
                if (n_chk >= 2) begin
                    if (cap_l !== exp_l || cap_r !== exp_r) begin
                        err_tx <= err_tx + 1;
                        if (err_tx < 5)
                            $display("  [发送错] 帧%0d L: 收=%0d 期=%0d | R: 收=%0d 期=%0d",
                                     n_chk, $signed(cap_l), $signed(exp_l),
                                     $signed(cap_r), $signed(exp_r));
                    end
                    if (rx_l !== exp_l || rx_r !== exp_r) begin
                        err_rx <= err_rx + 1;
                        if (err_rx < 5)
                            $display("  [接收错] 帧%0d L: 收=%0d 期=%0d | R: 收=%0d 期=%0d",
                                     n_chk, $signed(rx_l), $signed(exp_l),
                                     $signed(rx_r), $signed(exp_r));
                    end
                end
            end
        end
    end

    //-------------------------------------------------------------------------
    // LRCLK 周期测量：两次整帧起点之间的 BCLK 上升沿数必须是 2*SLOT
    //-------------------------------------------------------------------------
    integer bclk_rise_cnt  = 0;
    integer last_period    = 0;
    integer period_ok      = 0;
    integer period_bad     = 0;
    reg     seen_first     = 1'b0;

    always @(posedge clk) begin
        if (!rst_n) begin
            bclk_rise_cnt <= 0;
            seen_first    <= 1'b0;
        end else begin
            if (bclk_rise) bclk_rise_cnt <= bclk_rise_cnt + 1;
            if (frame_start) begin
                if (seen_first) begin
                    last_period <= bclk_rise_cnt;
                    if (bclk_rise_cnt == NFRAME) period_ok <= period_ok + 1;
                    else                         period_bad <= period_bad + 1;
                end
                seen_first    <= 1'b1;
                bclk_rise_cnt <= 0;
            end
        end
    end

    initial begin
        if (!$test$plusargs("novcd")) begin
            $dumpfile("sim/build/tb_i2s_loopback.vcd");
            $dumpvars(1, tb_i2s_loopback);
        end

        $display("=========================================================");
        $display(" I2S 收发闭环验证  SLOT=%0d  DIV=%0d", SLOT, DIV);
        $display(" 目标：BCLK = clk/%0d，LRCLK = clk/%0d",
                 2*DIV, 2*DIV*2*SLOT);
        $display("=========================================================");

        repeat (4) @(posedge clk);
        rst_n <= 1'b1;

        wait (n_chk >= NSAMP);
        repeat (4) @(posedge clk);

        $display("---------------------------------------------------------");
        $display(" 校验帧数     : %0d", n_chk - 2);
        $display(" 每帧 BCLK 数 : %0d (期望 %0d)  合格 %0d 帧 / 不合格 %0d 帧",
                 last_period, NFRAME, period_ok, period_bad);
        $display(" 接收错误数   : %0d", err_rx);
        $display(" 发送错误数   : %0d", err_tx);
        if (err_rx == 0 && err_tx == 0 && period_bad == 0)
            $display(" 结果         : *** PASS ***  I2S 收发双向一致");
        else
            $display(" 结果         : *** FAIL ***");
        $display("---------------------------------------------------------");
        $finish;
    end

    initial begin
        #5000000;
        $display("  [超时] n_chk=%0d fidx=%0d bit_idx=%0d", n_chk, fidx, bit_idx);
        $finish;
    end

endmodule
