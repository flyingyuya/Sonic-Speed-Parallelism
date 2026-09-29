//=============================================================================
// i2s_slave_clk.v - I2S 从模式时钟恢复（替代 i2s_clkgen）
//-----------------------------------------------------------------------------
// 背景：本工程 WM8960 是 I2S 主（手册 P56：数字音频接口也从 SYSCLK 派生，
//       MCLK 必须与 BCLK/LRCLK 同源）。所以 FPGA 侧只能当从机，
//       BCLK / LRCLK 都是【外部输入】。
//
// 本模块的职责：把外部输入的 BCLK/LRCLK 恢复成 i2s_rx / i2s_tx 需要的那一组
// 选通信号（bclk_rise / bclk_fall / frame_start / half_start / bit_idx），
// **输出契约与 i2s_clkgen 完全一致** —— 所以 i2s_rx / i2s_tx / eq_cascade /
// audio_fifo 一个字都不用改。
//
// 时钟比：clk_sys = 48 MHz，BCLK = 3.072 MHz -> 每个 BCLK 周期约 15.6 个 clk。
//   RX：WM8960 在 BCLK 下降沿更新 ADCDAT，我们在检测到的上升沿采样，
//       数据眼宽约 163 ns，检测偏差最多 1 个 clk（20.8 ns），余量充足。
//   TX：我们在检测到的下降沿更新 SDIN，WM8960 在下一个上升沿采样，
//       仍有约 122 ns 的建立时间。足够。
//
// 【对齐为什么用"电平比较"而不是"边沿检测"】
//   LRCLK 是在 BCLK 下降沿翻转的，和 BCLK 边沿几乎同时到达。
//   如果靠"检测 LRCLK 的跳变沿"来对齐，两个信号各自过同步器时可能落在
//   不同的 clk 周期上（±1 拍竞争），对齐就会整个差一位。
//
//   改用：在【BCLK 上升沿】采样 LRCLK。上升沿位于数据位正中间，
//   此时 LRCLK 已经稳定了半个 BCLK 周期（163 ns），不存在竞争。
//   然后拿采样值和计数器隐含的声道比较，不一致就直接纠正计数器 ——
//   这是纯电平比较，天然免疫 ±1 拍抖动。
//
//   正常工作时 BCLK 和 LRCLK 同源、不会相对漂移，所以纠正只在启动时发生一次。
//=============================================================================
`timescale 1ns/1ps

module i2s_slave_clk #(
    parameter integer SLOT = 32          // 每个声道位数
) (
    input  wire         clk,             // clk_sys = 48 MHz
    input  wire         rst_n,

    input  wire         bclk,            // 来自 WM8960（异步）
    input  wire         lrclk,           // 来自 WM8960（异步）

    // 输出契约与 i2s_clkgen 一致
    output reg          bclk_rise,       // 上升沿选通
    output reg          bclk_fall,       // 下降沿选通
    output wire         frame_start,     // 整帧起点（左声道起点）
    output wire         half_start,      // 右声道起点
    output wire [5:0]   bit_idx,         // 本次上升沿要采样的位下标
    output wire         sample_stb       // 一个立体声帧收齐
);

    localparam integer NFRAME = 2 * SLOT;
    localparam [5:0]   NLAST  = NFRAME - 1;
    localparam [5:0]   HLAST  = SLOT - 1;

    //=========================================================================
    // 1. 输入同步 + 边沿检测
    //    移位寄存器 {sr[1:0], pin}：sr[0] 刚从引脚采进（可能亚稳态），
    //    sr[1] 才是已经稳定下来的同步值，sr[2] 比它再早一拍。
    //    所以边沿检测必须用 sr[1] 与 sr[2]，绝不能用 sr[0]。
    //=========================================================================
    reg [2:0] bclk_sr;
    reg [2:0] lr_sr;

    always @(posedge clk) begin
        if (!rst_n) begin
            bclk_sr <= 3'b000;
            lr_sr   <= 3'b000;
        end else begin
            bclk_sr <= {bclk_sr[1:0], bclk};
            lr_sr   <= {lr_sr[1:0],   lrclk};
        end
    end

    wire bclk_now  = bclk_sr[1];         // 已同步的 BCLK
    wire bclk_prev = bclk_sr[2];
    wire lr_now    = lr_sr[1];           // 已同步的 LRCLK

    wire rise_w =  bclk_now & ~bclk_prev;
    wire fall_w = ~bclk_now &  bclk_prev;

    //=========================================================================
    // 2. 选通输出（与 i2s_clkgen 的时序约定一致）
    //    ⚠️ 必须【先寄存边沿】，再用寄存后的 bclk_rise / bclk_fall 去驱动
    //    计数器和其他一切。第一版用未寄存的 rise_w / fall_w 去更新 bcnt，
    //    而 bclk_fall 要下一拍才为 1 —— 于是 frame_start 判定时 bcnt 已经
    //    自增过了，frame_start / half_start 永远不成立。
    //    i2s_clkgen 里两者是同一个 always 块的同一拍，所以天然一致。
    //=========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            bclk_rise <= 1'b0;
            bclk_fall <= 1'b0;
        end else begin
            bclk_rise <= rise_w;
            bclk_fall <= fall_w;
        end
    end

    //=========================================================================
    // 3. 位计数器（用【寄存后】的选通驱动）
    //=========================================================================
    reg  [5:0] bcnt;
    wire [5:0] bcnt_nxt = (bcnt == NLAST) ? 6'd0 : bcnt + 6'd1;

    // 计数器隐含的声道 = 1 表示右声道
    wire lr_expect = (bcnt >= SLOT);

    // 上升沿做纠正：若采样到的 LRCLK 与计数隐含的声道不符，直接把计数器
    // 拉到该声道的起点。纯电平比较，不受 ±1 拍采样抖动影响。
    wire       misalign = (lr_now != lr_expect);
    wire [5:0] bcnt_fix = lr_now ? SLOT[5:0] : 6'd0;

    always @(posedge clk) begin
        if (!rst_n) begin
            bcnt <= 6'd0;
        end else if (bclk_rise) begin
            if (misalign)
                bcnt <= bcnt_fix;
        end else if (bclk_fall) begin
            bcnt <= bcnt_nxt;
        end
    end

    // bit_idx：本次上升沿要采样的位下标。
    //   若本拍刚好在纠正，则组合地输出纠正后的值，避免错一位。
    assign bit_idx = (bclk_rise && misalign) ? bcnt_fix : bcnt;

    // frame_start / half_start 必须与 bclk_fall 同周期有效
    assign frame_start = bclk_fall & (bcnt == NLAST);
    assign half_start  = bclk_fall & (bcnt == HLAST);

    assign sample_stb  = frame_start;

endmodule
