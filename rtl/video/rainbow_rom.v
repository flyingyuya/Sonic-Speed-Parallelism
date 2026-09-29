//=============================================================================
// rainbow_rom.v - 彩虹颜色表（128 级 RGB888）
//-----------------------------------------------------------------------------
// ⚠️ 由 scripts/golden/gen_rainbow.py 自动生成，请勿手工修改。
//
// 配色：HSL(H, S=0.85, L=0.6)，H = 0..360 均分 128 级
//   H=0 -> 红   H=1/3 -> 绿   H=2/3 -> 蓝   循环回红
//   这个公式是从参考工程 Music-Spectrum 的 RGB565 表反推验证出来的：
//   它的 rom[0] = 16'b11110_010000_01000 = (30,16,8)，
//   恰好等于 HSL(0, 0.85, 0.6) 量化到 RGB565 的结果。
//
// 地址是【循环】的：调用方对 128 取模即可实现彩虹滚动效果。
//=============================================================================
`timescale 1ns/1ps

module rainbow_rom (
    input  wire [6:0]   addr,       // 0..127
    output reg  [23:0]  rgb         // {R[7:0], G[7:0], B[7:0]}
);

    always @(*) begin
        case (addr)
            7'd0  : rgb = 24'hF04242;
            7'd1  : rgb = 24'hF04A42;
            7'd2  : rgb = 24'hF05342;
            7'd3  : rgb = 24'hF05B42;
            7'd4  : rgb = 24'hF06342;
            7'd5  : rgb = 24'hF06B42;
            7'd6  : rgb = 24'hF07342;
            7'd7  : rgb = 24'hF07B42;
            7'd8  : rgb = 24'hF08342;
            7'd9  : rgb = 24'hF08B42;
            7'd10 : rgb = 24'hF09442;
            7'd11 : rgb = 24'hF09C42;
            7'd12 : rgb = 24'hF0A442;
            7'd13 : rgb = 24'hF0AC42;
            7'd14 : rgb = 24'hF0B442;
            7'd15 : rgb = 24'hF0BC42;
            7'd16 : rgb = 24'hF0C442;
            7'd17 : rgb = 24'hF0CC42;
            7'd18 : rgb = 24'hF0D542;
            7'd19 : rgb = 24'hF0DD42;
            7'd20 : rgb = 24'hF0E542;
            7'd21 : rgb = 24'hF0ED42;
            7'd22 : rgb = 24'hEAF042;
            7'd23 : rgb = 24'hE2F042;
            7'd24 : rgb = 24'hDAF042;
            7'd25 : rgb = 24'hD2F042;
            7'd26 : rgb = 24'hCAF042;
            7'd27 : rgb = 24'hC2F042;
            7'd28 : rgb = 24'hBAF042;
            7'd29 : rgb = 24'hB1F042;
            7'd30 : rgb = 24'hA9F042;
            7'd31 : rgb = 24'hA1F042;
            7'd32 : rgb = 24'h99F042;
            7'd33 : rgb = 24'h91F042;
            7'd34 : rgb = 24'h89F042;
            7'd35 : rgb = 24'h81F042;
            7'd36 : rgb = 24'h78F042;
            7'd37 : rgb = 24'h70F042;
            7'd38 : rgb = 24'h68F042;
            7'd39 : rgb = 24'h60F042;
            7'd40 : rgb = 24'h58F042;
            7'd41 : rgb = 24'h50F042;
            7'd42 : rgb = 24'h48F042;
            7'd43 : rgb = 24'h42F045;
            7'd44 : rgb = 24'h42F04D;
            7'd45 : rgb = 24'h42F055;
            7'd46 : rgb = 24'h42F05D;
            7'd47 : rgb = 24'h42F066;
            7'd48 : rgb = 24'h42F06E;
            7'd49 : rgb = 24'h42F076;
            7'd50 : rgb = 24'h42F07E;
            7'd51 : rgb = 24'h42F086;
            7'd52 : rgb = 24'h42F08E;
            7'd53 : rgb = 24'h42F096;
            7'd54 : rgb = 24'h42F09E;
            7'd55 : rgb = 24'h42F0A7;
            7'd56 : rgb = 24'h42F0AF;
            7'd57 : rgb = 24'h42F0B7;
            7'd58 : rgb = 24'h42F0BF;
            7'd59 : rgb = 24'h42F0C7;
            7'd60 : rgb = 24'h42F0CF;
            7'd61 : rgb = 24'h42F0D7;
            7'd62 : rgb = 24'h42F0DF;
            7'd63 : rgb = 24'h42F0E8;
            7'd64 : rgb = 24'h42F0F0;
            7'd65 : rgb = 24'h42E8F0;
            7'd66 : rgb = 24'h42DFF0;
            7'd67 : rgb = 24'h42D7F0;
            7'd68 : rgb = 24'h42CFF0;
            7'd69 : rgb = 24'h42C7F0;
            7'd70 : rgb = 24'h42BFF0;
            7'd71 : rgb = 24'h42B7F0;
            7'd72 : rgb = 24'h42AFF0;
            7'd73 : rgb = 24'h42A7F0;
            7'd74 : rgb = 24'h429EF0;
            7'd75 : rgb = 24'h4296F0;
            7'd76 : rgb = 24'h428EF0;
            7'd77 : rgb = 24'h4286F0;
            7'd78 : rgb = 24'h427EF0;
            7'd79 : rgb = 24'h4276F0;
            7'd80 : rgb = 24'h426EF0;
            7'd81 : rgb = 24'h4266F0;
            7'd82 : rgb = 24'h425DF0;
            7'd83 : rgb = 24'h4255F0;
            7'd84 : rgb = 24'h424DF0;
            7'd85 : rgb = 24'h4245F0;
            7'd86 : rgb = 24'h4842F0;
            7'd87 : rgb = 24'h5042F0;
            7'd88 : rgb = 24'h5842F0;
            7'd89 : rgb = 24'h6042F0;
            7'd90 : rgb = 24'h6842F0;
            7'd91 : rgb = 24'h7042F0;
            7'd92 : rgb = 24'h7842F0;
            7'd93 : rgb = 24'h8142F0;
            7'd94 : rgb = 24'h8942F0;
            7'd95 : rgb = 24'h9142F0;
            7'd96 : rgb = 24'h9942F0;
            7'd97 : rgb = 24'hA142F0;
            7'd98 : rgb = 24'hA942F0;
            7'd99 : rgb = 24'hB142F0;
            7'd100: rgb = 24'hBA42F0;
            7'd101: rgb = 24'hC242F0;
            7'd102: rgb = 24'hCA42F0;
            7'd103: rgb = 24'hD242F0;
            7'd104: rgb = 24'hDA42F0;
            7'd105: rgb = 24'hE242F0;
            7'd106: rgb = 24'hEA42F0;
            7'd107: rgb = 24'hF042ED;
            7'd108: rgb = 24'hF042E5;
            7'd109: rgb = 24'hF042DD;
            7'd110: rgb = 24'hF042D5;
            7'd111: rgb = 24'hF042CC;
            7'd112: rgb = 24'hF042C4;
            7'd113: rgb = 24'hF042BC;
            7'd114: rgb = 24'hF042B4;
            7'd115: rgb = 24'hF042AC;
            7'd116: rgb = 24'hF042A4;
            7'd117: rgb = 24'hF0429C;
            7'd118: rgb = 24'hF04294;
            7'd119: rgb = 24'hF0428B;
            7'd120: rgb = 24'hF04283;
            7'd121: rgb = 24'hF0427B;
            7'd122: rgb = 24'hF04273;
            7'd123: rgb = 24'hF0426B;
            7'd124: rgb = 24'hF04263;
            7'd125: rgb = 24'hF0425B;
            7'd126: rgb = 24'hF04253;
            7'd127: rgb = 24'hF0424A;
            default: rgb = 24'h000000;
        endcase
    end

endmodule
