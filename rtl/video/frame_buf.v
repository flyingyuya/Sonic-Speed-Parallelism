//=============================================================================
// frame_buf.v  ——  一帧图片的帧缓冲（双口 BRAM）
//=============================================================================
//   【为什么需要它】
//     SD 卡的随机访问延迟是毫秒级，而一个像素行只有 20~40 us。
//     所以图片必须【提前整帧搬进快存储器】，显示时再从那里取。
//     这就是账本 380 说的"帧缓冲是扫描式显示加背景图的标准解法"。
//
//   【为什么用 BRAM 而不是 DDR3】
//     480×272×16bit = 2.09 Mbit
//     XC7A100T 的 BRAM 总量 4.86 Mbit（135 块 × 36Kb），当前只用 4 块
//     ⟹ 一帧完全装得下（约 58 块），不需要 MIG/DDR3 那一整套。
//
//   【端口】
//     写口：SD 卡数据流（clk 域），一次写 1 个像素（16 位）
//     读口：显示扫描（clk_pix/clk_hdmi 域），给地址出像素
//
//   ⚠️ 两个口可以是【不同时钟】（简单双口 BRAM 的标准用法）。
//      但写和读不会同时访问同一地址的问题要由上层保证
//      —— 实际上我们只在"搬帧完成后"才让显示去读（由上层用 valid 门控）。
//
//   ⚠️ 读延迟 1 拍：给出 rd_addr 之后的下一个时钟 rd_data 才有效。
//      扫描式显示要提前一拍送地址（disp_mix 里有对应处理）。
//=============================================================================

`timescale 1ns / 1ps

module frame_buf #(
    parameter integer W = 480,          // 帧宽（像素）
    parameter integer H = 272           // 帧高（像素）
) (
    //------------------- 写口（搬帧，通常 clk_sys）-------------------
    input  wire        wr_clk,
    input  wire        wr_en,
    input  wire [18:0] wr_addr,         // 像素线性地址 = y*W + x
    input  wire [15:0] wr_data,         // RGB565

    //------------------- 读口（显示扫描，clk_pix / clk_hdmi）-------------------
    input  wire        rd_clk,
    input  wire [18:0] rd_addr,
    output reg  [15:0] rd_data
);

    localparam integer DEPTH = W * H;

    // 综合器会把这块推成 BRAM（简单双口：一个写口 + 一个读口）
    reg [15:0] mem [0:DEPTH-1];

    always @(posedge wr_clk) begin
        if (wr_en && (wr_addr < DEPTH[18:0]))
            mem[wr_addr] <= wr_data;
    end

    always @(posedge rd_clk) begin
        if (rd_addr < DEPTH[18:0])
            rd_data <= mem[rd_addr];
        else
            rd_data <= 16'd0;
    end

endmodule
