//=============================================================================
// fft_addr_gen.v - FFT 蝶形地址与旋转因子索引生成（纯组合逻辑）
//-----------------------------------------------------------------------------
// 功能：给定"第几级(s)"和"本级第几个蝶形(cnt)"，算出：
//         p      —— 蝶形第一个点的 BRAM 地址
//         q      —— 蝶形第二个点的 BRAM 地址
//         tw_idx —— 该蝶形要用的旋转因子在 ROM 里的索引
//
// 【算法依据】见 docs/11-fft-design.md §4
//
//   把 cnt 拆成：  [ 高 (LOG2N-1-s) 位：组号 group ][ 低 s 位：组内偏移 j ]
//
//   朴素写法（硬件上要除法器，太贵）：
//       half  = 1 << s
//       group = cnt / half
//       j     = cnt % half
//       p     = group * 2 * half + j
//       q     = p + half
//       tw    = j << (LOG2N-1-s)
//
//   本模块用的位操作写法（只要移位器，等价但便宜几十倍）：
//       p = 把 cnt 的高位左移一格、第 s 位补 0、低 s 位不变   ← "插 0"
//       q = 把 p 的第 s 位置 1                              ← "插 1"
//       tw= j 左移 (LOG2N-1-s)
//
//   ★ 关键结论：p 和 q 只差第 s 位。这是整个地址发生器的精髓。
//
// 【参数化说明】
//   LOG2N 可配，方便用小点数（如 8 点）做穷举自检。
//   LOG2N=10 → 1024 点：cnt 9 位、p/q 10 位、tw_idx 9 位
//   LOG2N= 3 →    8 点：cnt 2 位、p/q  3 位、tw_idx 2 位
//
// 【时序】
//   纯组合，无时钟。综合后是一堆移位器和位或 —— 桶形移位器由综合器自动生成。
//=============================================================================
`timescale 1ns/1ps

module fft_addr_gen #(
    parameter integer LOG2N = 10            // N = 2^LOG2N
) (
    input  wire [LOG2N-2:0]  cnt,           // 蝶形编号 0 .. N/2-1
    input  wire [3:0]        stage,         // 当前级数 0 .. LOG2N-1
    output wire [LOG2N-1:0]  p,             // 蝶形第一个点地址
    output wire [LOG2N-1:0]  q,             // 蝶形第二个点地址
    output wire [LOG2N-2:0]  tw_idx         // 旋转因子 ROM 索引
);

    // 常量 1
    localparam [LOG2N-1:0] ONE = {{(LOG2N-1){1'b0}}, 1'b1};

    // 移位量用 5 位宽：避免 stage = 15 时 stage+1 溢出成 0。
    wire [4:0] stage_w = {1'b0, stage};
    wire [4:0] sh_p    = stage_w + 5'd1;                    // = stage + 1
    wire [4:0] sh_tw   = LOG2N[4:0] - 5'd1 - stage_w;       // = LOG2N - 1 - stage

    // 低 stage 位掩码
    wire [LOG2N-1:0] lo_mask = (ONE << stage_w) - ONE;

    // cnt 扩位
    wire [LOG2N-1:0] cnt_x = {1'b0, cnt};

    // 插 0：高位左移一格，第 stage 位补 0，低位不变
    assign p = ((cnt_x >> stage_w) << sh_p) | (cnt_x & lo_mask);

    // 插 1：高位左移一格，第 stage 位补 0，低位不变
    assign q = p | (ONE << stage_w);

    // 旋转因子索引  tw_idx = j << (LOG2N - 1 - stage)
    assign tw_idx = (cnt & lo_mask[LOG2N-2:0]) << sh_tw;

endmodule
