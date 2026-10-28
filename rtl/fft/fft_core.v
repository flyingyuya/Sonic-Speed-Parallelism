//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    fft_core
// Module Name:    fft_core
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    fft_core.v - 1024 点实数 FFT 顶层（存储式，单蝶形时分复用）
// Dependencies:   audio_fifo.v   fft_addr_gen.v   fft_twiddle_rom.v
//                 fft_butterfly.v
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module fft_core #(
    parameter integer N          = 1024,    // 样本数量
    parameter integer LOG2N      = 10,
    parameter integer DW         = 24,      // 数据位宽
    parameter integer TW         = 16,      // 旋转因子位宽
    parameter integer FIFO_DEPTH = 64       // FIFO 深度
) (
    input  wire                  clk,       // clk_sys = 48 MHz
    input  wire                  rst_n,

    // 输入样本流（实数，Q1.23）
    input  wire signed [DW-1:0]  x_in,      // 样本数据
    input  wire                  x_valid,   // 输入有效指示

    // 输出幅度谱（前 N/2 个频点）
    output reg  [LOG2N-2:0]      y_index,   // 输出数据地址索引
    output reg  [DW:0]           y_mag,     // 输出幅度谱：Q1.23 量级
    output reg                   y_valid,   // 输出有效指示

    // 状态与诊断
    output wire                  busy,      // 忙指示：1 代表正在计算
    output reg  [7:0]            drop_cnt   // FIFO 溢出丢样本计数（应恒为 0）
);

    // 常量定义
    localparam integer HALF = N / 2;

    localparam [LOG2N-1:0] NLAST  = N - 1;              // 1023
    localparam [LOG2N-2:0] HALFM1 = HALF - 1;           // 511：本级最后一个蝶形号
    localparam [3:0]       STAGE_LAST = LOG2N - 1;      // 9：最后一级

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_RUN  = 2'd1;
    localparam [1:0] S_OUT  = 2'd2;

    // 变量声明
    reg  [1:0]        state;
    reg  [LOG2N-1:0]  n;             // 写帧计数 0..N-1
    reg  [LOG2N-1:0]  out_cnt;       // 输出计数 0..N/2
    reg  [3:0]        stage;         // 当前级数
    reg  [LOG2N-2:0]  cnt;           // 本级蝶形编号
    reg               run_phase;     // RUN 内：0=读周期 1=写周期

    wire signed [DW-1:0] fifo_dout;
    wire                 fifo_empty, fifo_full;

    wire [LOG2N-1:0]  ram_p, ram_q;
    wire [LOG2N-2:0]  ram_tw;
    wire [2*TW-1:0]   tw_word;

    wire [LOG2N-1:0]  wr_addr;
    wire [LOG2N-1:0]  bram_addr_a, bram_addr_b;

    wire signed [DW-1:0] bf_pr, bf_pi, bf_qr, bf_qi;
    wire signed [DW-1:0] din_re_a, din_im_a, din_re_b, din_im_b;
    wire                 we_a, we_b;

    reg  signed [DW-1:0] dout_re_a, dout_im_a;
    reg  signed [DW-1:0] dout_re_b, dout_im_b;

    wire [DW:0]   abs_re, abs_im, mx, mn, mn437;
    wire [DW:0]   mag;

    wire in_pop, fifo_rd;

    assign busy = (state == S_RUN);

    //=========================================================================
    // 输入 FIFO（复用 rtl/common/audio_fifo.v）
    //=========================================================================
    audio_fifo #(.DW(DW), .DEPTH(FIFO_DEPTH)) u_fifo (
        .clk(clk), .rst_n(rst_n),
        .wr_en(x_valid), .din(x_in), .full(fifo_full),
        .rd_en(fifo_rd), .dout(fifo_dout), .empty(fifo_empty),
        .count()
    );

    // 只在 IDLE 且 FIFO 非空时弹出
    assign in_pop  = (state == S_IDLE) && ~fifo_empty;
    assign fifo_rd = in_pop;

    //=========================================================================
    // 地址发生器 + 旋转因子 ROM
    //=========================================================================
    fft_addr_gen #(.LOG2N(LOG2N)) u_addr (
        .cnt(cnt), .stage(stage),
        .p(ram_p), .q(ram_q), .tw_idx(ram_tw)
    );

    fft_twiddle_rom u_tw (
        .addr(ram_tw), .dout(tw_word)
    );
    wire signed [TW-1:0] tw_re = tw_word[TW-1:0];       // 低 16 位 = 实部
    wire signed [TW-1:0] tw_im = tw_word[2*TW-1:TW];    // 高 16 位 = 虚部

    //-------------------------------------------------------------------------
    // 旋转因子打一拍再送蝶形：在 DSP48 和 LUTRAM 之间插入一级寄存器，减少关键路径
    //-------------------------------------------------------------------------
    reg signed [TW-1:0] tw_re_r, tw_im_r;

    always @(posedge clk) begin
        if (!rst_n) begin
            tw_re_r <= {TW{1'b0}};
            tw_im_r <= {TW{1'b0}};
        end else begin
            tw_re_r <= tw_re;
            tw_im_r <= tw_im;
        end
    end

    //=========================================================================
    // 写帧地址：位反转
    //=========================================================================
    function [LOG2N-1:0] bitrev;
        input [LOG2N-1:0] a;
        integer i;
        begin
            for (i = 0; i < LOG2N; i = i + 1)
                bitrev[i] = a[LOG2N-1-i];
        end
    endfunction

    assign wr_addr = bitrev(n);

    //=========================================================================
    // 数据 BRAM（实部 / 虚部各一个，真双口）
    //=========================================================================
    // (ram_style="block") 指定综合器使用块 RAM，而不是分布式 RAM
    (* ram_style = "block" *) reg signed [DW-1:0] mem_re [0:N-1];
    (* ram_style = "block" *) reg signed [DW-1:0] mem_im [0:N-1];

    assign bram_addr_a = (state == S_RUN) ? ram_p :
                         (state == S_OUT) ? out_cnt[LOG2N-2:0] : wr_addr;
    assign bram_addr_b = ram_q;

    // IDLE 写帧时要拿 FIFO 的数；RUN 写回时拿蝶形结果
    assign din_re_a = (state == S_RUN) ? bf_pr : fifo_dout;
    assign din_im_a = (state == S_RUN) ? bf_pi : {DW{1'b0}};   // 输入是实信号
    assign din_re_b = bf_qr;
    assign din_im_b = bf_qi;

    assign we_a = (state == S_IDLE) & in_pop | (state == S_RUN) & run_phase;
    assign we_b = (state == S_RUN) & run_phase;

    //-------------------------------------------------------------------------
    // 每个端口一个独立的 always 块，让 Vivado 推断为真双口 BRAM
    // 读-写同地址时是"read-first"（先读出旧值再写），这正是蝶形运算需要的
    //-------------------------------------------------------------------------
    // 端口 A（实部）
    always @(posedge clk) begin
        if (we_a) mem_re[bram_addr_a] <= din_re_a;
        dout_re_a <= mem_re[bram_addr_a];
    end

    // 端口 A（虚部）
    always @(posedge clk) begin
        if (we_a) mem_im[bram_addr_a] <= din_im_a;
        dout_im_a <= mem_im[bram_addr_a];
    end

    // 端口 B（实部）
    always @(posedge clk) begin
        if (we_b) mem_re[bram_addr_b] <= din_re_b;
        dout_re_b <= mem_re[bram_addr_b];
    end

    // 端口 B（虚部）
    always @(posedge clk) begin
        if (we_b) mem_im[bram_addr_b] <= din_im_b;
        dout_im_b <= mem_im[bram_addr_b];
    end

    //=========================================================================
    // 蝶形单元（组合逻辑）
    //=========================================================================
    fft_butterfly #(.DW(DW), .TW(TW)) u_bf (
        .ar(dout_re_a), .ai(dout_im_a),
        .br(dout_re_b), .bi(dout_im_b),
        .wr(tw_re_r),   .wi(tw_im_r),
        .pr(bf_pr), .pi(bf_pi), .qr(bf_qr), .qi(bf_qi)
    );

    //=========================================================================
    // 输出幅度：  |X| ≈ max + 0.4375·min   （0.4375 = 1/2 - 1/16）
    //    OUT 状态时 dout_a 就是当前频点的 (re, im)
    //=========================================================================
    // 绝对值要先扩到 DW+1 位再取负
    assign abs_re = dout_re_a[DW-1] ? ({1'b0, ~dout_re_a} + 1'b1) : {1'b0, dout_re_a};
    assign abs_im = dout_im_a[DW-1] ? ({1'b0, ~dout_im_a} + 1'b1) : {1'b0, dout_im_a};

    assign mx    = (abs_re > abs_im) ? abs_re : abs_im;
    assign mn    = (abs_re > abs_im) ? abs_im : abs_re;
    assign mn437 = (mn >> 1) - (mn >> 4);
    assign mag   = {1'b0, mx} + {1'b0, mn437};

    //=========================================================================
    // 主状态机
    //=========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_IDLE;
            n         <= {LOG2N{1'b0}};
            out_cnt   <= {LOG2N{1'b0}};
            stage     <= 4'd0;
            cnt       <= {(LOG2N-1){1'b0}};
            run_phase <= 1'b0;
            y_index   <= {(LOG2N-1){1'b0}};
            y_mag     <= {(DW+1){1'b0}};
            y_valid   <= 1'b0;
            drop_cnt  <= 8'd0;
        end else begin
            case (state)

                //-----------------------------------------------------------
                // IDLE：从 FIFO 取样本，写进 mem[bitrev(n)]；虚部恒为 0
                //-----------------------------------------------------------
                S_IDLE: begin
                    y_valid <= 1'b0;
                    if (in_pop) begin
                        n <= n + 1'b1;
                        if (n == NLAST) begin
                            // 本拍写完最后一个样本，下一拍开始蝶形
                            state     <= S_RUN;
                            stage     <= 4'd0;
                            cnt       <= {(LOG2N-1){1'b0}};
                            run_phase <= 1'b0;
                        end
                    end
                end

                //-----------------------------------------------------------
                // RUN：每个蝶形占 2 拍
                //   phase=0 读：把 (p,q) 作为读地址送进 BRAM
                //   phase=1 写：BRAM 数据已回来 → 蝶形组合计算 → 写回同一地址
                //-----------------------------------------------------------
                S_RUN: begin
                    if (!run_phase) begin
                        run_phase <= 1'b1;                  // 下一拍进写周期
                    end else begin
                        run_phase <= 1'b0;
                        if (cnt == HALFM1) begin
                            cnt <= {(LOG2N-1){1'b0}};
                            if (stage == STAGE_LAST) begin
                                state   <= S_OUT;           // 全部级数完成
                                out_cnt <= {LOG2N{1'b0}};
                            end else begin
                                stage <= stage + 4'd1;
                            end
                        end else begin
                            cnt <= cnt + 1'b1;
                        end
                    end
                end

                //-----------------------------------------------------------
                // OUT：按自然顺序读 0..N/2-1，算幅度输出
                //-----------------------------------------------------------
                S_OUT: begin
                    if (out_cnt != {LOG2N{1'b0}}) begin
                        y_index <= out_cnt[LOG2N-2:0] - 1'b1;
                        y_mag   <= mag;
                        y_valid <= 1'b1;
                    end else begin
                        y_valid <= 1'b0;
                    end

                    if (out_cnt == HALF[LOG2N-1:0]) begin
                        state   <= S_IDLE;
                        out_cnt <= {LOG2N{1'b0}};
                        n       <= {LOG2N{1'b0}};       // 准备写下一帧
                    end else begin
                        out_cnt <= out_cnt + 1'b1;
                    end
                end

                default: state <= S_IDLE;
            endcase

            // FIFO 溢出计数：理论上恒为 0（深度 64，最大积压 ~11）
            if (x_valid && fifo_full) drop_cnt <= drop_cnt + 8'd1;
        end
    end

endmodule
