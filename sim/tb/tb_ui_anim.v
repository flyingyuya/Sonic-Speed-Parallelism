//=============================================================================
// tb_ui_anim.v - ui_anim 属性插值器自检
//-----------------------------------------------------------------------------
// 查的是【性质】，不是把 RTL 的加减法抄一遍：
//   ① 复位后全 0
//   ② target=1 -> 单调升到 FULL 就停住（既不回绕，也不超过 FULL）
//   ③ target=0 -> 单调降到 0 就停住（不变成负数/255）
//   ④ 只在 frame 那一拍变化（frame 不来就不动）
//   ⑤ 过渡帧数正好是 FULL/STEP
//   ⑥ 中途反向：升到一半改目标，必须立刻掉头
//=============================================================================
`timescale 1ns/1ps

module tb_ui_anim;

    localparam integer NCH  = 3;
    localparam integer FULL = 128;
    localparam integer STEP = 4;

    reg                clk = 0;
    reg                rst_n = 0;
    reg                frame = 0;
    reg  [NCH-1:0]     target = 3'b000;
    wire [NCH*8-1:0]   level;

    integer n_err = 0;
    integer i, k;
    integer prev, cur, frames;

    ui_anim #(.NCH(NCH), .FULL(FULL), .STEP(STEP)) dut (
        .clk(clk), .rst_n(rst_n), .frame(frame),
        .target(target), .level(level)
    );

    always #10.4167 clk = ~clk;      // 48 MHz 大致

    // 发一个 frame 脉冲（恰好一个时钟周期宽）
    //
    // ⚠️ 必须在【下降沿】驱动 frame。
    //   第一版写成 `@(posedge clk); frame = 1'b1; @(posedge clk); frame = 1'b0;`
    //   —— 赋值紧跟在同一个 posedge 之后，和 DUT 里 `always @(posedge clk)`
    //   采样 frame 处在同一时刻的竞争区，结果是【有时采到、有时采不到】，
    //   表现为"升到 128 只用了 17 帧"（一会儿走 1 步、一会儿走 2 步）和
    //   "改目标后一步没走"。这类"两边差一拍"的坑本工程已经踩过多次
    //   （账本 23/25/28/32），这次是【竞态导致步数随机】的变体。
    //   在 negedge 驱动就与 DUT 的采样沿彻底错开，一个脉冲 = 恰好一次更新。
    task do_frame;
        begin
            @(negedge clk);
            frame = 1'b1;
            @(negedge clk);
            frame = 1'b0;
        end
    endtask

    function [7:0] lv;
        input integer c;
        begin
            lv = level[c*8 +: 8];
        end
    endfunction

    // ⚠️ 不要用 `task check(input [255:0] name)` 来传消息：
    //   iverilog 对过宽的中文字符串参数处理有问题，打印出来全是乱码，
    //   而且会让人怀疑判据本身。Verilog-2001 里传字符串就用宏。
`define CHK(cond, msg) \
        if (cond) $display("  [ok ] %0s", msg); \
        else begin n_err = n_err + 1; $display("  [ERR] %0s", msg); end

    initial begin
        $display("============================================================");
        $display(" ui_anim 自检（属性插值器）");
        $display("  NCH=%0d  FULL=%0d  STEP=%0d  -> 过渡 %0d 帧",
                 NCH, FULL, STEP, FULL/STEP);
        $display("============================================================");

        rst_n = 0;
        repeat (10) @(posedge clk);
        rst_n = 1;

        //---------------------------------------------------------------------
        $display("");
        $display(" [1] 复位后全为 0");
        k = 0;
        for (i = 0; i < NCH; i = i + 1) if (lv(i) !== 8'd0) k = k + 1;
        `CHK(k == 0, "三个通道复位后都是 0");

        //---------------------------------------------------------------------
        $display("");
        $display(" [2] target=1：单调升到 FULL 就停住");
        target = 3'b111;
        // 先确认 frame 不来就不动
        prev = lv(0);
        repeat (500) @(posedge clk);        // 不发 frame
        `CHK(lv(0) === prev, "没有 frame 时 level 完全不动（帧门控生效）");

        // 逐帧升，检查单调 + 不超上限
        k = 0; frames = 0;
        while (lv(0) < FULL && frames < 200) begin
            prev = lv(0);
            do_frame();
            cur = lv(0);
            if (cur < prev) k = k + 1;                  // 不能掉头
            if (cur > FULL) k = k + 1;                  // 不能超上限
            frames = frames + 1;
        end
        `CHK(k == 0, "上升过程单调、不超 FULL");
        `CHK(frames == FULL/STEP, "上升用了 FULL/STEP 帧（过渡时长正确）");
        if (frames != FULL/STEP) $display("        （实际用了 %0d 帧，期望 %0d）", frames, FULL/STEP);
        `CHK(lv(0) === FULL[7:0], "最终停在 FULL（128），没有回绕到 0");

        // 再多送几帧，必须稳在 FULL
        repeat (5) do_frame();
        `CHK(lv(0) === FULL[7:0] && lv(1) === FULL[7:0] &&
             lv(2) === FULL[7:0], "继续送 frame 仍稳在 FULL");

        //---------------------------------------------------------------------
        $display("");
        $display(" [3] target=0：单调降到 0 就停住");
        target = 3'b000;
        k = 0; frames = 0;
        while (lv(0) > 0 && frames < 200) begin
            prev = lv(0);
            do_frame();
            cur = lv(0);
            if (cur > prev) k = k + 1;                  // 不能掉头
            frames = frames + 1;
        end
        `CHK(k == 0, "下降过程单调");
        `CHK(frames == FULL/STEP, "下降也用了 FULL/STEP 帧");
        if (frames != FULL/STEP) $display("        （实际用了 %0d 帧）", frames);
        `CHK(lv(0) === 8'd0, "最终停在 0，没有下溢成 255");

        repeat (5) do_frame();
        `CHK(lv(0) === 8'd0 && lv(1) === 8'd0 && lv(2) === 8'd0, "继续送 frame 仍稳在 0（下限钳位正确）");

        //---------------------------------------------------------------------
        $display("");
        $display(" [4] 各通道独立");
        target = 3'b001;
        repeat (FULL/STEP + 4) do_frame();
        `CHK(lv(0) === FULL[7:0] && lv(1) === 8'd0 && lv(2) === 8'd0, "只有通道 0 展开，1/2 保持 0（通道互不干扰）");

        //---------------------------------------------------------------------
        $display("");
        $display(" [5] 中途反向：升到一半改目标，必须立刻掉头");
        target = 3'b000;
        repeat (FULL/STEP + 4) do_frame();              // 先全部归零

        target = 3'b001;
        repeat (FULL/STEP/2) do_frame();                // 升到一半
        prev = lv(0);
        `CHK(prev > 0 && prev < FULL, "确实升到了中途（既不是 0 也不是满）");

        target = 3'b000;                                // 掉头
        do_frame();
        cur = lv(0);
        `CHK(cur < prev, "改目标后立刻开始下降（没有惯性/延迟）");
        if (!(cur < prev)) $display("        （prev=%0d cur=%0d target=%b）", prev, cur, target);

        k = 0;
        while (lv(0) > 0 && k < 200) begin
            prev = lv(0);
            do_frame();
            if (lv(0) > prev) k = k + 1;
        end
        `CHK(k == 0 && lv(0) === 8'd0, "反向过程单调且能归零");

        //---------------------------------------------------------------------
        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  插值单调、上下限正确、帧门控生效");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

    initial begin
        #5_000_000;
        $display("  [ERR] 超时");
        $display(" 结果       : *** FAIL ***  超时");
        $finish;
    end

endmodule
