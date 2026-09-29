//=============================================================================
// spec_sync.v - 频谱柱高的跨时钟域快照
//-----------------------------------------------------------------------------
// 把 clk_sys 域算出的柱高安全送到 clk_pix 域。
//
// 【为什么用异步 FIFO 而不是"数据 + sync 标志"】
//   朴素做法是把 270 位数据当普通信号直接给显示域，再用一个同步过的 toggle
//   告诉它"数据更新了"。功能上能跑，但：
//     · 工具无法判断数据是否稳定，CDC 检查会报一片未约束路径
//     · 数据比标志早到/晚到全靠"物理时序碰巧成立"，没有形式保证
//   走 async_fifo（格雷码指针）就把这件事变成有理论保证的：
//   指针只有 1 位在变，数据在存储体里稳定存放，跨域读到的必然是完整快照。
//
// 【为什么要"持续排空"】
//   音频域约 47 帧/秒写入，显示域 83 帧/秒读取。
//   如果只按显示帧节奏读，FIFO 会积压、显示的是几百毫秒前的旧数据。
//   所以读侧【一直读】，把最新的一直覆盖到 stage，只在帧起始(sof)把它搬进
//   bars。这样显示的永远是最新快照，且帧内不会撕裂。
//=============================================================================
`timescale 1ns/1ps

module spec_sync #(
    parameter integer NBARS = 30,
    parameter integer HW    = 9,
    parameter integer DEPTH = 4          // FIFO 深度（帧级的抖动余量）
) (
    //----------------------- 写侧：clk_sys -----------------------
    input  wire                    wclk,
    input  wire                    wrst_n,
    input  wire                    wr_en,        // = spectrum.frame_done
    input  wire [NBARS*HW-1:0]     din,          // = spectrum.bar_flat
    output wire                    full,

    //----------------------- 读侧：clk_pix -----------------------
    input  wire                    rclk,
    input  wire                    rrst_n,
    input  wire                    sof,          // 帧起始，把最新快照搬进 bars
    output reg  [NBARS*HW-1:0]     bars
);

    localparam integer DW = NBARS * HW;

    // 声明必须在使用之前（Verilog 不允许先用后声明）
    reg           rd_en;
    reg [DW-1:0]  stage;

    wire [DW-1:0] dout;
    wire          empty;

    async_fifo #(.DW(DW), .DEPTH(DEPTH)) u_fifo (
        .wclk     (wclk),
        .wrst_n   (wrst_n),
        .wr_en    (wr_en),
        .din      (din),
        .full     (full),
        .wr_level (),
        .wr_drop  (),
        .rclk     (rclk),
        .rrst_n   (rrst_n),
        .rd_en    (rd_en),
        .dout     (dout),
        .empty    (empty),
        .rd_level ()
    );

    // 持续排空：只要还有数据就弹掉，并把内容搬到 stage
    // （show-ahead FIFO，所以 !empty 时 dout 当拍就有效）
    always @(posedge rclk) begin
        if (!rrst_n) begin
            rd_en <= 1'b0;
            stage <= {DW{1'b0}};
        end else begin
            rd_en <= !empty;
            if (!empty)
                stage <= dout;
        end
    end

    // 帧起始时把最新快照搬进 bars —— 帧内保持不变，避免撕裂
    always @(posedge rclk) begin
        if (!rrst_n)
            bars <= {DW{1'b0}};
        else if (sof)
            bars <= stage;
    end

endmodule
