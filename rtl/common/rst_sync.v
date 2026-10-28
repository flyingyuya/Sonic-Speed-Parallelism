//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    rst_sync
// Module Name:    rst_sync
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    rst_sync.v - 异步复位、同步释放
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module rst_sync (
    input  wire clk,                    // 目标时钟域
    input  wire rst_async_n,            // 异步复位输入，低有效
    output wire rst_n                   // 同步释放后的复位，低有效
);

    //=========================================================================
    // 两级同步链：异步置位 / 同步释放
    //=========================================================================
    // ASYNC_REG 告诉综合器把这两级放在同一片 SLICE，降低布线延迟
    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_q;

    always @(posedge clk or negedge rst_async_n) begin
        if (!rst_async_n) sync_q <= 2'b00;          // 异步置 0：复位立刻生效
        else              sync_q <= {sync_q[0], 1'b1};  // 逐级移入 1：同步释放
    end

    assign rst_n = sync_q[1];                       // 第二级输出，最稳定

endmodule
