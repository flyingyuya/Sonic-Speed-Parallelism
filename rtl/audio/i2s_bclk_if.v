//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    i2s_bclk_if
// Module Name:    i2s_bclk_if
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    i2s_bclk_if.v - I2S 接口（以 BCLK 为采样时钟）
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module i2s_bclk_if #(
    parameter integer SLOT      = 32,   // 每声道槽位数
    parameter integer DATA_BITS = 24,   // 有效数据位（槽内高 DATA_BITS 位，左对齐）
    parameter integer DW        = 24    // 样本位宽
) (
    //----------------------- WM8960 侧（BCLK 域）-----------------------
    input  wire                 bclk,       // ← WM8960 输出的位时钟
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

    function signed [DW-1:0] fit;
        input [DATA_BITS-1:0] v;
        begin
            fit = v <<< UP;
        end
    endfunction

    //=========================================================================
    // RX（BCLK 域）
    //=========================================================================
    reg  [5:0]           rbit;
    reg                  lr_d;
    reg  [DATA_BITS-1:0] sr;
    reg  [DATA_BITS-1:0] l_acc, r_acc;
    reg                  rx_tog;

    wire rx_lr_chg = (lrclk ^ lr_d);

    always @(posedge bclk) begin
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
                l_acc <= sr;              // LRCK 低->高：左声道结束
            end else begin
                r_acc <= sr;              // LRCK 高->低：右声道结束 = 一帧结束
                rx_tog <= ~rx_tog;
            end
        end else if (rbit < DATA_BITS[5:0]) begin
            sr   <= {sr[DATA_BITS-2:0], adcdat};
            rbit <= rbit + 6'd1;
        end
        end
    end

    //=========================================================================
    // RX 跨时钟域
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
    // TX（BCLK 域）
    //=========================================================================
    //   数据源在 clk 域：同样用"翻转标志 + 保持"送过来
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

    // 在 BCLK【下降沿】输出数据：I2S 惯例，发送方在下降沿变、接收方上升沿采
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
            // 计数器是【半帧】计数：LRCK 每个半帧就翻一次
            if (lrclk ^ lr_p)          bpos <= 7'd0;
            else if (bpos != SLOT-1)   bpos <= bpos + 7'd1;
        end
    end

    // 本拍之后就要换路：lrclk=1 表示现在处在【右半帧】
    wire signed [DW-1:0] tx_new = lrclk ? tx_l_hold : tx_r_hold;

    always @(negedge bclk) begin
        if (!rst_n) begin
            tsr    <= {SLOT{1'b0}};
            dacdat <= 1'b0;
        end else if (bpos == SLOT-1) begin
            // 下一个 posedge 就是新声道的第 0 位
            dacdat <= tx_new[DW-1];
            tsr    <= {tx_new[DW-2:0], {(SLOT-DW+1){1'b0}}};
        end else begin
            dacdat <= tsr[SLOT-1];
            tsr    <= tsr <<< 1;
        end
    end

    assign dbg_tx_lr = lrclk;

endmodule
