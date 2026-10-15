//=============================================================================
// audio_top.v - 音频链路顶层（I2S → 低延迟均衡 → I2S）
//-----------------------------------------------------------------------------
// 【从模式】WM8960 是本工程的 I2S 主（手册 P56：数字音频接口也从 SYSCLK 派生，
// MCLK 必须与 BCLK/LRCLK 同源），所以 bclk / lrclk 在这里是**输入**。
// 时序恢复由 i2s_slave_clk 完成，输出契约与原来的 i2s_clkgen 完全一致，
// 所以 i2s_rx / i2s_tx / eq_cascade / audio_fifo 一个字都没改。
//
//                          ┌────────────────┐
//   sdin ─▶ i2s_rx ─▶ fifo ─▶ eq_cascade L ─┐
//                          └▶ eq_cascade R ─┴─▶ fifo ─▶ i2s_tx ──▶ sdout
//                ▲                                              │
//                └──── i2s_slave_clk（从 bclk/lrclk 恢复时序）──┘
//
// 单一时钟域：clk = clk_sys = 48 MHz。在从模式下本模块不再需要
// "BCLK = clk/4" 这种整数关系 —— i2s_slave_clk 靠过采样恢复边沿，
// 只要 clk 明显快于 BCLK 即可（48 MHz / 3.072 MHz = 15.6 倍）。
//
// 系数由 eq_coeff_rom 提供：5 个频段 x 21 个增益档，每个频段独立选档。
// 换挡时本地 FSM 把 25 个系数重新灌进两个声道的 eq_cascade。
//
// 为什么收发两侧都要加 FIFO：
//   RX 在帧尾（bit_idx=2*SLOT-1）才吐出样本，而 TX 必须在下一帧起点装载。
//   EQ 又要 6 个 clk。FIFO 把"帧节拍"和"处理节拍"解耦，
//   同时吸收系数装载期间的样本堆积。
//=============================================================================
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
    wire        dbg_sample_stb_i, dbg_frame_start_i;

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

    //-------------------------------------------------------------------------
    // I2S 接口（**直接拿 BCLK 当采样时钟**）—— 2026-10 重写
    //-------------------------------------------------------------------------
    //   原来用 i2s_slave_clk + i2s_rx/i2s_tx：在 clk_sys 域过采样 BCLK、
    //   自己纠正帧对齐。上板实测 RX 读不到 ADCDAT。换成教科书写法后，
    //   sim/tb/tb_i2s_bclk_if.v 里 RX 4 项 + TX 2 项【全部通过】。
    //   收发都在同一个模块里，跨域用"翻转标志 + 数据保持"。
    //-------------------------------------------------------------------------
    // ⚠️⚠️ tx 的"取走"节拍不能来自 FIFO 的 empty
    //   tx_en 在 i2s_bclk_if 里有【两层语义】：
    //     (a) 把值保持进发送寄存器  -> 只要非空就该持续有效
    //     (b) 从 FIFO 取走一个      -> 必须每帧一次
    //   绑 rx_valid：那一拍 EQ 还没算完（要 NSECT 拍），FIFO 空 -> 从来取不到
    //   绑 ~out_empty：每拍都取 -> FIFO 瞬间排空 -> 延迟 4 帧涨到 60 帧
    //   两个都错。EQ 和 TX 都在 clk 域，直接把 EQ 输出送给 TX 最干净：
    //   每产出一次就更新一次发送寄存器，模块自己按帧发出去。
    wire                 tx_load   = eq_l_val & eq_r_val;
    wire signed [DW-1:0] tx_l_data = eq_l_out;
    wire signed [DW-1:0] tx_r_data = eq_r_out;

    i2s_bclk_if #(.SLOT(SLOT), .DATA_BITS(DW), .DW(DW)) u_i2s (
        .bclk       (bclk),
        .lrclk      (lrclk),
        .adcdat     (sdin),
        .dacdat     (sdout),
        .clk        (clk),
        .rst_n      (rst_n),
        .rx_l       (rx_l),
        .rx_r       (rx_r),
        .rx_valid   (rx_valid),
        .tx_l       (tx_l_data),
        .tx_r       (tx_r_data),
        .tx_en      (tx_load),
        .dbg_rx_seen(dbg_sample_stb_i),
        .dbg_tx_lr  (dbg_frame_start_i)
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
    // tx_load 由 rx_valid 产生（见上面的 i2s_bclk_if 段）

    audio_fifo #(.DW(2*DW), .DEPTH(8)) u_fifo_out (
        .clk(clk), .rst_n(rst_n),
        .wr_en(eq_l_val & eq_r_val), .din({eq_l_out, eq_r_out}), .full(out_full),
        .rd_en(eq_l_val & eq_r_val), .dout(out_dout), .empty(out_empty), .count(out_count)
    );

    // （发送侧已并进上面的 i2s_bclk_if）

    //-------------------------------------------------------------------------
    // 调试可观测信号（ILA / 逻辑分析用）
    //-------------------------------------------------------------------------
    wire [3:0] dbg_in_count  = in_count;
    wire [3:0] dbg_out_count = out_count;

    // 旧时序信号已不存在；观测口保留
    assign dbg_bclk_rise  = 1'b0;
    assign dbg_bclk_fall  = 1'b0;
    assign dbg_half_start = 1'b0;
    assign dbg_bit_idx    = 6'd0;
    assign dbg_frame_start= dbg_frame_start_i;
    assign dbg_sample_stb = dbg_sample_stb_i;

    assign dbg_rx_l     = rx_l;
    assign dbg_rx_r     = rx_r;
    assign dbg_rx_valid = rx_valid;

endmodule
