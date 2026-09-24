//=============================================================================
// codec_model.v - 行为级 I2S codec 模型（ADC + DAC），供各 testbench 复用
//-----------------------------------------------------------------------------
// ADC 侧：在 BCLK 下降沿按 I2S 时序把 adc_l/adc_r 串行推到 sdin
// DAC 侧：在 BCLK 上升沿从 sdout 采样，整帧结束时拼回 cap_l/cap_r
//
// 注意：本模型的换沿/采样行为与真实 codec 一致（下降沿发送、上升沿采样），
//       因此可以直接用来检查 FPGA 侧的 I2S 时序是否符合标准。
//=============================================================================
`timescale 1ns/1ps

module codec_model #(
    parameter integer DW   = 24,
    parameter integer SLOT = 32
) (
    input  wire clk,
    input  wire rst_n,

    // 来自 i2s_clkgen 的时序信号
    input  wire bclk_rise,
    input  wire bclk_fall,
    input  wire frame_start,
    input  wire [5:0] bit_idx,

    // ADC：要发送的样本
    input  wire signed [DW-1:0] adc_l,
    input  wire signed [DW-1:0] adc_r,
    output wire                 sdin,

    // DAC：收到的样本
    input  wire                 sdout,
    output reg  signed [DW-1:0] cap_l,
    output reg  signed [DW-1:0] cap_r,
    output reg                  cap_valid
);

    localparam integer NFRAME = 2 * SLOT;

    // 本模型假定 DW <= SLOT（24bit 数据装在 32bit 槽的高位）
    initial begin
        if (DW > SLOT) begin
            $display("codec_model: 参数错误 DW(%0d) > SLOT(%0d)", DW, SLOT);
            $finish;
        end
    end

    //-------------------------------------------------------------------------
    // ADC
    //-------------------------------------------------------------------------
    wire [SLOT-1:0]     l_slot = {adc_l, {(SLOT-DW){1'b0}}};
    wire [SLOT-1:0]     r_slot = {adc_r, {(SLOT-DW){1'b0}}};
    wire [NFRAME-1:0]   adc_frame = {l_slot, r_slot};

    reg  [NFRAME-1:0]   adc_sr;
    reg                 sdin_r;

    wire [5:0]          idx_nxt = frame_start ? 6'd0 : (bit_idx + 6'd1);
    wire [NFRAME-1:0]   adc_nxt = frame_start ? adc_frame : adc_sr;

    assign sdin = sdin_r;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            adc_sr <= {NFRAME{1'b0}};
            sdin_r <= 1'b0;
        end else if (bclk_fall) begin
            adc_sr <= adc_nxt;
            sdin_r <= adc_nxt[NFRAME-1 - idx_nxt];
        end
    end

    //-------------------------------------------------------------------------
    // DAC
    //-------------------------------------------------------------------------
    reg  [NFRAME-1:0] dac_sr;
    wire [NFRAME-1:0] dac_nxt = {dac_sr[NFRAME-2:0], sdout};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dac_sr    <= {NFRAME{1'b0}};
            cap_l     <= {DW{1'b0}};
            cap_r     <= {DW{1'b0}};
            cap_valid <= 1'b0;
        end else begin
            cap_valid <= 1'b0;
            if (bclk_rise) begin
                dac_sr <= dac_nxt;
                if (bit_idx == NFRAME-1) begin
                    cap_l     <= dac_nxt[NFRAME-1 -: DW];
                    cap_r     <= dac_nxt[SLOT-1   -: DW];
                    cap_valid <= 1'b1;
                end
            end
        end
    end

endmodule
