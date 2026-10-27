//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    spectrum
// Module Name:    spectrum
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    spectrum.v - 频谱柱高生成（clk_sys 域，FFT 的直接下游）
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module spectrum #(
    parameter integer NBARS   = 60,     // 柱数（480px/60 = 每根 8px，下标零运算）
    parameter integer DW      = 25,     // fft_core 的 y_mag 位宽
    parameter integer HW      = 9,      // 柱高位宽
    parameter integer DECAY   = 6,      // 每帧衰减量（0 = 不衰减，只保持峰值）
    // DB_OFFS：多小的信号算"没有信号"（显示成 0）。
    //   单位是 log2 的 Q5.3，所以 64 = 2^8、80 = 2^10、96 = 2^12。
    //
    //   【2026-10 从 64 调到 80】用户反馈"安静时全频段都有柱子 ✗ 高频也是"。
    //   根因是【话筒的 SNR 天生比线路输入差 30~40 dB】（Music-Spectrum 那个
    //   项目用的是 Line In ✗ 信噪比 90~100dB ✗ 我们是 MEMS 话筒 ✗ 只有 50~60dB）。
    //   把门槛抬高 4 倍（2^8 -> 2^10）等于把底噪那一层直接判成 0，
    //   画面立刻干净很多；代价是**比 2^10 还弱的真实信号也不显示了**。
    //   想再干净就往 96 调，想更灵敏就回到 64 —— 这个数是【观感旋钮】。
    parameter integer DB_OFFS = 80,     // log2 偏移（Q5.3）；mag < 2^(OFFS/8) 显示为 0
    parameter integer SCALE_SH= 2,

    //-------------------------------------------------------------------------
    // 【sqrt 显示】把 dB 刻度拉长一倍
    //-----------------------------------------------------------------------------
    //   用户要的"频谱幅度开根号"，其实【不是新算法】：
    //
    //       20*log10(sqrt(x)) = 10*log10(x)
    //               ↑
    //       sqrt 在对数域里就是【减半】
    //
    //   而这里本来就在 log2 域里算高度（hsc = lv << SCALE_SH）。
    //   所以"开根号"= 把斜率减半 = SCALE_SH 减 1 = 设成 1。
    //   观感：现在约 60 dB 铺满全高；sqrt 模式下相当于 120 dB 铺满全高，
    //   低声压的柱子会明显变高（更热闹，但动态范围被压缩）。
    //
    //   ⚠️ 做成【参数】而不是写死：参数默认值就是原来的 2，
    //      逐位不变、零风险；想试 sqrt 就在实例化时改成 1。
    //      要"运行时可切"的话，再把它做成 ui_ctrl 的一个寄存器位即可。
    parameter integer SQRT_SCALE_SH = 2       // 高度缩放（左移位数）
) (
    input  wire                    clk,          // clk_sys
    input  wire                    rst_n,

    //---------------------- 来自 fft_core ----------------------
    input  wire                    in_valid,
    input  wire [8:0]              in_index,     // 0 .. 511
    input  wire [DW-1:0]           in_mag,

    //---------------------- 输出：拉平的柱高 ----------------------
    output wire [NBARS*HW-1:0]     bar_flat,
    output reg                     frame_done    // 最后一根柱完成，1 拍脉冲
);

    localparam integer AW   = $clog2(NBARS);            // 柱编号位宽
    localparam integer MAXH = (1 << HW) - 1;            // 高度上限

    // 状态寄存器（声明必须在使用之前 —— Verilog 不允许先用后声明）
    reg  [AW-1:0]       bar_cur;                        // 当前正在累积的柱编号
    reg  [HW-1:0]       cur_max;                        // 本柱已见到的最大高度
    reg  [NBARS*HW-1:0] peak;                           // 峰值保持值（拉平存储，方便变址）

    //=========================================================================
    // 分组表：当前柱的最后一个 bin 编号
    //   bcur 在帧首强制为 0，所以 last_bin 也要跟着用 bcur 去查 ——
    //   否则帧首那一拍会拿上一帧残留的 bar_cur 去查表。
    //=========================================================================
    wire              fstart = in_valid && (in_index == 9'd0);
    wire [AW-1:0]     bcur   = fstart ? {AW{1'b0}} : bar_cur;
    wire [8:0]        last_bin;

    //-------------------------------------------------------------------------
    // bin 分组表：按 NBARS 选表
    //   NBARS=60 ⟹ spectrum_map   （LCD ✗ 480/60 = 8 px/柱）
    //   NBARS=80 ⟹ spectrum_map80 （HDMI ✗ 640/80 = 8 px/柱）
    //   ⚠️ 两张表都由 scripts/golden/gen_spectrum_map.py 生成
    //      参数（--nbars / --out / --module）见脚本注释
    //      default 分支会给 last_bin=0 ⟹ frame_done 永不触发 ⟹ 柱谱全没
    //      （这个坑踩过了：用 NBARS=80 却用 60 的表 ⟹ 画面全空）
    //-------------------------------------------------------------------------
    generate
        if (NBARS == 80) begin : g_map80
            spectrum_map80 #(.NBARS(80), .AW(AW)) u_map (
                .bar      (bcur),
                .last_bin (last_bin)
            );
        end else begin : g_map60
            spectrum_map #(.NBARS(60), .AW(AW)) u_map (
                .bar      (bcur),
                .last_bin (last_bin)
            );
        end
    endgenerate

    //=========================================================================
    // 幅度 -> 高度（log2 Q5.3 压缩）
    //=========================================================================
    // 找最高位位置（综合成优先编码器）
    function [4:0] msb_pos;
        input [DW-1:0] v;
        integer i;
        begin
            msb_pos = 5'd0;
            for (i = 0; i < DW; i = i + 1)
                if (v[i]) msb_pos = i[4:0];
        end
    endfunction

    wire [4:0]  mp    = msb_pos(in_mag);
    // 把最高位移到 bit[DW-1]，尾数就成了归一化小数
    wire [4:0]  sh    = 5'd24 - mp;                  // DW-1 = 24
    wire [DW-1:0] nrm = in_mag << sh;
    // Q5.3：5 位整数部分 + 3 位小数部分
    wire [7:0]  ilog2 = {mp, nrm[DW-2 -: 3]};

    wire [8:0]  lv  = ({1'b0, ilog2} > DB_OFFS) ? ({1'b0, ilog2} - DB_OFFS) : 9'd0;
    wire [9:0]  hsc = lv << SQRT_SCALE_SH;
    wire [HW-1:0] lvl = (hsc > MAXH) ? MAXH[HW-1:0] : hsc[HW-1:0];

    //=========================================================================
    // 状态：当前柱编号 / 本柱已累积的最大高度 / 峰值保持值
    //=========================================================================
    wire              bar_done = in_valid && (in_index == last_bin);
    wire [HW-1:0]     raw      = (lvl > cur_max) ? lvl : cur_max;
    wire [HW-1:0]     old      = peak[bcur*HW +: HW];

    // 峰值保持 + 线性衰减
    //   注意这里是 >= 而不是 > —— 用 > 的话柱子在降到刚好等于 DECAY 时会永远停住，
    //   再也回不到 0（6/511 虽然看不见，但语义是错的）。
    wire [HW-1:0]     upd      = (raw >= old)                             ? raw
                               : ((old >= DECAY) && ((old - raw) >= DECAY)) ? (old - DECAY)
                               :                                               old;

    always @(posedge clk) begin
        if (!rst_n) begin
            bar_cur    <= {AW{1'b0}};
            cur_max    <= {HW{1'b0}};
            peak       <= {(NBARS*HW){1'b0}};
            frame_done <= 1'b0;
        end else begin
            frame_done <= bar_done && (bcur == NBARS - 1);

            if (in_valid) begin
                if (bar_done) begin
                    // 本柱结束：结算峰值，推进到下一根
                    peak[bcur*HW +: HW] <= upd;
                    cur_max             <= {HW{1'b0}};
                    if (bcur == NBARS - 1)
                        bar_cur <= bcur;             // 最后一根，保持
                    else if (fstart)
                        bar_cur <= {{(AW-1){1'b0}}, 1'b1};
                    else
                        bar_cur <= bcur + 1'b1;
                end else begin
                    cur_max <= (lvl > cur_max) ? lvl : cur_max;
                    if (fstart) bar_cur <= {AW{1'b0}};
                end
            end
        end
    end

    assign bar_flat = peak;

endmodule
