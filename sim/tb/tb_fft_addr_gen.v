//=============================================================================
// tb_fft_addr_gen.v - 地址发生器穷举自检
//-----------------------------------------------------------------------------
// 【核心思路：参考模型必须用"另一条路径"算，否则是自证】
//
//   RTL 用的   ：位操作（插 0 / 插 1）
//   参考模型用的：除法取模（直接照算法定义写，不做任何位技巧）
//
//   两条路径完全独立，能对上才算真的对。
//
// 【验证内容】
//   1. 穷举 LOG2N=3（8 点，  12 组）  —— 便于手工核对
//   2. 穷举 LOG2N=10（1024 点，5120 组）—— 真实参数
//   3. 额外断言：q 与 p 只差第 stage 位
//=============================================================================
`timescale 1ns/1ps

module tb_fft_addr_gen;

    integer errors = 0;
    integer total  = 0;

    //-------------------------------------------------------------------------
    // 被测模块：两套参数各例化一份
    //-------------------------------------------------------------------------
    reg  [2:0] cnt_small;   reg [3:0] stage_small;
    wire [2:0] p_small, q_small;  wire [1:0] tw_small;

    fft_addr_gen #(.LOG2N(3)) u_dut_small (
        .cnt(cnt_small), .stage(stage_small),
        .p(p_small), .q(q_small), .tw_idx(tw_small)
    );

    reg  [8:0] cnt_big;     reg [3:0] stage_big;
    wire [9:0] p_big, q_big;      wire [8:0] tw_big;

    fft_addr_gen #(.LOG2N(10)) u_dut_big (
        .cnt(cnt_big), .stage(stage_big),
        .p(p_big), .q(q_big), .tw_idx(tw_big)
    );

    //-------------------------------------------------------------------------
    // 参考模型：朴素除法取模，不用任何位技巧
    //-------------------------------------------------------------------------
    task ref_addr;
        input  integer log2n;
        input  integer c;           // cnt
        input  integer s;           // stage
        output integer rp, rq, rt;
        integer half, group, j;
        begin
            half  = 1 << s;
            group = c / half;                   // 组号
            j     = c % half;                   // 组内偏移
            rp    = group * 2 * half + j;
            rq    = rp + half;
            rt    = j * ((1 << log2n) / (2 * half));
        end
    endtask

    //-------------------------------------------------------------------------
    // 比对
    //-------------------------------------------------------------------------
    task check;
        input integer log2n;
        input integer c, s;
        input integer gp, gq, gtw;
        integer rp, rq, rt;
        begin
            ref_addr(log2n, c, s, rp, rq, rt);
            total = total + 1;
            if (gp !== rp || gq !== rq || gtw !== rt) begin
                errors = errors + 1;
                if (errors <= 5)
                    $display("  [错] LOG2N=%0d s=%0d cnt=%0d : RTL=(%0d,%0d,%0d) 参考=(%0d,%0d,%0d)",
                             log2n, s, c, gp, gq, gtw, rp, rq, rt);
            end
        end
    endtask

    //-------------------------------------------------------------------------
    // 主流程
    //-------------------------------------------------------------------------
    integer s, c;
    integer n_bit_diff = 0;

    initial begin
        $dumpfile("sim/build/tb_fft_addr_gen.vcd");
        $dumpvars(0, tb_fft_addr_gen);

        $display("=========================================================");
        $display(" fft_addr_gen 穷举自检");
        $display("   RTL 路径     : 位操作（插 0 / 插 1）");
        $display("   参考模型路径 : 除法取模（算法定义直译）");
        $display("=========================================================");

        //---------------------------------------------------------------------
        // 1) LOG2N = 3（8 点）—— 数据量小，出错时容易肉眼定位
        //---------------------------------------------------------------------
        $display("");
        $display("--- LOG2N=3 (8 点) 穷举，共 3 x 4 = 12 组 ---");
        for (s = 0; s < 3; s = s + 1) begin
            stage_small = s[3:0];
            for (c = 0; c < 4; c = c + 1) begin
                cnt_small = c[2:0];
                #1;                                 // 等组合逻辑稳定
                check(3, c, s, p_small, q_small, tw_small);
                $display("  s=%0d cnt=%0d  p=%2d q=%2d tw=%0d",
                         s, c, p_small, q_small, tw_small);
            end
        end

        //---------------------------------------------------------------------
        // 2) LOG2N = 10（1024 点）—— 真实参数，共 10 x 512 = 5120 组
        //---------------------------------------------------------------------
        $display("");
        $display("--- LOG2N=10 (1024 点) 穷举，共 10 x 512 = 5120 组 ---");
        for (s = 0; s < 10; s = s + 1) begin
            stage_big = s[3:0];
            for (c = 0; c < 512; c = c + 1) begin
                cnt_big = c[8:0];
                #1;
                check(10, c, s, p_big, q_big, tw_big);

                // 额外断言：q 与 p 必须只差第 stage 位
                if ((p_big ^ q_big) !== (10'd1 << s[3:0])) begin
                    n_bit_diff = n_bit_diff + 1;
                    if (n_bit_diff <= 3)
                        $display("  [错] s=%0d cnt=%0d : p^q=%b 期望=%b",
                                 s, c, p_big ^ q_big, (10'd1 << s[3:0]));
                end
            end
        end

        //---------------------------------------------------------------------
        // 汇总
        //---------------------------------------------------------------------
        $display("");
        $display("---------------------------------------------------------");
        $display(" 比对总数       : %0d", total);
        $display(" 地址/索引不符  : %0d", errors);
        $display(" p^q 断言不符   : %0d", n_bit_diff);
        if (errors == 0 && n_bit_diff == 0)
            $display(" 结果           : *** PASS ***");
        else
            $display(" 结果           : *** FAIL ***");
        $display("---------------------------------------------------------");
        $finish;
    end

endmodule
