//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    cdc_sync
// Module Name:    cdc_sync
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    cdc_sync.v - 多比特/单比特电平信号跨时钟域同步（两级触发器）
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module cdc_sync #(
    parameter integer WIDTH     = 1,
    parameter integer STAGES    = 2,
    parameter [WIDTH-1:0] RESET_VAL = {WIDTH{1'b0}}
) (
    input  wire             clk,
    input  wire             rst_n,
    input  wire [WIDTH-1:0] din,
    output wire [WIDTH-1:0] dout
);

    (* ASYNC_REG = "TRUE" *) reg [WIDTH-1:0] sync_q [0:STAGES-1];
    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin
            for (i = 0; i < STAGES; i = i + 1)
                sync_q[i] <= RESET_VAL;
        end else begin
            sync_q[0] <= din;
            for (i = 1; i < STAGES; i = i + 1)
                sync_q[i] <= sync_q[i-1];
        end
    end

    assign dout = sync_q[STAGES-1];

endmodule


//=============================================================================
// 边沿检测：对 cdc_sync 后的信号做上升/下降沿检测（输出 1 个 clk 宽脉冲）
//=============================================================================
module cdc_edge #(
    parameter integer STAGES = 2
) (
    input  wire clk,
    input  wire rst_n,
    input  wire din,
    output wire rise,
    output wire fall
);

    wire d;
    reg  d_d;

    cdc_sync #(.WIDTH(1), .STAGES(STAGES)) u_sync (
        .clk(clk), .rst_n(rst_n), .din(din), .dout(d)
    );

    always @(posedge clk) begin
        if (!rst_n) d_d <= 1'b0;
        else        d_d <= d;
    end

    assign rise = d & ~d_d;
    assign fall = ~d & d_d;

endmodule
