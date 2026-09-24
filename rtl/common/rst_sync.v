//=============================================================================
// rst_sync.v - 异步复位、同步释放
//-----------------------------------------------------------------------------
// 输入 rst_async_n（来自按键/上电复位，异步），输出 rst_n 在 clk 域同步释放，
// 保证所有触发器在同一个时钟沿退出复位，避免复位撤销时的亚稳态。
//=============================================================================
`timescale 1ns/1ps

module rst_sync (
    input  wire clk,
    input  wire rst_async_n,
    output wire rst_n
);

    (* ASYNC_REG = "TRUE" *) reg [1:0] sync_q;

    always @(posedge clk or negedge rst_async_n) begin
        if (!rst_async_n) sync_q <= 2'b00;
        else              sync_q <= {sync_q[0], 1'b1};
    end

    assign rst_n = sync_q[1];

endmodule
