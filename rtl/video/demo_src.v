//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    demo_src
// Module Name:    demo_src
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    demo_src.v - 演示 / 自检图案源
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


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
    // 节拍与相位
    //=========================================================================
    reg [TICK_B-1:0] tick;
    reg [5:0]        ph;                        // 包络移动相位（0..63 环绕）

    wire tick_now = (tick == {TICK_B{1'b0}});   // 计满回绕的那一拍

    //=========================================================================
    // 三种图案：串行生成
    //=========================================================================
    localparam ST_IDLE = 1'b0, ST_CALC = 1'b1;
    localparam [TICK_B-1:0] TICK_ONE = 1;      // 见下方“为什么不是 0”

    reg              st;
    reg [5:0]        k;                 // 0..59，对应柱号 i = 59 - k
    reg [1:0]        mode_r;            // 本帧用的 mode（重建开始时锁存）

    wire [5:0]       ii = 6'd59 - k;    // 当前正在算的柱号

    // 环形距离：|i - c| 按 64 环绕，结果 0..32。6 位减法自然回绕 + 取绝对值
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
            bar_wr <= 1'b0;                        // 默认低，只在算完后拉高一拍

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
                    // mode=0 时不推进 tick：关掉演示后相位冻结
                end

                ST_CALC: begin
                    // 左移 9 位，把刚算好的柱塞进最低位
                    bar_flat <= {bar_flat[NBARS*HW-1-HW:0], new_bar};
                    if (k == NBARS - 1) begin
                        st <= ST_IDLE;
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
    // 波形：48 kHz 等效速率写中心化三角波
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
