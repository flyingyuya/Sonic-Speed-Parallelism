//=============================================================================
// spectrum_map.v - 频谱柱的 bin 分组表（bar -> 本柱最后一个 bin 编号）
//-----------------------------------------------------------------------------
// ⚠️ 由 scripts/golden/gen_spectrum_map.py 自动生成，请勿手工修改。
//
// 分组方式：
//   柱 0..15    : bin 0..15        （线性，每柱 1 个 bin）
//   柱 16..59   : bin 16 -> 511     （对数均分）
//
//   bin k 的频率 = k x fs/N = k x 48000/1024 = k x 46.875 Hz
//=============================================================================
`timescale 1ns/1ps

module spectrum_map #(
    parameter integer NBARS = 60,
    parameter integer AW    = 6          // 柱编号位宽 = $clog2(NBARS)
) (
    input  wire [AW-1:0]    bar,         // 柱编号 0..NBARS-1
    output reg  [8:0]       last_bin     // 该柱覆盖的最后一个 bin 编号
);

    always @(*) begin
        case (bar)
            6'd0 : last_bin = 9'd0;
            6'd1 : last_bin = 9'd1;
            6'd2 : last_bin = 9'd2;
            6'd3 : last_bin = 9'd3;
            6'd4 : last_bin = 9'd4;
            6'd5 : last_bin = 9'd5;
            6'd6 : last_bin = 9'd6;
            6'd7 : last_bin = 9'd7;
            6'd8 : last_bin = 9'd8;
            6'd9 : last_bin = 9'd9;
            6'd10: last_bin = 9'd10;
            6'd11: last_bin = 9'd11;
            6'd12: last_bin = 9'd12;
            6'd13: last_bin = 9'd13;
            6'd14: last_bin = 9'd14;
            6'd15: last_bin = 9'd15;
            6'd16: last_bin = 9'd16;
            6'd17: last_bin = 9'd18;
            6'd18: last_bin = 9'd19;
            6'd19: last_bin = 9'd21;
            6'd20: last_bin = 9'd23;
            6'd21: last_bin = 9'd25;
            6'd22: last_bin = 9'd27;
            6'd23: last_bin = 9'd29;
            6'd24: last_bin = 9'd32;
            6'd25: last_bin = 9'd34;
            6'd26: last_bin = 9'd37;
            6'd27: last_bin = 9'd40;
            6'd28: last_bin = 9'd44;
            6'd29: last_bin = 9'd47;
            6'd30: last_bin = 9'd51;
            6'd31: last_bin = 9'd55;
            6'd32: last_bin = 9'd60;
            6'd33: last_bin = 9'd65;
            6'd34: last_bin = 9'd70;
            6'd35: last_bin = 9'd76;
            6'd36: last_bin = 9'd83;
            6'd37: last_bin = 9'd90;
            6'd38: last_bin = 9'd97;
            6'd39: last_bin = 9'd105;
            6'd40: last_bin = 9'd114;
            6'd41: last_bin = 9'd123;
            6'd42: last_bin = 9'd133;
            6'd43: last_bin = 9'd144;
            6'd44: last_bin = 9'd156;
            6'd45: last_bin = 9'd169;
            6'd46: last_bin = 9'd183;
            6'd47: last_bin = 9'd198;
            6'd48: last_bin = 9'd214;
            6'd49: last_bin = 9'd232;
            6'd50: last_bin = 9'd251;
            6'd51: last_bin = 9'd272;
            6'd52: last_bin = 9'd294;
            6'd53: last_bin = 9'd318;
            6'd54: last_bin = 9'd344;
            6'd55: last_bin = 9'd373;
            6'd56: last_bin = 9'd403;
            6'd57: last_bin = 9'd436;
            6'd58: last_bin = 9'd472;
            6'd59: last_bin = 9'd511;
            default: last_bin = 9'd0;
        endcase
    end

endmodule
