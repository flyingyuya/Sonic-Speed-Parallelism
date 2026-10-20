//=============================================================================
// tb_frame_buf.v  ——  frame_buf 自测
//=============================================================================
//   【判据】
//     ① 写进去的每个像素，按相同地址读回来必须完全一致（逐像素）
//     ② 越界地址（>= W*H）不能破坏数据，读回 0
//     ③ 读写用【不同时钟】时仍然正确（双口 BRAM 的关键性质）
//
//   【为什么要测"不同时钟"】
//     实际用法就是：写口在 clk_sys（SD 搬帧），读口在 clk_pix（扫描显示）。
//     如果只用同一个时钟测，就测不出"双口"这个关键性质。
//=============================================================================

`timescale 1ns / 1ps

module tb_frame_buf;

    localparam integer W = 480;
    localparam integer H = 272;
    localparam integer DEPTH = W * H;

    // 写时钟 48 MHz，读时钟 12.5 MHz（和实际用法对应）
    reg wr_clk = 1'b0;
    reg rd_clk = 1'b0;
    always #10  wr_clk = ~wr_clk;      // 50 MHz
    always #40  rd_clk = ~rd_clk;      // 12.5 MHz

    reg         wr_en = 1'b0;
    reg  [18:0] wr_addr = 19'd0;
    reg  [15:0] wr_data = 16'd0;

    reg  [18:0] rd_addr = 19'd0;
    wire [15:0] rd_data;

    frame_buf #(.W(W), .H(H)) dut (
        .wr_clk  (wr_clk),
        .wr_en   (wr_en),
        .wr_addr (wr_addr),
        .wr_data (wr_data),
        .rd_clk  (rd_clk),
        .rd_addr (rd_addr),
        .rd_data (rd_data)
    );

    integer i;
    integer n_chk = 0;
    integer n_err = 0;

    // 像素图案：i 的低 16 位异或一个固定数，保证每个地址都不同
    function [15:0] pat;
        input [18:0] a;
        begin
            pat = {a[18:3], a[2:0]} ^ 16'hA5C3;
        end
    endfunction

    initial begin
        $dumpfile("tb_frame_buf.vcd");
        $dumpvars(0, tb_frame_buf);

        $display("");
        $display("============================================================");
        $display(" tb_frame_buf  双口 BRAM 帧缓冲自测 (%0dx%0d = %0d 像素)",
                 W, H, DEPTH);
        $display("============================================================");

        //---------------------------------------------------------------------
        // 写入整帧（每个地址写不同的图案）
        //---------------------------------------------------------------------
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge wr_clk);
            wr_en   <= 1'b1;
            wr_addr <= i[18:0];
            wr_data <= pat(i[18:0]);
        end
        @(posedge wr_clk);
        wr_en <= 1'b0;
        repeat (4) @(posedge wr_clk);

        $display("  [ok ] 已写入 %0d 个像素", DEPTH);

        //---------------------------------------------------------------------
        // 判据①：逐像素读回比对（用【读时钟】）
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        for (i = 0; i < DEPTH; i = i + 1) begin
            @(posedge rd_clk);
            rd_addr <= i[18:0];
            @(posedge rd_clk);          // 等 BRAM 的 1 拍延迟
            @(negedge rd_clk);
            if (rd_data !== pat(i[18:0])) begin
                if (n_err < 5)
                    $display("  [ERR] 地址 %0d: 读回 0x%04h，应 0x%04h",
                             i, rd_data, pat(i[18:0]));
                n_err = n_err + 1;
            end
        end
        if (n_err == 0)
            $display("  [ok ] 判据①：%0d 个像素逐像素完全一致（读写不同时钟）", DEPTH);
        else
            $display("  [ERR] 判据①：%0d 个像素不对", n_err);

        //---------------------------------------------------------------------
        // 判据②：越界地址读回 0，且不破坏已有数据
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        @(posedge rd_clk); rd_addr <= DEPTH[18:0];       // 越界
        @(posedge rd_clk); @(negedge rd_clk);
        if (rd_data !== 16'd0) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据②：越界地址读回 0x%04h（应 0）", rd_data);
        end else begin
            // 再抽检最后一个合法像素，确认没被越界访问破坏
            @(posedge rd_clk); rd_addr <= (DEPTH - 1);
            @(posedge rd_clk); @(negedge rd_clk);
            if (rd_data !== pat(DEPTH - 1)) begin
                n_err = n_err + 1;
                $display("  [ERR] 判据②：越界访问破坏了最后一个像素");
            end else
                $display("  [ok ] 判据②：越界读回 0，已有数据未受影响");
        end

        //---------------------------------------------------------------------
        // 汇总
        //---------------------------------------------------------------------
        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果: *** PASS ***  (%0d/%0d)", n_chk, n_chk);
        else
            $display(" 结果: *** FAIL ***  (%0d/%0d 失败)", n_err, n_chk);
        $display("------------------------------------------------------------");
        $display("");
        $finish;
    end

endmodule
