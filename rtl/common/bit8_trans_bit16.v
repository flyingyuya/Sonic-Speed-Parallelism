//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    bit8_trans_bit16
// Module Name:    bit8_trans_bit16
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    http://xiaomeige.taobao.com
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps


module bit8_trans_bit16(
    input             clk,
    input             reset_p,

    input      [7:0]  bit8_in,
    input             bit8_in_valid,

    output reg [15:0] bit16_out,
    output reg        bit16_out_valid
);

    reg bit8_cnt;

    always@(posedge clk or posedge reset_p)
    begin
        if(reset_p)
        bit8_cnt <= 1'b0;
        else if(bit8_in_valid)
        bit8_cnt <= bit8_cnt + 1'b1;
        else
        bit8_cnt <= bit8_cnt;
    end

    always@(posedge clk or posedge reset_p)
    begin
        if(reset_p)
        bit16_out <= 16'h0000;
        else if(bit8_in_valid)
        bit16_out <= {bit16_out[7:0],bit8_in};
        else
        bit16_out <= bit16_out;
    end

    always@(posedge clk or posedge reset_p)
    begin
        if(reset_p)
        bit16_out_valid <= 1'b0;
        else if(bit8_in_valid && bit8_cnt)
        bit16_out_valid <= 1'b1;
        else
        bit16_out_valid <= 1'b0;
    end

endmodule

