//=============================================================================
// tb_ui_layer.v - 按钮层自检
//-----------------------------------------------------------------------------
// 查的是【可独立陈述的性质】，不是把 RTL 的比较器抄一遍：
//   ① 按钮带之外：draw 必须为 0
//   ② 每个按钮的中心像素：draw=1，且不是边色
//   ③ 边框：距边缘 2 像素以内是边色
//   ④ 命中测试：把触摸点放在每个按钮中心 -> hit_k 必须是那个按钮
//   ⑤ 按钮之外点：hit 必须为 0
//   ⑥ 【渲染和交互必须一致】—— 对每个按钮，把"渲染时被判为该按钮的像素"
//      和"命中测试判为该按钮的点"对齐检查：同一套边界，不能一个宽一个窄
//   ⑦ 按下/生效的配色优先级：按下 > 生效 > 普通
//=============================================================================
`timescale 1ns/1ps

module tb_ui_layer;

    localparam integer NB = 6;
    localparam integer XW = 10;
    localparam integer YW = 9;
    localparam integer BX0 = 0, BY0 = 234, BW = 78, BH = 38, GAP = 0;

    reg  [XW-1:0] x = 0;
    reg  [YW-1:0] y = 0;
    reg  [XW-1:0] tx = 0;
    reg  [YW-1:0] ty = 0;
    reg           pressed = 0;
    reg  [3:0]    active = 4'hF;        // 0xF = 没有按钮生效

    wire          draw;
    wire [23:0]   rgb;
    wire [2:0]    hit_k;
    wire          hit;
    wire [3:0]    hit_act;

    integer n_err = 0;
    integer k, i, px, py;

`define CHK(cond, msg) \
        if (cond) $display("  [ok ] %0s", msg); \
        else begin n_err = n_err + 1; $display("  [ERR] %0s", msg); end

    ui_layer #(
        .NB(NB), .XW(XW), .YW(YW),
        .BX0(BX0), .BY0(BY0), .BW(BW), .BH(BH), .GAP(GAP)
    ) dut (
        .x(x), .y(y), .tx(tx), .ty(ty), .pressed(pressed), .active(active),
        .draw(draw), .rgb(rgb), .hit_k(hit_k), .hit(hit), .hit_act(hit_act)
    );

    // 配色常量（和 DUT 里一致；这里只是给判据用）
    localparam [23:0] C_FACE = 24'h20_40_60;
    localparam [23:0] C_EDGE = 24'h60_A0_C0;
    localparam [23:0] C_PRESS = 24'hC0_E0_FF;
    localparam [23:0] C_ACT  = 24'h30_60_90;
    localparam [23:0] C_TXT  = 24'hE0_F0_FF;      // 标签文字（RTL 默认值）
    localparam [23:0] C_TXTH = 24'h10_20_30;      // 按下/生效时的深色字

    task setxy;
        input integer a, b;
        begin
            x = a[XW-1:0]; y = b[YW-1:0]; #1;
        end
    endtask

    task settouch;
        input integer a, b;
        input         p;
        begin
            tx = a[XW-1:0]; ty = b[YW-1:0]; pressed = p; #1;
        end
    endtask

    initial begin
        $display("============================================================");
        $display(" ui_layer 自检（按钮层：渲染 + 命中测试）");
        $display("   %0d 个按钮，每个 %0dx%0d，带子 y=%0d..%0d",
                 NB, BW, BH, BY0, BY0+BH-1);
        $display("============================================================");

        //---------------------------------------------------------------------
        $display("");
        $display(" [1] 按钮带之外的像素：draw 必须为 0");
        begin : outside
            integer bad;
            bad = 0;
            // 正上方
            for (px = 0; px < 480; px = px + 37) begin
                setxy(px, BY0 - 1);
                if (draw) bad = bad + 1;
                setxy(px, BY0 - 40);
                if (draw) bad = bad + 1;
            end
            // 正下方
            for (px = 0; px < 480; px = px + 37) begin
                setxy(px, BY0 + BH);
                if (draw) bad = bad + 1;
            end
            // 带子右侧（最后一个按钮之后）
            for (py = BY0; py < BY0 + BH; py = py + 7) begin
                setxy(BX0 + NB*BW, py);
                if (draw) bad = bad + 1;
            end
            `CHK(bad == 0, "按钮带之外 draw 全为 0");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [2] 每个按钮的中心：draw=1 且不是边色");
        begin : center_chk
            integer bad;
            bad = 0;
            for (k = 0; k < NB; k = k + 1) begin
                setxy(BX0 + k*BW + BW/2, BY0 + BH/2);
                if (!draw) begin bad = bad + 1; end
                if (rgb === C_EDGE) begin bad = bad + 1; end
            end
            `CHK(bad == 0, "所有按钮中心都画了面、不是边");
        end

        //---------------------------------------------------------------------
        // ⚠️ begin 块的名字也不能撞关键字。第一版叫 `edge`，
        //   iverilog 直接报 syntax error（edge 是 Verilog 保留字，
        //   用在 `always @(edge ...)` 那种地方）。和账本第 66 条（`buf`）同一类。
        $display("");
        $display(" [3] 边框：距边缘 2 像素以内是边色");
        begin : bevel
            integer bad;
            bad = 0;
            for (k = 0; k < NB; k = k + 1) begin
                // 左边 0/1 应是边，中间不应是边
                setxy(BX0 + k*BW + 0, BY0 + BH/2);
                if (rgb !== C_EDGE) bad = bad + 1;
                setxy(BX0 + k*BW + 1, BY0 + BH/2);
                if (rgb !== C_EDGE) bad = bad + 1;
                setxy(BX0 + k*BW + 2, BY0 + BH/2);
                if (rgb === C_EDGE) bad = bad + 1;
                // 上边
                setxy(BX0 + k*BW + BW/2, BY0 + 0);
                if (rgb !== C_EDGE) bad = bad + 1;
                setxy(BX0 + k*BW + BW/2, BY0 + 2);
                if (rgb === C_EDGE) bad = bad + 1;
            end
            `CHK(bad == 0, "边框宽度和位置正确（2 像素）");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [4] 命中测试：触摸点放在每个按钮中心");
        begin : hit_center
            integer bad;
            bad = 0;
            pressed = 1'b1;
            for (k = 0; k < NB; k = k + 1) begin
                settouch(BX0 + k*BW + BW/2, BY0 + BH/2, 1'b1);
                if (!hit)        bad = bad + 1;
                if (hit_k !== k[2:0]) begin
                    bad = bad + 1;
                    $display("      [ERR] 中心点 (%0d,%0d) 命中按钮 %0d，期望 %0d",
                             BX0 + k*BW + BW/2, BY0 + BH/2, hit_k, k);
                end
            end
            `CHK(bad == 0, "所有按钮中心都能命中自己");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [5] 按钮之外点：hit 必须为 0");
        begin : hitout
            integer bad;
            bad = 0;
            // 带子正上方
            for (px = 0; px < 480; px = px + 41) begin
                settouch(px, BY0 - 1, 1'b1);
                if (hit) bad = bad + 1;
            end
            // 带子正下方
            for (px = 0; px < 480; px = px + 41) begin
                settouch(px, BY0 + BH, 1'b1);
                if (hit) bad = bad + 1;
            end
            // 最后一个按钮右侧
            settouch(BX0 + NB*BW, BY0 + BH/2, 1'b1);
            if (hit) bad = bad + 1;
            `CHK(bad == 0, "按钮带之外点不命中");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [6] 渲染与交互必须用同一套边界（否则就是'框画这里、热区在那里'）");
        begin : consistent
            integer bad, r_lo, r_hi, h_lo, h_hi, all_lo, all_hi;
            bad = 0;
            // 渲染侧：整条带子（所有按钮合起来）的水平覆盖范围
            //   ⚠️ 第一版这里只查了交互侧，没查渲染侧 —— 于是"in_band 漏判 x"
            //      这个 bug 在这个判据里溜过去了（是 [1] 抓到的）。
            //      判据本身也不能只查一半。
            all_lo = -1; all_hi = -1;
            for (px = 0; px < 480; px = px + 1) begin
                setxy(px, BY0 + BH/2);
                if (draw) begin
                    if (all_lo < 0) all_lo = px;
                    all_hi = px;
                end
            end
            if (all_lo !== BX0 || all_hi !== (BX0 + NB*BW - 1)) begin
                bad = bad + 1;
                $display("      [ERR] 渲染侧带子覆盖 [%0d,%0d]，期望 [%0d,%0d]",
                         all_lo, all_hi, BX0, BX0 + NB*BW - 1);
            end

            for (k = 0; k < NB; k = k + 1) begin
                // 交互：用 in_rect 的等价判据找水平范围
                h_lo = -1; h_hi = -1;
                for (px = 0; px < 480; px = px + 1) begin
                    settouch(px, BY0 + BH/2, 1'b1);
                    if (hit && hit_k === k[2:0]) begin
                        if (h_lo < 0) h_lo = px;
                        h_hi = px;
                    end
                end
                if (h_lo !== (BX0 + k*BW) || h_hi !== (BX0 + k*BW + BW - 1)) begin
                    bad = bad + 1;
                    $display("      [ERR] 按钮 %0d 热区水平范围 [%0d,%0d]，期望 [%0d,%0d]",
                             k, h_lo, h_hi, BX0 + k*BW, BX0 + k*BW + BW - 1);
                end
            end
            `CHK(bad == 0, "热区范围与按钮框完全一致");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [7] 配色优先级：按下 > 生效 > 普通");
        begin : prio_chk
            integer bad;
            bad = 0;
            // ⚠️ 取色点必须避开【标签文字】和【边框】。
            //   标签画在 y0+16..y0+23（字符行 2），按钮高 38，
            //   所以取 y0+30 这一行：既不是边，也没有字。
            //   第一版取的是按钮正中（y0+19），正好落在字上，
            //   于是"按下色/生效色"全被判错。
            // 按钮 2 生效中
            active = 4'h2;
            setxy(BX0 + 2*BW + BW/2, BY0 + 30);
            if (rgb !== C_ACT) begin bad = bad + 1; $display("      [ERR] 生效按钮没高亮"); end

            // 按钮 3 生效中，但手指正按着按钮 3 -> 应该是按下色
            active = 4'h3;
            settouch(BX0 + 3*BW + BW/2, BY0 + 30, 1'b1);
            setxy(BX0 + 3*BW + BW/2, BY0 + 30);
            if (rgb !== C_PRESS) begin bad = bad + 1; $display("      [ERR] 按下色没有压过生效色"); end

            // 松开后应该回到生效色
            settouch(BX0 + 3*BW + BW/2, BY0 + 30, 1'b0);
            setxy(BX0 + 3*BW + BW/2, BY0 + 30);
            if (rgb !== C_ACT) begin bad = bad + 1; $display("      [ERR] 松开后没回到生效色"); end

            // 没生效也没按的按钮 -> 底色
            setxy(BX0 + 0*BW + BW/2, BY0 + 30);
            if (rgb !== C_FACE) begin bad = bad + 1; $display("      [ERR] 普通按钮不是底色"); end

            `CHK(bad == 0, "配色优先级正确（按下 > 生效 > 普通）");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [8] active 无效值（0xF）时不该有任何按钮高亮");
        begin : noact
            integer bad;
            bad = 0;
            active = 4'hF;
            pressed = 1'b0;
            for (k = 0; k < NB; k = k + 1) begin
                setxy(BX0 + k*BW + BW/2, BY0 + 30);     // 避开标签
                if (rgb !== C_FACE) bad = bad + 1;
            end
            `CHK(bad == 0, "active=0xF 时全部是普通底色");
        end

        //---------------------------------------------------------------------
        $display("");
        $display(" [9] hit_act 必须是该按钮的动作码（供上层去写 ui_ctrl）");
        begin : act_chk
            integer bad;
            bad = 0;
            pressed = 1'b1;
            for (k = 0; k < NB; k = k + 1) begin
                settouch(BX0 + k*BW + BW/2, BY0 + BH/2, 1'b1);
                // 表里第 0..4 个是 0..4，第 5 个是 0x6
                if (k < 5) begin
                    if (hit_act !== k[3:0]) bad = bad + 1;
                end else begin
                    if (hit_act !== 4'h6) bad = bad + 1;
                end
            end
            `CHK(bad == 0, "hit_act 与按钮表的动作码一致");

            // ⚠️ 关键判据：没按下时 hit_act 必须是 0xF。
            //   上层就是靠"从 0xF 变成非 0xF"来识别一次按下的；
            //   如果没按时它仍然给出动作码，上层就再也识别不到"按下"。
            //   （这正是演示扫描时"光标一直动、配置不动"的根因。）
            bad = 0;
            pressed = 1'b0;
            for (k = 0; k < NB; k = k + 1) begin
                settouch(BX0 + k*BW + BW/2, BY0 + BH/2, 1'b0);
                if (hit_act !== 4'hF) begin
                    bad = bad + 1;
                    $display("      [ERR] 没按下时 hit_act=%h（应为 F）", hit_act);
                end
                if (hit) bad = bad + 1;
            end
            `CHK(bad == 0, "没按下时 hit_act 恒为 0xF（上层才能识别'按下'沿）");
        end

        //---------------------------------------------------------------------
        //---------------------------------------------------------------------
        $display("");
        $display(" [10] 标签：每个按钮的标签区必须画出文字（不能只有底色）");
        begin : label_chk
            integer bad, n_ink, ty2;
            bad = 0;
            active = 4'hF;
            pressed = 1'b0;
            for (k = 0; k < NB; k = k + 1) begin
                n_ink = 0;
                // 扫标签区：字符行 2 -> y0+16..y0+23，整行 x0..x0+BW
                for (ty2 = BY0 + 16; ty2 < BY0 + 24; ty2 = ty2 + 1) begin
                    for (px = BX0 + k*BW; px < BX0 + k*BW + BW; px = px + 1) begin
                        setxy(px, ty2);
                        if (rgb === C_TXT) n_ink = n_ink + 1;
                    end
                end
                if (n_ink < 10) begin
                    bad = bad + 1;
                    $display("      [ERR] 按钮 %0d 的标签只有 %0d 个亮点（应有几十个）",
                             k, n_ink);
                end

                // ⚠️ 光数亮点个数是不够的：
                //   曾经把"字符行"当成"字形行"，结果每个字母只画了 7 行里的 3 行，
                //   屏幕上是一排竖条纹 —— 但亮点个数和正常字体差不多，这条判据照样通过。
                //   所以再查【每一行的亮点数不能都相同】：真正的字形每行宽度不一样。
                begin : rowvar
                    integer r, r0, r1, same;
                    same = 0;
                    r0 = -1;
                    for (r = 0; r < 7; r = r + 1) begin
                        r1 = 0;
                        for (px = BX0 + k*BW; px < BX0 + k*BW + BW; px = px + 1) begin
                            setxy(px, BY0 + 16 + r);
                            if (rgb === C_TXT) r1 = r1 + 1;
                        end
                        if (r0 == r1) same = same + 1;
                        r0 = r1;
                    end
                    if (same >= 6) begin
                        bad = bad + 1;
                        $display("      [ERR] 按钮 %0d 的字形每行宽度几乎相同 —— 像竖条纹而不是字母",
                                 k);
                    end
                end
            end
            `CHK(bad == 0, "每个按钮都画出了标签，且各字符行宽度不同（真的是字形）");
        end

        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  渲染/命中/边界一致/配色优先级全部正确");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

endmodule
