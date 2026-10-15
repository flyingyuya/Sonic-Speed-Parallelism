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
        // ⚠️ BCLK 域的寄存器【必须有复位】。少了这一段，上电时 lr_d / sr / rx_tog
        //    全是 X，而 rx_tog 的 X 会顺着两级同步器传到 clk 域，让 rx_take 变成 X
        //    -> 测试里 `while (!rx_valid)` 在 X 上会【立刻通过】-> 根本等不到数据。
        //    独立 TB 里就是这个症状：读回全 0，而且 adcdat 一直是 x。
        //   ⚠️⚠️ 【rx_tog 也必须复位！】它写的是 `rx_tog <= ~rx_tog`，
        //        而 ~X 还是 X —— 不复位的话它【永远变不成真实值】，
        //        进而让 rx_take / rx_valid 一直是 X。
        //        TB 里 `while (!rx_valid)` 遇到 X 会立刻通过，于是"读回全 0"
        //        看起来像 DUT 坏了，其实是这里漏了一个复位。
        //        （l_acc / r_acc 同理，它们虽然只被赋真值，但上电是 X，
        //          在第一次赋值之前就被读走就是 X。）
        if (!rst_n) begin
            lr_d   <= 1'b0;
            rbit   <= 6'd0;
            sr     <= {DATA_BITS{1'b0}};
            l_acc  <= {DATA_BITS{1'b0}};
            r_acc  <= {DATA_BITS{1'b0}};
            rx_tog <= 1'b0;
        end else begin
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

    // 在 BCLK【下降沿】输出数据：I2S 惯例，发送方在下降沿变、接收方上升沿采。
    //
    //=========================================================================
    // 【为什么要"预测"而不能"检测"】（推时序推出来的，不是调参调出来的）
    //=========================================================================
    //   接收方（真实 WM8960 / TB 的采集器）的行为是固定的：
    //     LRCK 翻转后【第一个上升沿 P1】就把 dacdat 当成新声道的 MSB。
    //     所以发送方必须在【LRCK 翻转那一刻 N0】就把 MSB 放上线。
    //
    //   而 N0 是 negedge。如果 TX 也在 negedge 去比较 LRCK：
    //     产生 LRCK 的方和比较 LRCK 的方【在同一个时间步】——顺序不确定，
    //     实际表现为"在下一个 negedge(N1) 才看到变化" -> 装载晚一整拍
    //     -> 接收方在 P1 采到的是上一路的尾巴 -> 收回的值正好差一位
    //        （实测：喂 0x800000 收回 0x3FFFFF、喂 1111111 收回 555555 = 一半）。
    //
    //   正确做法：
    //     · 用 posedge 采样 LRCK（那时早已稳定，没有竞态）得到换沿事件 P1
    //     · 从 P1 开始用【posedge 计数器】数位下标：P1 就是新声道的第 0 位
    //     · 每个 negedge 输出"下一个 posedge 要采的那一位"
    //       -> 当计数到 SLOT-1（左路最后一位）时，下一个 posedge 就是右路的 MSB，
    //          所以这一拍 negedge 就要把【右路】的 MSB 放上线。帧尾同理。
    //     · 计数器在 posedge 更新、输出在 negedge —— **不同沿，天然无竞态**
    //=========================================================================
    reg  [6:0]      bpos;           // posedge 计数：0 = 换沿后的第 1 个上升沿
    reg             lr_p;
    reg  [SLOT-1:0] tsr;

    wire lr_chg_p = (lrclk ^ lr_p); // 在 posedge 域成立

    always @(posedge bclk) begin
        if (!rst_n) begin
            lr_p <= 1'b0;
            bpos <= 7'd0;
        end else begin
            lr_p <= lrclk;
            // ⚠️ 计数器是【半帧】计数：LRCK 每个半帧就翻一次，
            //    所以每换沿都归零，bpos 只在 0..SLOT-1 之间。
            //    第一版写成 `!= 2*SLOT-1`，结果永远数不到 63
            //    -> 装载条件里的 `bpos == 2*SLOT-1` 从不成立
            //    -> 左声道从来没装载过（实测：L 收回的总是 R 的值）。
            if (lrclk ^ lr_p)          bpos <= 7'd0;
            else if (bpos != SLOT-1)   bpos <= bpos + 7'd1;
        end
    end

    // 本拍之后就要换到哪一路：lrclk=1 表示现在处在【右半帧】，
    //   所以接下来该发的是【左】声道；反之亦然。
    wire signed [DW-1:0] tx_new = lrclk ? tx_l_hold : tx_r_hold;

    always @(negedge bclk) begin
        if (!rst_n) begin
            tsr    <= {SLOT{1'b0}};
            dacdat <= 1'b0;
        end else if (bpos == SLOT-1) begin
            // 下一个 posedge 就是新声道的第 0 位 -> 现在把 MSB 放上线
            dacdat <= tx_new[DW-1];
            tsr    <= {tx_new[DW-2:0], {(SLOT-DW+1){1'b0}}};
        end else begin
            dacdat <= tsr[SLOT-1];
            tsr    <= tsr <<< 1;
        end
    end

    assign dbg_tx_lr = lrclk;

endmodule
