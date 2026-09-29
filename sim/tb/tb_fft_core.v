//=============================================================================
// tb_fft_core.v - 1024 点 FFT 端到端验证
//-----------------------------------------------------------------------------
// 流程（对每组测试）：
//   1. 用 fft_in.hex 里的 N 个样本灌进 fft_core（每拍一个）
//   2. 等它走完 IDLE -> RUN -> OUT
//   3. 把 512 个输出的 (index, mag) 与 fft_mag.hex 逐位比对
//
// 同时检查：
//   · y_index 必须严格按 0,1,2,...,511 递增（验证输出顺序）
//   · drop_cnt 必须为 0（验证 FIFO 没有溢出）
//
// 向量由 scripts/golden/gen_fft_core_vec.py 生成，
// 黄金模型是 scripts/golden/fft_dsp.py 里的 fft_core_model()。
//=============================================================================
`timescale 1ns/1ps

module tb_fft_core;

    localparam integer DW    = 24;
    localparam integer LOG2N = 10;
    localparam integer N     = 1024;
    localparam integer HALF  = 512;
    localparam integer NTEST = 4;
    localparam integer TIMEOUT = 200000;

    reg clk = 1'b0;
    always #10 clk = ~clk;              // 50 MHz（频率不影响功能验证）

    reg  rst_n = 1'b0;

    reg  signed [DW-1:0] x_in    = {DW{1'b0}};
    reg                  x_valid = 1'b0;
    wire [LOG2N-2:0]     y_index;
    wire [DW:0]          y_mag;
    wire                 y_valid;
    wire                 busy;
    wire [7:0]           drop_cnt;

    fft_core #(.N(N), .LOG2N(LOG2N), .DW(DW), .TW(16), .FIFO_DEPTH(64)) u_dut (
        .clk(clk), .rst_n(rst_n),
        .x_in(x_in), .x_valid(x_valid),
        .y_index(y_index), .y_mag(y_mag), .y_valid(y_valid),
        .busy(busy), .drop_cnt(drop_cnt)
    );

    //-------------------------------------------------------------------------
    // 向量
    //-------------------------------------------------------------------------
    reg signed [DW-1:0] mem_in  [0:NTEST*N-1];
    reg        [DW:0]   mem_mag [0:NTEST*HALF-1];

    // 测试名只用于打印。用 ASCII —— iverilog 对非 ASCII 字符串支持不好会打乱码。
    reg [8*12-1:0] tname [0:NTEST-1];

    //-------------------------------------------------------------------------
    // 输出收集与比对
    //-------------------------------------------------------------------------
    integer t_idx  = 0;
    integer rx_cnt = 0;
    reg     rx_en  = 0;

    integer e_idx = 0;      // index 顺序错误数
    integer e_mag = 0;      // 幅度不符数
    integer n_chk = 0;      // 已比对总数
    integer shown = 0;

    always @(posedge clk) begin
        if (rx_en && y_valid && rx_cnt < HALF) begin
            n_chk = n_chk + 1;

            if (y_index !== rx_cnt[LOG2N-2:0]) begin
                e_idx = e_idx + 1;
                if (shown < 5) begin
                    shown = shown + 1;
                    $display("  [序错] 第 %0d 个输出: index=%0d 期望=%0d",
                             rx_cnt, y_index, rx_cnt);
                end
            end

            if (y_mag !== mem_mag[t_idx*HALF + rx_cnt]) begin
                e_mag = e_mag + 1;
                if (e_mag <= 5)
                    $display("  [值错] test%0d bin %0d : RTL=%0d 期望=%0d",
                             t_idx, rx_cnt, y_mag, mem_mag[t_idx*HALF + rx_cnt]);
            end

            rx_cnt = rx_cnt + 1;
        end
    end

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    integer i, to;

    initial begin
        $dumpfile("sim/build/tb_fft_core.vcd");
        $dumpvars(0, tb_fft_core);

        $display("=========================================================");
        $display(" fft_core 端到端验证：%0d 点实数 FFT，%0d 组测试", N, NTEST);
        $display(" 判据：512 个频点的幅度与 Python 黄金模型【逐位一致】");
        $display("=========================================================");

        $readmemh("sim/vectors/fft_in.hex",  mem_in);
        $readmemh("sim/vectors/fft_mag.hex", mem_mag);

        tname[0] = "impulse";
        tname[1] = "tone_1k";
        tname[2] = "2tones ";
        tname[3] = "small1k";

        // 复位
        repeat (8) @(posedge clk);
        rst_n <= 1'b1;
        repeat (4) @(posedge clk);

        for (t_idx = 0; t_idx < NTEST; t_idx = t_idx + 1) begin
            rx_cnt = 0;
            rx_en  = 1;

            // ---- 灌 N 个样本，每拍一个 ----
            for (i = 0; i < N; i = i + 1) begin
                @(negedge clk);
                x_in    <= mem_in[t_idx*N + i];
                x_valid <= 1'b1;
            end
            @(negedge clk);
            x_valid <= 1'b0;
            x_in    <= {DW{1'b0}};

            // ---- 等 512 个输出收齐 ----
            to = 0;
            while (rx_cnt < HALF && to < TIMEOUT) begin
                @(posedge clk);
                to = to + 1;
            end

            if (rx_cnt != HALF)
                $display("  [超时] test%0d 只收到 %0d / %0d 个输出",
                         t_idx, rx_cnt, HALF);
            else
                $display("  test%0d %s  OK  (等待 %0d 拍)", t_idx, tname[t_idx], to);

            rx_en = 0;
            repeat (10) @(posedge clk);
        end

        //---------------------------------------------------------------------
        // 汇总
        //---------------------------------------------------------------------
        $display("---------------------------------------------------------");
        $display(" 比对总数       : %0d   (期望 %0d x %0d)", n_chk, NTEST, HALF);
        $display(" 输出序号错误   : %0d", e_idx);
        $display(" 幅度不符       : %0d", e_mag);
        $display(" FIFO 丢样本    : %0d", drop_cnt);
        if (e_idx == 0 && e_mag == 0 && n_chk == NTEST*HALF && drop_cnt == 0)
            $display(" 结果           : *** PASS ***  FFT 端到端与黄金模型逐位一致");
        else
            $display(" 结果           : *** FAIL ***");
        $display("---------------------------------------------------------");
        $finish;
    end

endmodule
