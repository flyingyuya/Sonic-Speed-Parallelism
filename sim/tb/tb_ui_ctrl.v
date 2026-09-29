//=============================================================================
// tb_ui_ctrl.v - 按键消抖 + 配置寄存器组验证
//-----------------------------------------------------------------------------
// 这两个模块是一起用的（按键 -> 消抖 -> 寄存器组），所以放一个 TB 里测。
//
// 检查项：
//   ① 消抖效果     给一个**带抖动的**按键波形，只能识别出 1 次按下
//                   （真实按键按下瞬间会抖动几毫秒，不消抖会当成几十次）
//   ② 短按不误判   抖动持续时间小于消抖窗口时，不产生任何脉冲
//   ③ 松手也消抖   松开时的抖动也不能产生额外的"按下"
//   ④ 默认值       上电后寄存器组必须是约定的默认值
//   ⑤ 统一写端口   写各地址要落到对应寄存器，未定义地址忽略
//   ⑥ 视图轮转     next_view 必须按预设表循环，包含回绕
//   ⑦ 自动循环     开 AUTO 后应当自动切视图
//   ⑧ 直写 VIEW 后 下一次 next_view 不能跳号（view_idx 要跟着对齐）
//=============================================================================
`timescale 1ns / 1ps

`include "disp_cfg.vh"

module tb_ui_ctrl;

    localparam integer CLK_HZ = 1_000_000;      // 用 1 MHz，消抖窗口小、跑得快
    localparam integer MS     = 1;       // 真实用 20ms；测试只需 1ms，快 20 倍
    localparam integer CNT_MAX = CLK_HZ / 1000 * MS;   // 20000

    reg clk = 0, rst_n = 0;
    always #500 clk = ~clk;                     // 1 MHz

    //=========================================================================
    // 按键消抖
    //=========================================================================
    reg  key_n = 1'b1;
    wire kp, press;

    key_debounce #(.CLK_HZ(CLK_HZ), .MS(MS)) u_kd (
        .clk(clk), .rst_n(rst_n), .key_n(key_n),
        .key_pressed(kp), .press(press)
    );

    //=========================================================================
    // 配置寄存器组（自动循环周期设小，便于测）
    //=========================================================================
    reg        wr_en   = 0;
    reg  [3:0] wr_addr = 0;
    reg  [7:0] wr_data = 0;
    reg        next_view = 0;

    wire [7:0] cfg_view, cfg_style, cfg_hue_spd, cfg_wave_gain, cfg_bg_mode, cfg_auto;
    wire [3:0] view_idx;

    ui_ctrl #(.AUTO_PERIOD(1000)) u_ui (
        .clk(clk), .rst_n(rst_n),
        .wr_en(wr_en), .wr_addr(wr_addr), .wr_data(wr_data),
        .next_view(next_view),
        .cfg_view(cfg_view), .cfg_style(cfg_style), .cfg_hue_spd(cfg_hue_spd),
        .cfg_wave_gain(cfg_wave_gain), .cfg_bg_mode(cfg_bg_mode),
        .cfg_auto(cfg_auto), .view_idx(view_idx)
    );

    //=========================================================================
    integer n_err = 0;
    integer n_press = 0, n_press_before = 0;
    integer i, k;
    reg [7:0] exp_view [0:5];

    always @(posedge clk) if (rst_n && press) n_press = n_press + 1;

    // 带抖动的按键：先抖 N 次再稳定
    task poke_key;
        input integer n_bounce;
        input         level;        // 0 = 按下
        integer j;
        begin
            key_n = ~level;         // 先稳定到目标电平
            for (j = 0; j < n_bounce; j = j + 1) begin
                #3000 key_n = level;        // 抖一下（3 us，小于 20 ms 窗口）
                #3000 key_n = ~level;
            end
            key_n = ~level;         // 最终稳定
            // ⚠️ CNT_MAX 是【周期数】，不能直接当 #延时用（1 周期 = 1000 ns，
            //    差了 1000 倍，等于根本没等）。用 repeat @(posedge clk) 最稳。
            repeat (CNT_MAX + 2000) @(posedge clk);
        end
    endtask

    task do_write;
        input [3:0] a; input [7:0] d;
        begin
            @(negedge clk); wr_en = 1; wr_addr = a; wr_data = d;
            @(negedge clk); wr_en = 0;
            @(posedge clk);
        end
    endtask

    task do_next;
        begin
            @(negedge clk); next_view = 1;
            @(negedge clk); next_view = 0;
            @(posedge clk);
        end
    endtask

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_ui_ctrl.vcd");
            $dumpvars(0, tb_ui_ctrl);
        end

        $display("============================================================");
        $display(" 按键消抖 + 配置寄存器组验证");
        $display("   消抖窗口 %0d ms，时钟 %0d MHz，自动循环周期 %0d 拍",
                 MS, CLK_HZ/1000000, 1000);
        $display("============================================================");

        rst_n = 0;
        repeat (10) @(posedge clk);
        @(negedge clk); rst_n = 1;
        repeat (5) @(posedge clk);

        //---------------------------------------------------------------------
        // ① 带抖动按一次
        //---------------------------------------------------------------------
        n_press_before = n_press;
        // ⚠️ poke_key 的 level 参数：1 = 按下（内部取反成 key_n=0）。
        //    第一版写反了顺序（先 1'b0 再 1'b1），结果"松开"被当成按下，
        //    第二次调用的等待窗口里又刚好错过了抬起沿。
        poke_key(5, 1'b1);          // 抖 5 次后按下
        poke_key(5, 1'b0);          // 抖 5 次后松开
        if (n_press - n_press_before != 1) begin
            n_err = n_err + 1;
            $display("  [ERR] 带抖动按一次产生了 %0d 个脉冲（应为 1）",
                     n_press - n_press_before);
        end else
            $display("  [ok ] ① 带 5 次抖动的按键只识别出 1 次按下");

        //---------------------------------------------------------------------
        // ② 纯抖动（不真的按下）
        //---------------------------------------------------------------------
        n_press_before = n_press;
        for (i = 0; i < 30; i = i + 1) begin
            #100 key_n = 1'b0;
            #100 key_n = 1'b1;
        end
        repeat (CNT_MAX + 2000) @(posedge clk);
        if (n_press != n_press_before) begin
            n_err = n_err + 1;
            $display("  [ERR] 纯抖动产生了 %0d 个脉冲（应为 0）", n_press - n_press_before);
        end else
            $display("  [ok ] ② 纯抖动（不到消抖窗口）不产生任何脉冲");

        //---------------------------------------------------------------------
        // ③ 复位后的默认值
        //---------------------------------------------------------------------
        $display("");
        if (cfg_view !== 8'b0000_0111 || cfg_hue_spd !== 8'd2 ||
            cfg_style !== 8'd0 || cfg_bg_mode !== 8'd0 || cfg_auto !== 8'd0) begin
            n_err = n_err + 1;
            $display("  [ERR] 默认值不符：view=%08b style=%0d huespd=%0d bg=%0d auto=%0d",
                     cfg_view, cfg_style, cfg_hue_spd, cfg_bg_mode, cfg_auto);
        end else
            $display("  [ok ] ③ 上电默认值正确（三视图全开 / 色相速度 2 / 不自动）");

        //---------------------------------------------------------------------
        // ④ 统一写端口
        //---------------------------------------------------------------------
        do_write(4'h0, 8'b0000_0001);   // 只柱状
        do_write(4'h1, 8'd1);
        do_write(4'h2, 8'd4);
        do_write(4'h3, 8'd5);
        do_write(4'h4, 8'd2);
        do_write(4'h5, 8'd0);
        do_write(4'hF, 8'hAA);          // 未定义地址，应被忽略
        if (cfg_view !== 8'b0000_0001 || cfg_style !== 8'd1 || cfg_hue_spd !== 8'd4 ||
            cfg_wave_gain !== 8'd5 || cfg_bg_mode !== 8'd2 || cfg_auto !== 8'd0) begin
            n_err = n_err + 1;
            $display("  [ERR] 写端口结果不符：view=%08b style=%0d huespd=%0d wg=%0d bg=%0d",
                     cfg_view, cfg_style, cfg_hue_spd, cfg_wave_gain, cfg_bg_mode);
        end else
            $display("  [ok ] ④ 统一写端口 6 个地址全部正确，未定义地址被忽略");

        //---------------------------------------------------------------------
        // ⑤ 视图轮转（含回绕）
        //---------------------------------------------------------------------
        $display("");
        do_write(4'h5, 8'd0);           // 关自动
        do_write(4'h0, 8'b0000_0111);   // 回到 preset[2] 全开
        // TB 里照抄一份预设表（独立写，不复用 RTL 的）
        exp_view[0] = 8'b0000_0101;
        exp_view[1] = 8'b0000_0110;
        exp_view[2] = 8'b0000_0111;
        exp_view[3] = 8'b0000_0001;
        exp_view[4] = 8'b0000_0010;
        exp_view[5] = 8'b0000_0100;

        k = 0;
        for (i = 0; i < 8; i = i + 1) begin
            do_next();
            // 从 preset[2] 出发，第 n 次应该落到 preset[(2+n) % 6]
            if (cfg_view !== exp_view[(2 + i + 1) % 6]) begin
                k = k + 1;
                if (k <= 3)
                    $display("  [ERR] 第 %0d 次 next_view 后 view=%08b，期望 %08b",
                             i + 1, cfg_view, exp_view[(2 + i + 1) % 6]);
            end
        end
        if (k != 0) n_err = n_err + 1;
        else $display("  [ok ] ⑤ next_view 按预设表轮转 8 次，回绕正确");

        //---------------------------------------------------------------------
        // ⑥ 直写 VIEW 后，下一次 next_view 不能跳号
        //---------------------------------------------------------------------
        do_write(4'h0, 8'b0000_0010);   // 直写"只极坐标"
        do_next();
        // preset[4] = 0000_0010（只极坐标）-> 下一个是 preset[5] = 0000_0100（只波形）
        if (cfg_view !== 8'b0000_0100) begin
            n_err = n_err + 1;
            $display("  [ERR] 直写后 next_view 跳号：view=%08b idx=%0d（期望 00000100/idx=5）",
                     cfg_view, view_idx);
        end else if (view_idx !== 4'd5) begin
            n_err = n_err + 1;
            $display("  [ERR] 直写后 view_idx 没对齐：%0d（期望 5）", view_idx);
        end else
            $display("  [ok ] ⑥ 直写 VIEW 后 view_idx 自动对齐，next_view 不跳号");

        //---------------------------------------------------------------------
        // ⑦ 自动循环
        //---------------------------------------------------------------------
        $display("");
        do_write(4'h5, 8'd1);           // 开自动（周期 1000 拍）
        n_press_before = cfg_view;
        repeat (2500) @(posedge clk);
        if (cfg_view === n_press_before) begin
            n_err = n_err + 1;
            $display("  [ERR] 开了自动循环但视图没变（一直是 %08b）", cfg_view);
        end else
            $display("  [ok ] ⑦ 自动循环生效（%08b -> %08b）", n_press_before, cfg_view);
        do_write(4'h5, 8'd0);

        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  消抖/默认值/写端口/轮转/自动 全部正确");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

    // 超时保护
    initial begin
        #50_000_000;
        $display(" 结果       : *** FAIL ***  超时");
        $finish;
    end

endmodule
