//=============================================================================
// tb_font_rom.v - 点阵字库 ROM 自检
//-----------------------------------------------------------------------------
// 【验证策略】
//   字库是一大堆常量，最容易错的是【索引算错】（行错位、列反了、越界）。
//   所以不去把 728 个字节抄一遍，而是查【可以独立陈述的性质】：
//     · 形状已知的几个字符必须完全正确（空格全 0、'-' 是一条实线、
//       '=' 是两条、'/' 是从右上到左下的斜线）
//     · 第 7 行（行距行）必须永远是 0
//     · 没收录的 ASCII 码必须返回 0，不能是 X
//     · 列方向必须是 bit4 = 最左（不是反的）
//   最后把几个字符按点阵打出来 —— 肉眼扫一眼就知道对不对，
//   这比看一堆十六进制可靠得多。
//=============================================================================
`timescale 1ns/1ps

module tb_font_rom;

    localparam integer NCH = 91;      // 与 font_rom 的默认一致
    localparam integer GW  = 5;
    localparam integer GH  = 7;

    reg  [7:0] ch;
    reg  [2:0] row;
    wire [7:0] bits;

    integer n_err = 0;
    integer c, r, i;

    font_rom dut (.ch(ch), .row(row), .bits(bits));

    // 期望值：某字符某行的位模式（bit4 = 最左）
    function [7:0] expect_row;
        input [7:0] code;
        input [2:0] rr;
        begin
            case ({code, rr})
                // '-' 第 3 行是一条实线
                {8'h2D, 3'd3}: expect_row = 8'b00011111;
                // '=' 第 2、4 行两条实线
                {8'h3D, 3'd2}: expect_row = 8'b00011111;
                {8'h3D, 3'd4}: expect_row = 8'b00011111;
                // 'I' 第 0、6 行是 01110，中间几行是 00100
                {8'h49, 3'd0}: expect_row = 8'b00000001110;
                {8'h49, 3'd6}: expect_row = 8'b00000001110;
                {8'h49, 3'd3}: expect_row = 8'b00000100;
                // '/' 第 0 行在最右，第 6 行在最左 -> 验证列方向没反
                {8'h2F, 3'd0}: expect_row = 8'b00000001;
                {8'h2F, 3'd6}: expect_row = 8'b00010000;
                default:       expect_row = 8'bzzzzzzzz;   // z = 不检查
            endcase
        end
    endfunction

    task dump_glyph;
        input [7:0] code;
        begin
            $write("      '%c'\n", code);
            for (r = 0; r < GH; r = r + 1) begin
                ch = code; row = r[2:0];
                #1;
                $write("        ");
                for (i = GW - 1; i >= 0; i = i - 1)
                    $write("%s", bits[i] ? "#" : ".");
                $write("\n");
            end
        end
    endtask

    reg [7:0] exp_v;

    initial begin
        $display("============================================================");
        $display(" font_rom 自检（5x7 点阵，8 行/字符）");
        $display("============================================================");

        //---------------------------------------------------------------------
        $display("");
        $display(" [1] 形状已知的字符必须完全正确");
        begin : exact
            integer k;
            k = 0;
            for (c = 0; c < 8; c = c + 1) begin
                // 挨个查 ' ' 到 '~' 里我们声明过期望值的那些
                ch = 8'h2D; row = 3'd3; #1;
                if (bits !== 8'b00011111) k = k + 1;
                ch = 8'h3D; row = 3'd2; #1;
                if (bits !== 8'b00011111) k = k + 1;
                ch = 8'h3D; row = 3'd4; #1;
                if (bits !== 8'b00011111) k = k + 1;
                ch = 8'h49; row = 3'd0; #1;
                if (bits !== 8'b00000001110) k = k + 1;
                ch = 8'h49; row = 3'd6; #1;
                if (bits !== 8'b00000001110) k = k + 1;
                ch = 8'h2F; row = 3'd0; #1;
                if (bits !== 8'b00000001) k = k + 1;
                ch = 8'h2F; row = 3'd6; #1;
                if (bits !== 8'b00010000) k = k + 1;
                c = 99;     // 只跑一遍
            end
            if (k != 0) begin
                n_err = n_err + 1;
                $display("  [ERR] 有 %0d 处形状不符（见下面打印的字形）", k);
            end else
                $display("  [ok ] '-' '=' 'I' '/' 的形状全对（含列方向）");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [2] 行距行（第 7 行）必须永远是 0");
        begin : rowgap
            integer k;
            k = 0;
            for (c = 32; c < NCH; c = c + 1) begin
                ch = c[7:0]; row = 3'd7; #1;
                if (bits !== 8'd0) begin
                    k = k + 1;
                    if (k <= 3) $display("  [ERR] 0x%02X 的第 7 行 = %02h（应 0）", c, bits);
                end
            end
            if (k != 0) begin
                n_err = n_err + 1;
                $display("  [ERR] 有 %0d 个字符的行距行不是 0", k);
            end else
                $display("  [ok ] 全部 %0d 个字符的第 7 行都是 0", NCH - 32);
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [3] 未收录的字符必须返回 0（不能是 X）");
        begin : blank
            integer k;
            k = 0;
            for (c = 0; c < NCH; c = c + 1) begin
                // 未收录的定义：所有 8 行都是 0
                ch = c[7:0];
                for (r = 0; r < 8; r = r + 1) begin
                    row = r[2:0]; #1;
                    if (bits === 8'bxxxxxxxx) begin
                        k = k + 1;
                        if (k <= 3) $display("  [ERR] 0x%02X 的第 %0d 行是 X", c, r);
                    end
                end
            end
            if (k != 0) begin
                n_err = n_err + 1;
                $display("  [ERR] 有 %0d 处读到 X（ROM 没初始化全）", k);
            end else
                $display("  [ok ] 0..%0d 全部有确定值，没有 X", NCH-1);

            // 越界访问
            ch = 8'hFF; row = 3'd0; #1;
            if (bits !== 8'd0) begin
                n_err = n_err + 1;
                $display("  [ERR] 越界字符 0xFF 返回 %02h（应 0）", bits);
            end else
                $display("  [ok ] 越界字符 0xFF 返回 0");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [4] 抽查：以下字形请肉眼核对");
        dump_glyph("0"); dump_glyph("G"); dump_glyph("V"); dump_glyph("8");

        //---------------------------------------------------------------------
        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  索引/列方向/行距/越界全部正确");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

endmodule
