//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    audio_top
// Module Name:    audio_top
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    audio_top.v - 音频链路顶层（I2S → 低延迟均衡 → I2S）
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module audio_top #(
    parameter integer DW      = 24,
    parameter integer CW      = 18,
    parameter integer CF      = 16,
    parameter integer AW      = 48,
    parameter integer NSECT   = 5,
    parameter integer SLOT    = 32,
    parameter integer NGAIN   = 21,
    parameter integer NROMW   = 10     // 总表项 5*21*5 = 525 -> 需 10bit 地址
) (
    input  wire clk,            // clk_sys = 48 MHz
    input  wire rst_n,

    // 喇叭静音（1 = 静音）。
    //   实现方式：把送进 i2s_tx 的数据清零 ⟹ WM8960 收到全 0 采样 ⟹ 无声。
    //   为什么不在 WM8960 里静音（写 R28/R29）：
    //     那需要在运行时再发 I2C 写 ✗ 而 WM8960_init 是一次性播 ROM 的结构,
    //     为这个功能加一条 I2C 命令通道代价太大。
    //     在 FPGA 侧清零数据是零风险的做法 ✓ 而且不会爆音（I2S 时序完全不变）。
    input  wire        mute,

    // ---- I2S 物理接口（从模式：bclk/lrclk 由 WM8960 提供）----
    input  wire bclk,
    input  wire lrclk,
    input  wire sdin,           // WM8960 ADCDAT → FPGA
    output wire sdout,          // FPGA → WM8960 DACDAT

    // ---- 控制（必须已同步到 clk 域）----
    input  wire [NSECT*5-1:0] band_gain,   // 每频段 5bit 增益档位：0..20 -> -10..+10 dB
    input  wire               cfg_load,    // 拉高至少 1 个 clk，触发系数重载
    input  wire               bypass,      // 1 = 直通
    output wire               cfg_busy,
    output wire               running,     // 系数装载完成、正在处理样本

    // ---- 调试 / 下游观测 ----
    output wire               dbg_bclk_rise,
    output wire               dbg_bclk_fall,
    output wire               dbg_frame_start,
    output wire               dbg_half_start,
    output wire [5:0]         dbg_bit_idx,
    output wire               dbg_sample_stb,

    // 接收到的样本（去 EQ 之前），送给 FFT 做频谱分析
    output wire signed [DW-1:0] dbg_rx_l,
    output wire signed [DW-1:0] dbg_rx_r,
    output wire                 dbg_rx_valid
);

    localparam integer NCOE = NSECT * 5;

    //-------------------------------------------------------------------------
    // 声明区（全部前置，避免"先用后声明"）
    //-------------------------------------------------------------------------
    wire        bclk_rise, bclk_fall, frame_start, half_start, sample_stb;
    wire [5:0]  bit_idx;

    wire signed [DW-1:0] rx_l, rx_r;
    wire                 rx_valid;

    wire signed [CW-1:0] rom_dout;
    reg  [NROMW-1:0]     rom_addr;

    wire [2*DW-1:0] in_dout;
    wire            in_empty, in_full;
    wire [3:0]      in_count;
    wire            in_rd_en;

    wire                 eq_l_ready, eq_r_ready;
    wire signed [DW-1:0] eq_l_out, eq_r_out;
    wire                 eq_l_val, eq_r_val;

    wire [2*DW-1:0] out_dout;
    wire            out_empty, out_full;
    wire [3:0]      out_count;

    wire            eq_ready;
    wire            pop;
    wire            tx_load;

    //-------------------------------------------------------------------------
    // I2S 时序恢复（从模式）
    //-------------------------------------------------------------------------
    i2s_slave_clk #(.SLOT(SLOT)) u_clkgen (
        .clk(clk), .rst_n(rst_n),
        .bclk(bclk), .lrclk(lrclk),
        .bclk_rise(bclk_rise), .bclk_fall(bclk_fall),
        .frame_start(frame_start), .half_start(half_start),
        .bit_idx(bit_idx), .sample_stb(sample_stb)
    );

    //-------------------------------------------------------------------------
    // I2S 接收（**换成直接拿 BCLK 当采样时钟**）—— 2026-10
    //-------------------------------------------------------------------------
    //   【为什么只换 RX】
    //     原来 RX 用 i2s_slave_clk 在 clk_sys 域过采样 BCLK、自己纠正帧对齐。
    //     上板实测：把输入 PGA 静音（ADC 必然输出 0）时读到的却是一串快速
    //     跳动的数字 -> 接收器读到的根本不是 ADCDAT 上的电平。
    //     换成教科书写法（posedge bclk 直接当采样沿）后，
    //     sim/tb/tb_i2s_bclk_if.v 里 RX 四项全部通过。
    //
    //   【为什么 TX 暂时不动】
    //     新模块的 TX 还差一个 BCLK（见那个 TB 的注释）。为了把迁移量降到最小：
    //       · i2s_slave_clk 和 i2s_tx【原样保留】-> 它们继续产生/使用
    //         bclk_rise / bclk_fall / frame_start / bit_idx
    //       · codec_model 和 tb_audio_top 的 DAC 侧一个字都不用改
    //     新模块的 dacdat 输出【空接】不驱动（旧 i2s_tx 仍然是 sdout 的驱动源）。
    //
    //   注意：这里不要给 bclk/lrclk 加 create_clock —— 它们仍被 i2s_slave_clk
    //   当普通信号过采样，加了反而会引入一场假违例。
    //-------------------------------------------------------------------------
    i2s_bclk_if #(.SLOT(SLOT), .DATA_BITS(DW), .DW(DW)) u_i2s_rxnew (
        .bclk       (bclk),
        .lrclk      (lrclk),
        .adcdat     (sdin),
        .dacdat     (),                 // 发送侧仍由下面的 i2s_tx 负责
        .clk        (clk),
        .rst_n      (rst_n),
        .rx_l       (rx_l),
        .rx_r       (rx_r),
        .rx_valid   (rx_valid),
        .tx_l       ({DW{1'b0}}),
        .tx_r       ({DW{1'b0}}),
        .tx_en      (1'b0),             // 不让它发送
        .dbg_rx_seen(),
        .dbg_tx_lr  ()
    );

    //-------------------------------------------------------------------------
    // 系数装载 FSM
    //-------------------------------------------------------------------------
    localparam ST_IDLE = 2'd0, ST_ADDR = 2'd1, ST_WR = 2'd2, ST_NXT = 2'd3;

    reg  [1:0]           st;
    reg  [4:0]           ld_cnt;
    reg  [NSECT*5-1:0]   gain_reg;
    reg                  coe_we;
    reg  [4:0]           coe_addr;
    reg  signed [CW-1:0] coe_wdata;
    reg                  dirty;

    wire [4:0]       cur_band  = ld_cnt / 5;
    wire [4:0]       cur_gain  = gain_reg[cur_band*5 +: 5];
    wire [NROMW-1:0] next_addr = (cur_band * NGAIN + cur_gain) * 5 + (ld_cnt % 5);

    eq_coeff_rom u_rom (.addr(rom_addr), .dout(rom_dout));

    always @(posedge clk) begin
        if (!rst_n) begin
            st        <= ST_IDLE;
            ld_cnt    <= 5'd0;
            rom_addr  <= {NROMW{1'b0}};
            gain_reg  <= {(NSECT*5){1'b0}};
            coe_we    <= 1'b0;
            coe_addr  <= 5'd0;
            coe_wdata <= {CW{1'b0}};
            dirty     <= 1'b1;
        end else begin
            coe_we <= 1'b0;

            // 配置请求：只置 dirty，不直接改 gain_reg。
            // 若在装载过程中又收到请求，dirty 置位，当前装载结束后自动重载。
            // （早期版本在这里直接写 gain_reg，导致装载中途换档，
            //   前几个系数用旧档位、后几个用新档位 —— band0 系数错的根源）
            if (cfg_load && (band_gain != gain_reg) && !dirty)
                dirty <= 1'b1;

            case (st)
                ST_IDLE: begin
                    if (dirty) begin
                        gain_reg <= band_gain;   // 装载开始时锁存，整轮不变
                        dirty    <= 1'b0;
                        ld_cnt   <= 5'd0;
                        st       <= ST_ADDR;
                    end
                end

                ST_ADDR: begin
                    rom_addr <= next_addr;
                    st       <= ST_WR;
                end

                ST_WR: begin
                    coe_we    <= 1'b1;
                    coe_addr  <= ld_cnt;
                    coe_wdata <= rom_dout;
                    st        <= ST_NXT;
                end

                ST_NXT: begin
                    if (ld_cnt == NCOE[4:0] - 5'd1) begin
                        st <= ST_IDLE;          // dirty 的清零已移到 ST_IDLE 入口
                    end else begin
                        ld_cnt <= ld_cnt + 5'd1;
                        st     <= ST_ADDR;
                    end
                end

                // 4 个状态已用满 2bit，default 不可达；
                // 写上是为了：① 满足 lint ② 万一 st 被翻转成非法值能自恢复
                default: st <= ST_IDLE;
            endcase
        end
    end

    assign cfg_busy = (st != ST_IDLE) || dirty;
    assign running  = ~cfg_busy;

    //-------------------------------------------------------------------------
    // 输入 FIFO
    //-------------------------------------------------------------------------
    audio_fifo #(.DW(2*DW), .DEPTH(8)) u_fifo_in (
        .clk(clk), .rst_n(rst_n),
        .wr_en(rx_valid), .din({rx_l, rx_r}), .full(in_full),
        .rd_en(in_rd_en), .dout(in_dout), .empty(in_empty), .count(in_count)
    );

    // 两个声道都空闲、FIFO 非空、且不在装载系数时才弹出一个样本
    assign eq_ready = eq_l_ready & eq_r_ready;
    assign pop      = ~in_empty & eq_ready & running;
    assign in_rd_en = pop;

    //-------------------------------------------------------------------------
    // 双声道均衡器（共享同一组系数）
    //-------------------------------------------------------------------------
    eq_cascade #(.DW(DW), .CW(CW), .CF(CF), .AW(AW), .NSECT(NSECT)) u_eq_l (
        .clk(clk), .rst_n(rst_n),
        .coe_we(coe_we), .coe_addr(coe_addr), .coe_wdata(coe_wdata),
        .bypass(bypass),
        .x_in(in_dout[2*DW-1:DW]), .x_valid(pop), .x_ready(eq_l_ready),
        .y_out(eq_l_out), .y_valid(eq_l_val)
    );

    eq_cascade #(.DW(DW), .CW(CW), .CF(CF), .AW(AW), .NSECT(NSECT)) u_eq_r (
        .clk(clk), .rst_n(rst_n),
        .coe_we(coe_we), .coe_addr(coe_addr), .coe_wdata(coe_wdata),
        .bypass(bypass),
        .x_in(in_dout[DW-1:0]), .x_valid(pop), .x_ready(eq_r_ready),
        .y_out(eq_r_out), .y_valid(eq_r_val)
    );

    //-------------------------------------------------------------------------
    // 输出 FIFO + I2S 发送
    //-------------------------------------------------------------------------
    assign tx_load = frame_start & ~out_empty;

    audio_fifo #(.DW(2*DW), .DEPTH(8)) u_fifo_out (
        .clk(clk), .rst_n(rst_n),
        .wr_en(eq_l_val & eq_r_val), .din({eq_l_out, eq_r_out}), .full(out_full),
        .rd_en(tx_load), .dout(out_dout), .empty(out_empty), .count(out_count)
    );

    // 欠载时保持上一帧（data_en=0），避免爆音
    i2s_tx #(.SLOT(SLOT), .DATA_BITS(DW), .DW(DW)) u_tx (
        .clk(clk), .rst_n(rst_n),
        .bclk_fall(bclk_fall), .frame_start(frame_start), .bit_idx(bit_idx),
        // 静音时送全 0（保持 data_en，让 I2S 时序不受影响）
        .l_data(mute ? {DW{1'b0}} : out_dout[2*DW-1:DW]),
        .r_data(mute ? {DW{1'b0}} : out_dout[DW-1:0]),
        .data_en(~out_empty),
        .sdout(sdout)
    );

    //-------------------------------------------------------------------------
    // 调试可观测信号（ILA / 逻辑分析用）
    //-------------------------------------------------------------------------
    wire [3:0] dbg_in_count  = in_count;
    wire [3:0] dbg_out_count = out_count;

    assign dbg_bclk_rise  = bclk_rise;
    assign dbg_bclk_fall  = bclk_fall;
    assign dbg_frame_start= frame_start;
    assign dbg_half_start = half_start;
    assign dbg_bit_idx    = bit_idx;
    assign dbg_sample_stb = sample_stb;

    assign dbg_rx_l     = rx_l;
    assign dbg_rx_r     = rx_r;
    assign dbg_rx_valid = rx_valid;

endmodule
