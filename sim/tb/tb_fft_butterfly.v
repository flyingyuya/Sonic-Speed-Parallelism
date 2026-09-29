//=============================================================================
// tb_fft_butterfly.v - 蝶形单元与 Python 定点黄金模型逐位对拍
//-----------------------------------------------------------------------------
// 向量文件 sim/vectors/bf_vec.txt 每行 10 个 hex 字段：
//     ar ai br bi wr wi | pr pi qr qi
//
// 用 $fscanf 读（$readmemh 一个文件只能读一列，这里每行多列）
//=============================================================================
`timescale 1ns/1ps

module tb_fft_butterfly;

    localparam integer DW = 24;
    localparam integer TW = 16;

    reg  signed [DW-1:0] ar, ai, br, bi;
    reg  signed [TW-1:0] wr, wi;
    wire signed [DW-1:0] pr, pi, qr, qi;

    fft_butterfly #(.DW(DW), .TW(TW)) u_dut (
        .ar(ar), .ai(ai), .br(br), .bi(bi), .wr(wr), .wi(wi),
        .pr(pr), .pi(pi), .qr(qr), .qi(qi)
    );

    integer fd;
    integer n    = 0;
    integer errs = 0;

    reg signed [DW-1:0] er, ei, fr, fi;     // 期望值
    integer r;

    initial begin
        $dumpfile("sim/build/tb_fft_butterfly.vcd");
        $dumpvars(0, tb_fft_butterfly);

        $display("=========================================================");
        $display(" fft_butterfly  RTL vs Python 定点黄金模型 逐位对拍");
        $display("   数据 Q1.%0d (%0d bit)   旋转因子 Q1.%0d (%0d bit)",
                 DW-1, DW, TW-1, TW);
        $display("=========================================================");

        fd = $fopen("sim/vectors/bf_vec.txt", "r");
        if (fd == 0) begin
            $display("  [致命] 打不开 sim/vectors/bf_vec.txt");
            $display("         先跑 python3 scripts/golden/gen_fft_butterfly_vec.py");
            $finish;
        end

        //---------------------------------------------------------------------
        // 主循环：读一行 -> 比对一行
        //---------------------------------------------------------------------
        while (!$feof(fd)) begin
            r = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h",
                        ar, ai, br, bi, wr, wi, er, ei, fr, fi);
            if (r == 10) begin
                #1;                     // 等组合逻辑稳定
                n = n + 1;
                if (pr !== er || pi !== ei || qr !== fr || qi !== fi) begin
                    errs = errs + 1;
                    if (errs <= 5) begin
                        $display("  [错] #%0d", n);
                        $display("       in : a=(%0d,%0d) b=(%0d,%0d) W=(%0d,%0d)",
                                 $signed(ar), $signed(ai), $signed(br), $signed(bi),
                                 $signed(wr), $signed(wi));
                        $display("       p  : RTL=(%0d,%0d) 期望=(%0d,%0d)",
                                 $signed(pr), $signed(pi), $signed(er), $signed(ei));
                        $display("       q  : RTL=(%0d,%0d) 期望=(%0d,%0d)",
                                 $signed(qr), $signed(qi), $signed(fr), $signed(fi));
                    end
                end
            end
        end
        $fclose(fd);

        //---------------------------------------------------------------------
        // 汇总
        //---------------------------------------------------------------------
        $display("---------------------------------------------------------");
        $display(" 比对向量数 : %0d", n);
        $display(" 逐位不符数 : %0d", errs);
        if (errs == 0 && n > 0)
            $display(" 结果       : *** PASS ***  RTL 与黄金模型完全一致");
        else
            $display(" 结果       : *** FAIL ***");
        $display("---------------------------------------------------------");
        $finish;
    end

endmodule
