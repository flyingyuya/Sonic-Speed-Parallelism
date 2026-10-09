//=============================================================================
// spectrum.v - 频谱柱高生成（clk_sys 域，FFT 的直接下游）
//-----------------------------------------------------------------------------
// 输入：fft_core 顺序输出的 512 个频点 (index, magnitude)
// 输出：60 根柱的高度（9 位，0..511），带峰值保持与线性衰减
//
// 【处理链】
//
//   bin 流 ──▶ ①对数频率分组 ──▶ ②组内取最大 ──▶ ③幅度->高度 ──▶ ④峰值保持+衰减
//               spectrum_map        逐柱累积            dB 压缩         每帧一次
//
// 【① 分组】低频 16 根线性 + 高频 44 根对数
//   为什么不能纯对数：512 个 bin 分 60 根柱，平均每柱 8.5 个 bin。
//   纯对数时低频前几根柱只覆盖 1 个甚至 0 个 bin，会看到一根根空柱子。
//   分组表由 scripts/golden/gen_spectrum_map.py 生成，可自由调。
//
// 【③ dB 压缩】用 log2 近似，而不是开方或线性
//   线性：只有最强的几根柱子看得见，音乐一停全塌
//   开方：压缩不足，动态范围还是太大
//   dB  ：标准频谱分析仪的做法，视觉上最接近"听觉响度"
//
//   实现：先找最高位位置 mp，再把尾数归一化后取高 3 位，拼成 Q5.3 的 log2
//
//       ilog2 = { mp[4:0], 尾数高 3 位 }      单位 = 1/8 个八度
//       相当于每个 ilog2 单位 = 0.7525 dB
//
//   然后  高度 = (ilog2 - DB_OFFS) << SCALE_SH，钳位到 0..511
//   默认 DB_OFFS=64（log2=8，即 mag<256 显示为 0），SCALE_SH=2
//   -> 每像素约 0.188 dB，满量程约 96 dB 动态范围
//
// 【④ 峰值保持】跟涨不跟跌，跌的时候每帧线性降 DECAY
//       新值 >= 旧值            -> 立即跟上
//       旧值 - 新值 >= DECAY     -> 旧值 -= DECAY
//       否则                     -> 保持不动（这一段是"峰值保持"的手感来源）
//
// 【接口约定】VERILOG-2001 不支持数组端口，所以柱高拉平成一个向量：
//       bar_flat[(i+1)*HW-1 : i*HW] = 第 i 根柱的高度
//=============================================================================
`timescale 1ns/1ps

module spectrum #(
    parameter integer NBARS   = 60,     // 柱数（480px/60 = 每根 8px，下标零运算）
    parameter integer DW      = 25,     // fft_core 的 y_mag 位宽
    parameter integer HW      = 9,      // 柱高位宽
    parameter integer DECAY   = 6,      // 每帧衰减量（0 = 不衰减，只保持峰值）
    parameter integer DB_OFFS = 64,     // log2 偏移（Q5.3）；mag < 2^(OFFS/8) 显示为 0
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

    spectrum_map #(.NBARS(NBARS), .AW(AW)) u_map (
        .bar      (bcur),
        .last_bin (last_bin)
    );

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
