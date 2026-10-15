//=============================================================================
// codec_model.v - 行为级 I2S codec 模型（ADC + DAC）
//-----------------------------------------------------------------------------
// 【2026-10 改写：只看 bclk / lrclk 两个真实引脚】
//   旧版吃 i2s_slave_clk 派生的 bclk_rise/bclk_fall/frame_start/bit_idx。
//   audio_top 换成 i2s_bclk_if 之后那些信号不存在了。
//
// 【时序】LRCK 在 BCLK 下降沿翻转；低=左，高=右。
//   ADC（发送）：下降沿更新 sdin，MSB 在换沿后第一个上升沿有效。
//   DAC（接收）：上升沿采样 sdout。
//=============================================================================
`timescale 1ns/1ps

module codec_model #(
    parameter integer DW   = 24,
    parameter integer SLOT = 32
) (
    input  wire clk,
    input  wire rst_n,
    input  wire bclk,
    input  wire lrclk,

    input  wire signed [DW-1:0] adc_l,
    input  wire signed [DW-1:0] adc_r,
    output reg                  sdin,

    input  wire                 sdout,
    output reg  signed [DW-1:0] cap_l,
    output reg  signed [DW-1:0] cap_r,
    output reg                  cap_valid
);

    localparam integer PAD = SLOT - DW;

    //----------------- ADC（发送，下降沿更新）-----------------
    reg [SLOT-1:0] ash  = {SLOT{1'b0}};
    reg            lr_d = 1'b0;
    wire            adc_lr_chg = (lrclk ^ lr_d);
    // 换沿那一刻：lrclk=0（H->L，帧起点）接下来发左 -> else 装 adc_l
    wire [SLOT-1:0] tx_new = lrclk ? {adc_r, {PAD{1'b0}}} : {adc_l, {PAD{1'b0}}};

    always @(negedge bclk or negedge rst_n) begin
        if (!rst_n) begin
            lr_d <= 1'b0; ash <= {SLOT{1'b0}}; sdin <= 1'b0;
        end else begin
            lr_d <= lrclk;
            if (adc_lr_chg) begin
                sdin <= tx_new[SLOT-1];
                ash  <= {tx_new[SLOT-2:0], 1'b0};
            end else begin
                sdin <= ash[SLOT-1];
                ash  <= {ash[SLOT-2:0], 1'b0};
            end
        end
    end

    //----------------- DAC（接收，上升沿采样）-----------------
    reg [SLOT-1:0] dsh  = {SLOT{1'b0}};
    reg            lr_r = 1'b0;
    wire dac_lr_chg = (lrclk ^ lr_r);

    always @(posedge bclk or negedge rst_n) begin
        if (!rst_n) begin
            lr_r <= 1'b0; dsh <= {SLOT{1'b0}};
            cap_l <= {DW{1'b0}}; cap_r <= {DW{1'b0}}; cap_valid <= 1'b0;
        end else begin
            lr_r <= lrclk; cap_valid <= 1'b0;
            if (dac_lr_chg) begin
                if (lr_r == 1'b0) cap_l <= dsh[SLOT-1 -: DW];
                else begin cap_r <= dsh[SLOT-1 -: DW]; cap_valid <= 1'b1; end
                dsh <= {{(SLOT-1){1'b0}}, sdout};
            end else dsh <= {dsh[SLOT-2:0], sdout};
        end
    end

endmodule
