//=============================================================================
// tb_sd_img_load.v  ——  字节流到像素的搬运验证
//=============================================================================
//   【判据】
//     ① 喂进 2*(W*H) 个字节后，done 必须拉高
//     ② 每个像素的组装必须正确（小端：先来的字节是低位）
//     ③ wr_addr 必须是 0,1,2,... 严格递增，不能跳、不能重
//     ④ 一帧写满后继续喂字节 ⟹ 不能越界写（done 保持、wr_en 不再拉高）
//     ⑤ start 能清计数器（重新来一帧）
//
//   【为什么判据②③要分开】
//     ②验证"数据对不对"，③验证"地址对不对"。
//     两者任何一个是错的，最终画面都会错，但错法完全不同：
//       数据错 ⟹ 画面颜色错乱但形状对
//       地址错 ⟹ 画面整体错位/撕裂
//     分开测能一眼定位。
//=============================================================================

`timescale 1ns / 1ps

module tb_sd_img_load;

    localparam integer W = 32;      // 用小尺寸加快仿真（逻辑与尺寸无关）
    localparam integer H = 8;
    localparam integer DEPTH = W * H;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #10 clk = ~clk;

    reg        start = 1'b0;
    reg        byte_valid = 1'b0;
    reg  [7:0] byte_data = 8'd0;

    wire       wr_en;
    wire [18:0] wr_addr;
    wire [15:0] wr_data;
    wire       done;
    wire [18:0] pix_cnt;

    sd_img_load #(.W(W), .H(H)) dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .start      (start),
        .byte_valid (byte_valid),
        .byte_data  (byte_data),
        .wr_en      (wr_en),
        .wr_addr    (wr_addr),
        .wr_data    (wr_data),
        .done       (done),
        .pix_cnt    (pix_cnt)
    );

    //-------------------------------------------------------------------------
    // 收集写出的像素
    //-------------------------------------------------------------------------
    reg [15:0] got [0:DEPTH-1];
    integer    got_n = 0;
    integer    addr_err = 0;

    always @(posedge clk) begin
        if (wr_en) begin
            if (got_n < DEPTH)
                got[got_n] = wr_data;
            if (wr_addr !== got_n[18:0]) begin
                if (addr_err < 5)
                    $display("  [ERR] 第 %0d 个写：wr_addr=%0d（应为 %0d）",
                             got_n, wr_addr, got_n);
                addr_err = addr_err + 1;
            end
            got_n = got_n + 1;
        end
    end

    // 像素图案：第 i 个像素 = {i[7:0], ~i[7:0]}（高低字节明显不同）
    function [15:0] pat;
        input [18:0] i;
        begin
            pat = {i[7:0], ~i[7:0]};
        end
    endfunction

    integer i;
    integer n_chk = 0;
    integer n_err = 0;
    integer bad = 0;

    task feed_frame;
        begin
            for (i = 0; i < DEPTH; i = i + 1) begin
                // 低字节
                @(posedge clk);
                byte_valid <= 1'b1;
                byte_data  <= pat(i[18:0]) & 16'h00FF;
                @(posedge clk);
                byte_valid <= 1'b0;
                // 高字节
                @(posedge clk);
                byte_valid <= 1'b1;
                byte_data  <= (pat(i[18:0]) >> 8) & 16'h00FF;
                @(posedge clk);
                byte_valid <= 1'b0;
            end
            repeat (10) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_sd_img_load.vcd");
        $dumpvars(0, tb_sd_img_load);

        $display("");
        $display("============================================================");
        $display(" tb_sd_img_load  字节流->像素搬运 (%0dx%0d = %0d 像素)",
                 W, H, DEPTH);
        $display("============================================================");

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;

        // 发一个 start 清计数器
        @(posedge clk); start <= 1'b1;
        @(posedge clk); start <= 1'b0;

        feed_frame;

        //---------------------------------------------------------------------
        // 判据①：done 拉高
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        if (done !== 1'b1) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据①：done 没拉高（pix_cnt=%0d）", pix_cnt);
        end else
            $display("  [ok ] 判据①：done 拉高（pix_cnt=%0d）", pix_cnt);

        //---------------------------------------------------------------------
        // 判据②：像素数值正确
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        bad = 0;
        for (i = 0; i < DEPTH; i = i + 1) begin
            if (i < got_n) begin
                if (got[i] !== pat(i[18:0])) begin
                    if (bad < 5)
                        $display("  [ERR] 判据②：像素 %0d = 0x%04h（应 0x%04h）",
                                 i, got[i], pat(i[18:0]));
                    bad = bad + 1;
                end
            end
        end
        if (bad != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据②：%0d 个像素数值不对", bad);
        end else
            $display("  [ok ] 判据②：%0d 个像素组装正确（小端）", DEPTH);

        //---------------------------------------------------------------------
        // 判据③：地址严格递增
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        if (addr_err != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据③：%0d 处地址不对", addr_err);
        end else
            $display("  [ok ] 判据③：wr_addr 严格 0..%0d 递增", DEPTH - 1);

        //---------------------------------------------------------------------
        // 判据④：写满后继续喂字节，不能越界写
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        begin : overrun
            integer n0;
            n0 = got_n;
            for (i = 0; i < 8; i = i + 1) begin
                @(posedge clk); byte_valid <= 1'b1; byte_data <= 8'hAA;
                @(posedge clk); byte_valid <= 1'b0;
            end
            repeat (5) @(posedge clk);
            if (got_n != n0) begin
                n_err = n_err + 1;
                $display("  [ERR] 判据④：写满后又写了 %0d 个像素（越界）", got_n - n0);
            end else
                $display("  [ok ] 判据④：写满后不再写入（%0d 个像素不变）", got_n);
        end

        //---------------------------------------------------------------------
        // 判据⑤：start 能清计数器
        //---------------------------------------------------------------------
        n_chk = n_chk + 1;
        @(posedge clk); start <= 1'b1;
        @(posedge clk); start <= 1'b0;
        repeat (3) @(posedge clk);
        if ((done !== 1'b0) || (pix_cnt !== 19'd0)) begin
            n_err = n_err + 1;
            $display("  [ERR] 判据⑤：start 没清干净（done=%b pix_cnt=%0d）",
                     done, pix_cnt);
        end else
            $display("  [ok ] 判据⑤：start 把 done/pix_cnt 清零了");

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
