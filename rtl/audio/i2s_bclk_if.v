//=============================================================================
// i2s_bclk_if.v - I2S 接口（**直接拿 BCLK 当采样时钟**）
//-----------------------------------------------------------------------------
// 【为什么重写】
//   原来用的是 i2s_slave_clk + i2s_rx / i2s_tx 那一套：
//   在 clk_sys(48MHz) 域【过采样】BCLK(3.072MHz)，自己检测边沿、自己纠正帧对齐。
//
//   上板实测（关键证据）：
//     把输入 PGA 完全静音 -> ADC 必然输出恒定的 0 -> FPGA 就该读到 0。
//     实际读到的却是**一串快速跳动的数字**。
//     => 接收器读到的根本不是 ADCDAT 上的电平，而且**收发都坏**
//        （DAC 送测试音也一声不响）。
//
//   过采样那套有太多可以错的地方：边沿检测早/晚一拍、bit_cnt 与真实帧的相位、
//   以及那个"电平纠正"逻辑在什么条件下会反复纠正导致帧永远对不齐。
//   厂商例程（audio_rcv.v）用的是最朴素的写法：**posedge bclk 直接当采样沿**，
//   20 行，没有对齐问题 —— 这才是教科书做法。
//
// 【I2S 时序（本模块实现的）】
//     LRCK 在 BCLK 下降沿翻转；数据在 LRCK 翻转后的**第一个上升沿**开始，
//     MSB 在先。LRCK 低 = 左声道，高 = 右声道。
//     RX：在上升沿采样 ADCDAT。
//     TX：在下降沿更新 DACDAT（接收方在下一个上升沿采）。
//
// 【跨时钟域：翻转标志 + 数据保持】
//   采样率 48kHz、clk_sys 48MHz -> 一帧约 1000 个 clk_sys，
//   数据在整帧内稳定；翻转标志过两级同步器后才被识别，所以数据必然稳定。
//   两端速率严格相同（同一个 BCLK/LRCK 派生），只是相位不同，
//   所以【不需要 FIFO】—— 翻转+保持更省也更简单。
//=============================================================================
`timescale 1ns/1ps

module i2s_bclk_if #(
    parameter integer SLOT      = 32,   // 每声道槽位数
    parameter integer DATA_BITS = 24,   // 有效数据位（槽内高 DATA_BITS 位，左对齐）
    parameter integer DW        = 24    // 样本位宽
) (
    //----------------------- WM8960 侧（BCLK 域）-----------------------
    input  wire                 bclk,       // ← WM8960 输出的位时钟，**当时钟用**
    input  wire                 lrclk,      // ← WM8960 输出的帧时钟
    input  wire                 adcdat,     // ← WM8960 ADCDAT
    output reg                  dacdat,     // → WM8960 DACDAT

    //----------------------- FPGA 侧（clk 域）-----------------------
    input  wire                 clk,        // clk_sys
    input  wire                 rst_n,

    output reg  signed [DW-1:0] rx_l,
    output reg  signed [DW-1:0] rx_r,
    output reg                  rx_valid,   // clk 域单拍脉冲

    input  wire signed [DW-1:0] tx_l,
    input  wire signed [DW-1:0] tx_r,
    input  wire                 tx_en,      // 0 = 发送全 0

    //----------------------- 诊断 -----------------------
    output wire                 dbg_rx_seen,   // 收到过帧（指示 BCLK/LRCK 在动）
    output wire                 dbg_tx_lr      // 当前发送声道（观测用）
);

    localparam integer UP = DW - DATA_BITS;

    // ⚠️ UP 在本工程里是 0（DW=24 == DATA_BITS=24）。
    //    写成 {{UP{1'b0}}, v} 会变成【零宽重复】—— 旧的 i2s_rx 专门用
    //    generate if (UP==0) 绕开它，我这里用左移，UP=0 时天然是原值。
    function signed [DW-1:0] fit;
        input [DATA_BITS-1:0] v;
        begin
            fit = v <<< UP;
        end
    endfunction

    //=========================================================================
    // 1. RX（BCLK 域）
    //=========================================================================
    //   ⚠️ 槽是 SLOT 位（32），有效数据只有 DATA_BITS 位（24）。
    //      "收满 DATA_BITS 位之后必须停止移位"，否则后面那 8 个补零位
    //      会把已经收好的数据冲掉 —— 这是第一版写错的地方。
    reg  [5:0]           rbit;
    reg                  lr_d;
    reg  [DATA_BITS-1:0] sr;
    reg  [DATA_BITS-1:0] l_acc, r_acc;
    reg                  rx_tog;

    wire rx_lr_chg = (lrclk ^ lr_d);

    always @(posedge bclk) begin
        lr_d <= lrclk;

        if (rx_lr_chg) begin
            // 声道切换：上一路刚好收完
            rbit <= 6'd0;
            if (lr_d == 1'b0) begin
                l_acc <= sr;                    // LRCK 低->高：左声道结束
            end else begin
                r_acc <= sr;                    // LRCK 高->低：右声道结束 = 一帧结束
                rx_tog <= ~rx_tog;
            end
        end else if (rbit < DATA_BITS[5:0]) begin
            sr   <= {sr[DATA_BITS-2:0], adcdat};
            rbit <= rbit + 6'd1;
        end
    end

    //=========================================================================
    // 2. RX 跨时钟域
    //=========================================================================
    reg [2:0] tog_s;

    always @(posedge clk) begin
        if (!rst_n) tog_s <= 3'b000;
        else        tog_s <= {tog_s[1:0], rx_tog};
    end

    wire rx_take = (tog_s[2] ^ tog_s[1]);

    always @(posedge clk) begin
        if (!rst_n) begin
            rx_l     <= {DW{1'b0}};
            rx_r     <= {DW{1'b0}};
            rx_valid <= 1'b0;
        end else begin
            rx_valid <= rx_take;
            if (rx_take) begin
                rx_l <= fit(l_acc);
                rx_r <= fit(r_acc);
            end
        end
    end

    assign dbg_rx_seen = rx_take;

    //=========================================================================
    // 3. TX（BCLK 域）
    //=========================================================================
    //   数据源在 clk 域：同样用"翻转标志 + 保持"送过来。
    reg  signed [DW-1:0] tx_l_hold, tx_r_hold;
    reg                  tx_tog;

    always @(posedge clk) begin
        if (!rst_n) begin
            tx_l_hold <= {DW{1'b0}};
            tx_r_hold <= {DW{1'b0}};
            tx_tog    <= 1'b0;
        end else if (tx_en) begin
            tx_l_hold <= tx_l;
            tx_r_hold <= tx_r;
            tx_tog    <= ~tx_tog;
        end
    end

    // 在 BCLK【下降沿】工作：I2S 惯例，发送方在下降沿变、接收方上升沿采。
    reg             tlr_dn;
    reg [SLOT-1:0]  tsr;

    wire tx_lr_chg = (lrclk ^ tlr_dn);

    // 本拍要发送的声道数据
    wire signed [DW-1:0] tx_new = lrclk ? tx_r_hold : tx_l_hold;

    always @(negedge bclk) begin
        tlr_dn <= lrclk;

        if (tx_lr_chg) begin
            // LRCK 刚翻转：这一刻就要立刻呈现【新声道的 MSB】——
            //   I2S 的约定是"LRCK 翻、下一个上升沿接收方就采 MSB"，
            //   所以 MSB 必须在【本次下降沿】就出现在线上了。
            //   剩下的 DW-1 位要【左对齐】放进 32 位移位寄存器的高位区，
            //   这样后面每拍取 tsr[SLOT-1] 就正好是 MSB->LSB 的顺序。
            //   ⚠️ 不能写 `tsr <= data <<< 1` —— data 是 24 位，零扩展后再左移，
            //      最高位会变成 0，等于多发了一个假的 0 位（第一版就是这么错的）。
            dacdat <= tx_new[DW-1];
            tsr    <= {tx_new[DW-2:0], {(SLOT-DW+1){1'b0}}};
        end else begin
            dacdat <= tsr[SLOT-1];
            tsr    <= tsr <<< 1;
        end
    end

    assign dbg_tx_lr = lrclk;

endmodule
