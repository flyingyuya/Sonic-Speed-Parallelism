//////////////////////////////////////////////////////////////////////////////////
// Company:        个人项目 / SonicTwin-Engine
// Engineer:       flyingyu
//
// Create Date:    2026-10-26
// Design Name:    spec_sync
// Module Name:    spec_sync
// Project Name:   音速双擎（SonicTwin-Engine）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    spec_sync.v - 频谱柱高的跨时钟域快照
//                 把 clk_sys 域算出的柱高安全送到 clk_pix 域。
//                 【为什么用异步 FIFO 而不是"数据 + sync 标志"】
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
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
