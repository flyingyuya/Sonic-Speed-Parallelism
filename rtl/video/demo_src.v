//////////////////////////////////////////////////////////////////////////////////
// Company:        个人项目 / SonicTwin-Engine
// Engineer:       flyingyu
//
// Create Date:    2026-10-26
// Design Name:    demo_src
// Module Name:    demo_src
// Project Name:   音速双擎（SonicTwin-Engine）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    demo_src.v - 演示 / 自检图案源
//                 【为什么需要这个模块】
//                 显示链（柱状 / 极坐标 / 波形）在硬件上一直是【零观察】的：
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


// 【更新速率怎么定的 —— 这里返过工】
//   第一版取 TICK_B=17（2.73 ms）+ 相位每次 +3，上板后是一片糊：
//   峰值 55 ms 就扫完一圈。原因是两个错误叠在一起 ——
//     ① 更新周期比 LCD 帧周期短太多。LCD 一帧是
//          525 x 286 / 12.5 MHz = 12.01 ms
//        而 demo 每 2.73 ms 就换一帧 -> **比显示刷新快 4.4 倍**，
//        屏幕上一帧里已经跳了 4 次图案，看上去就是抖。
//        **更新得比显示刷新快是纯浪费** —— 那些帧根本没人看到。
//     ② 相位步进 3 又把这个速度乘了 3。
//
//   改成 TICK_B=20（21.85 ms，约 LCD 帧周期的 1.8 倍）+ PH_STEP=1：
//   峰值 60 x 21.85 ms = **1.31 s 扫完一圈**，看起来像真的频谱仪。
//
//   注：真实链路里 FFT 帧约 224 us（比 LCD 帧快得多），但看不出问题 ——
//   因为显示侧只在帧起始锁存一次（spec_sync），**实际可见刷新率就是
//   LCD 帧率**。演示源应该直接按这个来，不必去学 FFT 的帧率。
//=============================================================================
module demo_src #(
    parameter integer NBARS   = 60,             // 柱数
    parameter integer HW      = 9,              // 每根柱的高度位宽
    parameter integer DW      = 24,             // 采样位宽
    parameter integer TICK_B  = 20,             // 每 2^TICK_B 拍更新一次（48MHz -> 21.85ms）
    parameter integer PH_STEP = 1,              // 每次更新相位推进几根柱
    parameter integer WV      = 16,             // 包络峰半宽（柱数）
    parameter integer WS      = 5,              // 包络峰缩放（左移位数）
    parameter integer LF_W    = 8,              // 低频抬升半宽
    parameter integer LF_A    = 4               // 低频抬升缩放
) (
    input  wire                  clk,
    input  wire                  rst_n,
    input  wire [1:0]            mode,          // 0=关 1=斜坡 2=棋盘 3=包络

    output reg  [NBARS*HW-1:0]   bar_flat,
    output reg                   bar_wr,        // 一帧一次的单拍脉冲

    output reg  signed [DW-1:0]  wave_din,
    output reg                   wave_we
);

    //=========================================================================
    // 1. 节拍与相位
    //-----------------------------------------------------------------------------
    // 注意：tick / ph / bar_flat / bar_wr 的【驱动逻辑全部在 §2 那一个 always 块里】。
    //   早期版本这里另有一个“tick 计数 + ph 推进”的 always 块，改写时忘了删，
    //   于是同一个 tick 被两个块驱动 —— 综合报 17 条
    //   [Synth 8-6859] multi-driven net。
    //
    //   ⚠️ 这个错误【iverilog 和 Verible 都没报】：仿真里两个块写同一个 reg
    //      被当成“后写有效”，TB 居然还全过了（因为两个块数 tick 的方式恰好一样）。
    //      **只有综合器抓到了** —— 和账本第 19 条（组合环）同一类教训：
    //      仿真通过 ≠ 设计合法，综合器的 DRC 必须跑。
    //=========================================================================
    reg [TICK_B-1:0] tick;
    reg [5:0]        ph;                        // 包络移动相位（0..63 环绕）

    wire tick_now = (tick == {TICK_B{1'b0}});   // 计满回绕的那一拍

    //=========================================================================
    // 2. 三种图案：**串行生成**
    //-----------------------------------------------------------------------------
    // 【为什么串行，不并行】
    //   第一版写成 `for (bi = 0; bi < 60; bi = bi + 1)` 并行算 60 根柱，
    //   而且包络那支每根柱调了 3 次 tri_peak —— 综合展开后是 180 份三角运算，
    //   实测多耗 **694 个 LUT**。对一个"测试功能"来说完全不成比例。
    //
    //   真实 spectrum 模块也是并行的，但它有 473 LUT 是因为它必须每帧
    //   持续吞吐。演示图案不需要——**60 拍算完一帧绰绰有余**
    //   （48 MHz 下 1.25 us，而更新周期是 2.7 ms）。
    //
    //   串行版只留**一份**运算单元（cdist + 三角 + 模式选择），
    //   结果用 540 位【移位寄存器】拼装：每次左移 9 位、在最低位塞入新柱。
    //   所以从 i = 59 算到 i = 0，最后 bar[0] 正好落在最低位
    //   —— 与 disp_mix 的 `bars[b*HW +: HW]` 取法一致。
    //
    //   代价：540 个 FF（本来就要存 bar_flat）+ 约 80 LUT。
    //   注意重算期间 bar_flat 是中间态，但 bar_wr 只在【全部算完】后
    //   拉高一拍，显示侧只认 bar_wr，所以不会采到半成品。
    //=========================================================================
    localparam ST_IDLE = 1'b0, ST_CALC = 1'b1;
    localparam [TICK_B-1:0] TICK_ONE = 1;      // 见下方“为什么不是 0”

    reg              st;
    reg [5:0]        k;                 // 0..59，对应柱号 i = 59 - k
    reg [1:0]        mode_r;            // 本帧用的 mode（重建开始时锁存）

    wire [5:0]       ii = 6'd59 - k;    // 当前正在算的柱号

    // --- 环形距离：|i - c| 按 64 环绕，结果 0..32。6 位减法自然回绕 + 取绝对值 ---
    function [5:0] cdist;
        input [5:0] i;
        input [5:0] c;
        reg   [5:0] d;
        begin
            d = i - c;
            cdist = d[5] ? (~d + 6'd1) : d;
        end
    endfunction

    // --- 三角形峰：距离越近越高，中心处最高，超出半宽为 0 ---
    function [HW-1:0] tri_peak;
        input [5:0]   i;
        input [5:0]   c;
        input [5:0]   half_w;
        reg   [5:0]   d;
        reg   [HW-1:0] v;
        begin
            d = cdist(i, c);
            if (d < half_w)
                v = (half_w - d) << WS;     // 单语句分支不需要 end
            else
                v = {HW{1'b0}};             // 超出半宽 -> 0
            tri_peak = v;
        end
    endfunction

    // --- 当前柱的高度：模式选择 ---
    reg [HW-1:0] new_bar;
    reg [HW-1:0] tri_a, tri_b;

    always @(*) begin
        tri_a = tri_peak(ii, ph, WV[5:0]);          // 移动的峰
        tri_b = tri_peak(ii, 6'd0, LF_W[5:0]);      // 固定的低频抬升
        case (mode_r)                                // 用锁存值，不用实时 mode
            2'd1:    new_bar = ii << 3;             // T01 斜坡：0, 8, ..., 472
            2'd2:    new_bar = ii[0] ? 9'd448 : 9'd32;  // T02 棋盘
            default: new_bar = (tri_a > tri_b) ? tri_a : tri_b;  // T03 包络
        endcase
    end

    // 本帧是否要跑（用锁存值判，避免中途被关掉导致半帧）
    wire frame_on = (mode_r != 2'd0);

    always @(posedge clk) begin
        if (!rst_n) begin
            st       <= ST_IDLE;
            k        <= 6'd0;
            mode_r   <= 2'd0;
            tick     <= {TICK_B{1'b0}};
            ph       <= 6'd0;
            bar_flat <= {(NBARS*HW){1'b0}};
            bar_wr   <= 1'b0;
        end else begin
            bar_wr <= 1'b0;                         // 默认低，只在算完后拉高一拍

            case (st)
                ST_IDLE: begin
                    if (mode != 2'd0) begin
                        if (tick_now) begin
                            st     <= ST_CALC;
                            k      <= 6'd0;
                            mode_r <= mode;         // 锁存：整帧用同一个模式
                        end else begin
                            tick <= tick + 1'b1;
                        end
                    end
                    // mode=0 时不推进 tick：关掉演示后相位冻结，
                    // 重新打开时不会“跳变”一下
                end

                ST_CALC: begin
                    // 左移 9 位，把刚算好的柱塞进最低位
                    bar_flat <= {bar_flat[NBARS*HW-1-HW:0], new_bar};
                    if (k == NBARS - 1) begin
                        st <= ST_IDLE;
                        // ⚠️ 这里不能写 TICK_ONE 之外的任何值，尤其是 0！
                        //   tick_now 的判据是 tick == 0，如果这里置 0，
                        //   下一拍 tick_now 立刻又为真 -> 变成每 60 拍重算一次
                        //   的连环重建，更新周期从 2.7 ms 掉到 1.25 us。
                        //   而且 frame 会一直处于“重算中”，外部改 mode 时
                        //   会拿到半帧旧图案 + 半帧新图案。
                        tick   <= TICK_ONE;
                        if (frame_on)
                            bar_wr <= 1'b1;         // 60 根全部就位，通知显示侧
                        ph     <= ph + PH_STEP[5:0]; // 相位推进，图案就动起来了
                    end else begin
                        k <= k + 1'b1;
                    end
                end

                default: st <= ST_IDLE;
            endcase
        end
    end

    //=========================================================================
    // 3. 波形：48 kHz 等效速率写中心化三角波
    //    48 MHz / 1000 = 48 kHz —— 和真实采样率完全相同
    //    相位步进 819 -> 周期 65536/819 ≈ 80 个采样 ≈ 600 Hz
    //=========================================================================
    reg [9:0]  wdiv;
    reg [15:0] wph;

    wire w_tick = (wdiv == 10'd999);

    // 三角：把 16 位相位折叠成 0..32767..0，再中心化到 ±16384
    wire [15:0] wfold   = wph[15] ? ~wph : wph;
    wire signed [16:0] wctr = {1'b0, wfold} - 17'sd16384;    // -16384 .. +16383

    always @(posedge clk) begin
        if (!rst_n) begin
            wdiv     <= 10'd0;
            wph      <= 16'd0;
            wave_din <= {DW{1'b0}};
            wave_we  <= 1'b0;
        end else begin
            wave_we <= 1'b0;

            if (w_tick) begin
                wdiv <= 10'd0;
                wph  <= wph + 16'd819;
                // 左移 8 位 -> ±2^22，对应 disp_mix 里 ±16 像素
                wave_din <= wctr <<< 8;
                wave_we  <= 1'b1;
            end else begin
                wdiv <= wdiv + 1'b1;
            end
        end
    end

endmodule
