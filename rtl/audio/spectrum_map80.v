//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    spectrum_map80
// Module Name:    spectrum_map80
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    spectrum_map.v - 频谱柱的 bin 分组表（bar -> 本柱最后一个 bin 编号）
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module spectrum_map80 #(
    parameter integer NBARS = 80,
    parameter integer AW    = 7          // 柱编号位宽 = $clog2(NBARS)
) (
    input  wire [AW-1:0]    bar,         // 柱编号 0..NBARS-1
    output reg  [8:0]       last_bin     // 该柱覆盖的最后一个 bin 编号
);

    always @(*) begin
        case (bar)
            7'd0 : last_bin = 9'd0;
            7'd1 : last_bin = 9'd1;
            7'd2 : last_bin = 9'd2;
            7'd3 : last_bin = 9'd3;
            7'd4 : last_bin = 9'd4;
            7'd5 : last_bin = 9'd5;
            7'd6 : last_bin = 9'd6;
            7'd7 : last_bin = 9'd7;
            7'd8 : last_bin = 9'd8;
            7'd9 : last_bin = 9'd9;
            7'd10: last_bin = 9'd10;
            7'd11: last_bin = 9'd11;
            7'd12: last_bin = 9'd12;
            7'd13: last_bin = 9'd13;
            7'd14: last_bin = 9'd14;
            7'd15: last_bin = 9'd15;
            7'd16: last_bin = 9'd16;
            7'd17: last_bin = 9'd17;
            7'd18: last_bin = 9'd18;
            7'd19: last_bin = 9'd19;
            7'd20: last_bin = 9'd20;
            7'd21: last_bin = 9'd21;
            7'd22: last_bin = 9'd22;
            7'd23: last_bin = 9'd24;
            7'd24: last_bin = 9'd25;
            7'd25: last_bin = 9'd26;
            7'd26: last_bin = 9'd28;
            7'd27: last_bin = 9'd30;
            7'd28: last_bin = 9'd31;
            7'd29: last_bin = 9'd33;
            7'd30: last_bin = 9'd35;
            7'd31: last_bin = 9'd37;
            7'd32: last_bin = 9'd39;
            7'd33: last_bin = 9'd41;
            7'd34: last_bin = 9'd44;
            7'd35: last_bin = 9'd46;
            7'd36: last_bin = 9'd49;
            7'd37: last_bin = 9'd52;
            7'd38: last_bin = 9'd55;
            7'd39: last_bin = 9'd58;
            7'd40: last_bin = 9'd61;
            7'd41: last_bin = 9'd64;
            7'd42: last_bin = 9'd68;
            7'd43: last_bin = 9'd72;
            7'd44: last_bin = 9'd76;
            7'd45: last_bin = 9'd80;
            7'd46: last_bin = 9'd85;
            7'd47: last_bin = 9'd90;
            7'd48: last_bin = 9'd95;
            7'd49: last_bin = 9'd100;
            7'd50: last_bin = 9'd105;
            7'd51: last_bin = 9'd111;
            7'd52: last_bin = 9'd118;
            7'd53: last_bin = 9'd124;
            7'd54: last_bin = 9'd131;
            7'd55: last_bin = 9'd139;
            7'd56: last_bin = 9'd146;
            7'd57: last_bin = 9'd155;
            7'd58: last_bin = 9'd163;
            7'd59: last_bin = 9'd172;
            7'd60: last_bin = 9'd182;
            7'd61: last_bin = 9'd192;
            7'd62: last_bin = 9'd203;
            7'd63: last_bin = 9'd214;
            7'd64: last_bin = 9'd226;
            7'd65: last_bin = 9'd239;
            7'd66: last_bin = 9'd252;
            7'd67: last_bin = 9'd266;
            7'd68: last_bin = 9'd281;
            7'd69: last_bin = 9'd297;
            7'd70: last_bin = 9'd313;
            7'd71: last_bin = 9'd331;
            7'd72: last_bin = 9'd349;
            7'd73: last_bin = 9'd369;
            7'd74: last_bin = 9'd390;
            7'd75: last_bin = 9'd411;
            7'd76: last_bin = 9'd434;
            7'd77: last_bin = 9'd458;
            7'd78: last_bin = 9'd484;
            7'd79: last_bin = 9'd511;
            default: last_bin = 9'd0;
        endcase
    end

endmodule
