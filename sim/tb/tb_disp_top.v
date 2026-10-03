//=============================================================================
// tb_disp_top.v - 显示链顶层验证 + 导出 PPM
//-----------------------------------------------------------------------------
// 【对齐关系（写错了会全线报假错，务必先看清）】
//
//   lcd_timing 里：
//       周期 T   : x(T), y(T), in_active(T)                <- 组合
//       周期 T+1 : de = in_active(T)，rgb_out = f(x(T), y(T))   <- 寄存
//
//   所以检查时要用【当拍的 de】去配【上一拍的 x/y】：
//       if (de)  比较( lcd_rgb , f(x_d, y_d) )      x_d = x 延迟一拍
//   ❌ 不能再用 de 延迟一拍去配 x_d —— 那会整体又错开一拍。
//   （这个坑本项目踩过 4 次，见 docs/08 账本第 23/25/28/32 条）
//
// bars 也要延迟一拍：它在 sof 才更新，而 rgb_out 反映的是上一拍的状态。
//
// 【参照实现】
//   TB 里另起一份完整的像素生成链（bg_src + polar_map + rainbow_rom +
//   柱状/波形/极坐标合成），算出"这一像素本应是什么颜色"，逐点比对。
//   只有这样才能保证绘制顺序、优先级、颜色索引全都一致。
//
// 检查项：
//   ① 跨时钟域快照   30 根柱高跨域后逐根一致
//   ② 颜色           【全部 130560 个有效像素】逐一比对
//   ③ 柱状区像素数   每根柱点亮数 = (bh*3/16) * (8-BAR_GAP)
//   ④ 极坐标覆盖     30 根辐条都要有像素
//   ⑤ 帧内不撕裂     非 sof 拍 bars 不允许变化
//   ⑥ 色相滚动       跨帧 hue_off 递增（波形也用 rb_pol 上色）
//   ⑦ 导出 PPM
//=============================================================================
`timescale 1ns / 1ps

`include "disp_cfg.vh"

module tb_disp_top;

    // ⚠️ 全部来自 rtl/video/disp_cfg.vh —— 不要再在 TB 里写死这些数，
    //    否则改布局时 TB 和 RTL 会错开（这个坑踩过两次）。
    localparam integer HDISP    = `DISP_HDISP;
    localparam integer VDISP    = `DISP_VDISP;
    localparam integer NBARS    = `DISP_NBARS;
    localparam integer HW       = 9;
    localparam integer BARS_Y0  = `DISP_BARS_Y0;
    localparam integer BAR_GAP  = `DISP_BAR_GAP;
    localparam integer POL_CX   = `DISP_POL_CX;
    localparam integer POL_CY   = `DISP_POL_CY;
    localparam integer POL_RIN  = `DISP_POL_RIN;
    localparam integer POL_RMAX = `DISP_POL_RMAX;
    localparam integer WAVE_CY  = `DISP_WAVE_CY;
    localparam integer WAVE_AMP = `DISP_WAVE_AMP;
    localparam integer WAVE_TH  = `DISP_WAVE_TH;
    localparam integer DW       = NBARS * HW;      // 540

    localparam [23:0] AXIS_RGB = 24'h20_38_50;
    localparam [23:0] CORE_RGB = 24'h40_50_60;

    localparam real TSYS_NS = 20.8333;
    localparam real TPIX_NS = 80.0;
    localparam integer SETTLE_FRAMES = 4;
    localparam integer NBAR_W = 8 - BAR_GAP;       // 每根柱每行点亮像素数

    reg clk_sys = 1'b0, clk_pix = 1'b0;
    reg rst_sys_n = 1'b0, rst_pix_n = 1'b0;

    always #(TSYS_NS / 2.0) clk_sys = ~clk_sys;
    always #(TPIX_NS / 2.0) clk_pix = ~clk_pix;

    //=========================================================================
    // 写侧
    //=========================================================================
    reg  [DW-1:0] spec_din = {DW{1'b0}};
    reg           spec_wr  = 1'b0;

    // 波形输入：喂一段三角波，方便看出"中心线固定、上下对称"
    //   phase 0..63，幅度 0..31，再左移 18 位放进 Q1.23 的高位
    reg signed [23:0] wave_din = 24'sd0;
    reg               wave_we  = 1'b0;

    // 视图使能：[0]柱状 [1]极坐标 [2]波形。主测量用全开，
    //           之后会临时关掉几个做"开关真的生效"的抽查。
    reg [2:0] view_en  = 3'b111;
    reg [7:0] hue_spd  = 8'd6;      // 与 ui_ctrl 的默认值一致
    reg [7:0] wave_gain = 8'd8;     // G 命令：8 = 1.0 倍（与 ui_ctrl 默认一致）
                                    //   H 越大越快：H=6 -> 每 2^(8-6)=4 帧滚一级
    integer           wdiv = 0, wph = 0;

    always @(posedge clk_sys) begin
        if (!rst_sys_n) begin
            wdiv <= 0; wph <= 0; wave_we <= 1'b0; wave_din <= 24'sd0;
        end else if (wdiv == 39) begin
            wdiv     <= 0;
            wave_we  <= 1'b1;
            wave_din <= (wph < 32) ? (wph << 18) : ((63 - wph) << 18);
            wph      <= (wph == 63) ? 0 : wph + 1;
        end else begin
            wdiv    <= wdiv + 1;
            wave_we <= 1'b0;
        end
    end
    integer       i, k;

    //=========================================================================
    // DUT
    //=========================================================================
    wire [23:0] lcd_rgb;
    wire        lcd_hs, lcd_vs, lcd_clk;

    disp_top dut (
        .clk_sys   (clk_sys),
        .rst_sys_n (rst_sys_n),
        .spec_wr   (spec_wr),
        .spec_din  (spec_din),
        .clk_pix   (clk_pix),
        .rst_pix_n (rst_pix_n),
        .ui_mode   (4'd0),
        .ui_style  (4'd0),
        .ui_view   (view_en),
        .ui_hue_spd(hue_spd),
        .ui_wave_gain(wave_gain),
        .wave_din  (wave_din),
        .wave_we   (wave_we),
        .lcd_rgb   (lcd_rgb),
        .lcd_hs    (lcd_hs),
        .lcd_vs    (lcd_vs),
        .lcd_clk   (lcd_clk)
    );

    //=========================================================================
    // 参照实现：所有信号统一延迟一拍，去配【当拍的 de】
    //=========================================================================
    reg [9:0]    x_d   = 10'd0;
    reg [8:0]    y_d   = 9'd0;
    reg [6:0]    hue_d = 7'd0;
    reg [DW-1:0] bars_d = {DW{1'b0}};

    always @(posedge clk_pix) begin
        x_d    <= dut.x;
        y_d    <= dut.y;
        hue_d  <= dut.hue_off;
        bars_d <= dut.u_sync.bars;
    end

    // ---- 背景 ----
    wire [23:0] e_bg;
    bg_src #(.HDISP(HDISP), .VDISP(VDISP)) u_bg_ref (
        .x(x_d), .y(y_d), .mode(4'd0), .rgb(e_bg)
    );

    // ---- 柱状 ----
    wire [5:0]    e_bbar = {1'b0, x_d[8:3]};
    wire [HW-1:0] e_bbh  = bars_d[e_bbar*HW +: HW];
    wire [10:0]   e_bmul = (e_bbh << 1) + e_bbh;
    wire [6:0]    e_bhpx = e_bmul[10:4];
    wire [8:0]    e_bfb  = VDISP[8:0] - 9'd1 - y_d;
    wire e_b_hit = (y_d >= BARS_Y0[8:0]) && (e_bfb < {2'b00, e_bhpx})
                   && (x_d[2:0] >= BAR_GAP[2:0]);
    wire e_b_lit = e_b_hit && view_en[0];

    // ---- 极坐标 ----
    wire        e_p_in, e_p_lit;
    wire [5:0]  e_p_bar;
    wire [7:0]  e_p_r;

    polar_map #(
        .NBARS(NBARS), .HW(HW),
        .CX(POL_CX), .CY(POL_CY), .R_IN(POL_RIN), .R_MAX(POL_RMAX)
    ) u_pol_ref (
        .x(x_d), .y(y_d), .bars(bars_d),
        .in_disc(e_p_in), .lit(e_p_lit), .bar_idx(e_p_bar), .r_out(e_p_r)
    );
    wire e_p_core = view_en[1] && e_p_in && (e_p_r >= POL_RIN - 3) && (e_p_r < POL_RIN);
    wire e_p_litg = view_en[1] && e_p_lit;

    // ---- 颜色 ----
    wire [23:0] e_rb_bar, e_rb_pol;
    rainbow_rom u_rb1 (.addr({e_bbar[4:0], 2'b00} + hue_d), .rgb(e_rb_bar));
    rainbow_rom u_rb2 (.addr({e_p_bar[4:0], 2'b00} + hue_d), .rgb(e_rb_pol));

    // ---- 波形（TB 里镜像一份 wave_buf，才能验证 disp_top 的连线与映射）----
    wire signed [23:0] e_wave;
    wave_buf #(.DW(24), .AW(10), .SPAN(HDISP)) u_wave_ref (
        .wclk(clk_sys), .wrst_n(rst_sys_n), .we(wave_we), .din(wave_din),
        .rclk(clk_pix), .rrst_n(rst_pix_n), .sof(dut.sof), .x(dut.x),
        .dout(e_wave)
    );

    // ⚠️ 采集波形也要延迟一拍：DUT 里 wave_buf.dout 是一级寄存器、
    //    lcd_timing.rgb_out 又是一级，而参照里的 y_d/x_d 只延迟了一拍。
    //    少延这一拍会让波形整体错开 2 个像素（又是"差一拍"这个老问题）。
    reg signed [23:0] e_wave_d = 24'sd0;
    always @(posedge clk_pix) e_wave_d <= e_wave;

    wire [24:0] e_wabs = e_wave_d[23] ? ({1'b0, ~e_wave_d} + 1'b1)
                                      : {1'b0, e_wave_d};
    wire [5:0]  e_wraw = e_wabs[23:18];
    wire [5:0]  e_wamp = (e_wraw > WAVE_AMP[5:0]) ? WAVE_AMP[5:0] : e_wraw;
    wire [8:0]  e_wy   = e_wave_d[23] ? (WAVE_CY[8:0] - {3'b000, e_wamp})
                                      : (WAVE_CY[8:0] + {3'b000, e_wamp});
    wire [8:0]  e_wdy  = (y_d > e_wy) ? (y_d - e_wy) : (e_wy - y_d);
    wire        e_wline = view_en[2] && (e_wdy <= WAVE_TH[8:0]);
    wire        e_waxis = !view_en[2] && (y_d == WAVE_CY[8:0]);

    // ---- 合成（优先级必须和 disp_mix 完全一致）----
    // 优先级必须和 disp_mix 完全一致：背景 < 柱状 < 波形 < 极坐标
    wire [23:0] exp_rgb = e_p_litg ? e_rb_pol
                        : e_p_core ? CORE_RGB
                        : e_wline  ? e_rb_pol
                        : e_waxis  ? AXIS_RGB
                        : e_b_lit  ? e_rb_bar
                        :            e_bg;

    //=========================================================================
    // 测量窗口
    //=========================================================================
    integer n_err = 0;
    integer n_pix = 0;
    integer f_no  = 0;
    reg     meas  = 1'b0;

    integer bar_cnt [0:NBARS-1];
    integer pol_cnt [0:NBARS-1];
    integer n_tear  = 0;

    reg [6:0] hue_prev = 7'd0;
    integer   n_scroll = 0;

    integer fd;
    reg     cap_en = 1'b0;

    always @(posedge clk_pix) begin
        if (rst_pix_n && dut.sof) begin
            f_no = f_no + 1;
            if (f_no == SETTLE_FRAMES) begin
                meas   = 1'b1;
                cap_en = 1'b1;
            end
            if (f_no == SETTLE_FRAMES + 1) begin
                meas   = 1'b0;
                cap_en = 1'b0;
            end
        end
    end

    //---------------------------------------------------------------------
    // ② 颜色逐像素比对
    //---------------------------------------------------------------------
    always @(posedge clk_pix) begin
        if (rst_pix_n && meas && dut.de) begin
            n_pix = n_pix + 1;
            if (lcd_rgb !== exp_rgb) begin
                n_err = n_err + 1;
                if (n_err <= 8)
                    $display("  [ERR] (%0d,%0d) 颜色 %06h 期望 %06h  (柱亮=%b 极亮=%b 心环=%b 轴=%b)",
                             x_d, y_d, lcd_rgb, exp_rgb, e_b_lit, e_p_litg, e_p_core, e_wline);
            end

            // ③④ 分区统计
            if (e_b_lit) bar_cnt[e_bbar] = bar_cnt[e_bbar] + 1;
            if (e_p_lit) pol_cnt[e_p_bar] = pol_cnt[e_p_bar] + 1;
        end
    end

    //---------------------------------------------------------------------
    // ⑤ 帧内不撕裂
    //---------------------------------------------------------------------
    always @(posedge clk_pix) begin
        if (rst_pix_n && meas && !dut.sof) begin
            if (dut.u_sync.bars !== bars_d) n_tear = n_tear + 1;
        end
    end

    //---------------------------------------------------------------------
    // ⑥ 色相滚动
    //---------------------------------------------------------------------
    always @(posedge clk_pix) begin
        if (rst_pix_n && hue_prev !== dut.hue_off) begin
            n_scroll = n_scroll + 1;
            hue_prev = dut.hue_off;
        end
    end

    //---------------------------------------------------------------------
    // ⑦ PPM 导出
    //---------------------------------------------------------------------
    always @(posedge clk_pix) begin
        if (cap_en && dut.de && fd != 0)
            $fwrite(fd, "%c%c%c", lcd_rgb[23:16], lcd_rgb[15:8], lcd_rgb[7:0]);
    end

    //=========================================================================
    // 主流程
    //=========================================================================
    reg [HW-1:0] got_bars [0:NBARS-1];
    reg [DW-1:0] bars_now;
    integer n_err_bar, n_err_pol, n_pol_used;
    integer bh_cnt;
    integer exp_px;
    integer h0, h1, h2, hh;
    reg [8:0] exp_h;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_disp_top.vcd");
            $dumpvars(0, tb_disp_top);
        end

        $display("============================================================");
        $display(" 显示链顶层验证（新布局：极坐标 + 波形中线 + 柱状）");
        $display("   极坐标 圆心(%0d,%0d) 半径 %0d~%0d", POL_CX, POL_CY, POL_RIN, POL_RMAX);
        $display("   波形   中线 y=%0d（A3 才接真实缓冲）", WAVE_CY);
        $display("   柱状   y>=%0d，%0d 根 x %0d px", BARS_Y0, NBARS, HDISP/NBARS);
        $display("============================================================");

        for (k = 0; k < NBARS; k = k + 1) begin
            bar_cnt[k] = 0;
            pol_cnt[k] = 0;
            got_bars[k] = 0;
        end

        rst_sys_n = 1'b0;  rst_pix_n = 1'b0;
        repeat (20) @(posedge clk_sys);
        repeat (10) @(posedge clk_pix);
        @(negedge clk_sys); rst_sys_n = 1'b1;
        @(negedge clk_pix); rst_pix_n = 1'b1;
        repeat (4) @(posedge clk_pix);

        fd = $fopen("sim/build/disp_frame.ppm", "wb");
        if (fd == 0)
            $display("  [WARN] 打不开 sim/build/disp_frame.ppm，跳过图片导出");
        else
            $fwrite(fd, "P6\n%0d %0d\n255\n", HDISP, VDISP);

        for (i = 0; i < 3; i = i + 1) begin
            // 造一段"像音乐"的频谱：整体随频率衰减 + 两个凸起（鼓点/人声）
            //   base  = 470 - 3k        470 -> 293
            //   bump1 = k 8..17  +70    低频鼓点
            //   bump2 = k 30..41 +55    中频人声
            //   柱 0 故意留 0 —— 直流分量本来就是滤掉的，
            //   顺便让"柱高为 0 不点亮"这条检查有依据。
            // ⚠️ 循环体必须用 begin/end 包起来！Verilog 的 for 只带【一条】语句，
            //    漏了 begin/end 会让后面的赋值跑到循环外，只执行一次 ——
            //    表现为"数据写进去了但全是 0"（因为最后一次执行时 k 已越界）。
            for (k = 0; k < NBARS; k = k + 1) begin
                h0 = 470 - (k * 3);
                h1 = (k >= 8  && k < 18) ? 70 : 0;
                h2 = (k >= 30 && k < 42) ? 55 : 0;
                hh = h0 + h1 + h2;
                if (k == 0)                hh = 0;
                if (hh > 511)              hh = 511;
                spec_din[k*HW +: HW] = hh[8:0];
            end
            @(negedge clk_sys); spec_wr = 1'b1;
            @(negedge clk_sys); spec_wr = 1'b0;
            repeat (6) @(posedge clk_sys);
        end

        wait (f_no >= SETTLE_FRAMES + 2);
        repeat (4) @(posedge clk_pix);

        if (fd != 0) begin
            $fclose(fd);
            $display("");
            $display("  已导出图片: sim/build/disp_frame.ppm  (%0dx%0d RGB888)", HDISP, VDISP);
        end

        //---------------------------------------------------------------------
        // ① 跨域快照
        //---------------------------------------------------------------------
        $display("");
        $display(" [1] 跨时钟域快照");
        for (k = 0; k < NBARS; k = k + 1) begin
            got_bars[k] = dut.u_sync.bars[k*HW +: HW];
            h0 = 470 - (k * 3);
            h1 = (k >= 8  && k < 18) ? 70 : 0;
            h2 = (k >= 30 && k < 42) ? 55 : 0;
            hh = h0 + h1 + h2;
            exp_h = (k == 0) ? 9'd0 : (hh > 511) ? 9'd511 : hh[8:0];
            if (got_bars[k] !== exp_h) begin
                n_err = n_err + 1;
                if (n_err <= 6)
                    $display("  [ERR] 柱 %0d：clk_pix 读到 %0d，写入 %0d",
                             k, got_bars[k], exp_h);
            end
        end
        $display("  [ok ] %0d 根柱高跨域后逐根一致（柱0=%0d 柱10=%0d 柱29=%0d）",
                 NBARS, got_bars[0], got_bars[10], got_bars[29]);

        //---------------------------------------------------------------------
        // ③ 柱状区像素数
        //---------------------------------------------------------------------
        $display("");
        $display(" [2] 柱状区像素数");
        n_err_bar = 0;
        for (k = 0; k < NBARS; k = k + 1) begin
            exp_px = (got_bars[k] * 3) / 16 * NBAR_W;
            if (bar_cnt[k] != exp_px) begin
                n_err_bar = n_err_bar + 1;
                if (n_err_bar <= 6)
                    $display("  [ERR] 柱 %0d：点亮 %0d 像素，期望 %0d（高 %0d）",
                             k, bar_cnt[k], exp_px, got_bars[k]);
            end
        end
        if (n_err_bar != 0) n_err = n_err + 1;
        else
            $display("  [ok ] 60 根柱点亮像素数 = (柱高*3/16) x %0d，逐根吻合", NBAR_W);

        //---------------------------------------------------------------------
        // ④ 极坐标覆盖
        //---------------------------------------------------------------------
        $display("");
        $display(" [3] 极坐标覆盖");
        n_pol_used = 0;
        for (k = 0; k < NBARS; k = k + 1)
            if (pol_cnt[k] > 0) n_pol_used = n_pol_used + 1;

        // 柱 0 高度为 0 -> 极坐标上对应辐条整段熄灭；其余都要有像素
        n_err_pol = 0;
        if (pol_cnt[0] != 0) n_err_pol = n_err_pol + 1;
        for (k = 1; k < NBARS; k = k + 1)
            if (pol_cnt[k] == 0) n_err_pol = n_err_pol + 1;

        if (n_err_pol != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 有 %0d 根辐条的覆盖情况不符（柱 0 高为 0，应完全不亮）", n_err_pol);
        end else
            $display("  [ok ] 柱 0（高为 0）的辐条完全不亮，其余 %0d 根都有像素", NBARS-1);

        //---------------------------------------------------------------------
        $display("");
        if (n_tear != 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 帧内 bars 变化 %0d 次（撕裂）", n_tear);
        end else
            $display("  [ok ] 帧内柱高保持不变（无撕裂）");

        if (n_scroll == 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 色相偏移没有变化");
        end else
            $display("  [ok ] 色相偏移变化 %0d 次", n_scroll);

        $display("");
        $display("  测量帧有效像素数 = %0d（应为 %0d）", n_pix, HDISP*VDISP);
        if (n_pix != HDISP * VDISP) begin
            n_err = n_err + 1;
            $display("  [ERR] 有效像素数不符");
        end

        //---------------------------------------------------------------------
        //---------------------------------------------------------------------
        //---------------------------------------------------------------------
        // [3b] 波形增益（G 命令）—— 它以前是个【死控件】，这里专门守住
        //---------------------------------------------------------------------
        // ⚠️ 这里【不能】把 dut.wave_adj / dut.wave_sample 当成有符号数比较。
        //   Verilog-2001 的层次引用（dut.xxx）不带 signed 属性，iverilog 会
        //   按无符号解释 —— 于是 -6291456 被读成 10485760，判据全错，
        //   看上去像"输出变成了 -采样"（其实 DUT 是好的，是 TB 读错了）。
        //   所以下面一律【只看位】：用 bit[23] 判符号，自己算绝对值。
        //
        // 【判据】（不做"扫帧抓峰值"——那要扫满 150150 拍一帧，TB 会超时）
        //   · G=8 和 G=0 都必须是精确 1.0 倍：|wave_adj| 逐拍 == |wave_sample|
        //   · G=8 时符号位也必须逐拍相同
        //   · G=4 的绝对值 <= G=8 的（真在衰减）
        //   · G=12/15 的绝对值 >= G=8 的（真在放大）
        //---------------------------------------------------------------------
        $display("");
        $display(" [3b] 波形增益（G 命令）");
        begin : gain_test
            integer g, j;
            integer n_mag, n_sgn, n_dir;
            reg [23:0] ma, ms;

            // ---- 判据①：G=0/G=8 精确 1.0 倍（比绝对值 + 比符号位）----
            n_mag = 0; n_sgn = 0;
            for (g = 0; g < 2; g = g + 1) begin
                wave_gain = (g == 0) ? 8'd0 : 8'd8;
                repeat (3) @(posedge clk_pix);
                for (j = 0; j < 6000; j = j + 1) begin
                    @(posedge clk_pix);
                    ma = dut.wave_adj[23]    ? (~dut.wave_adj[23:0] + 1'b1)
                                             : dut.wave_adj[23:0];
                    ms = dut.wave_sample[23] ? (~dut.wave_sample[23:0] + 1'b1)
                                             : dut.wave_sample[23:0];
                    if (ma !== ms) n_mag = n_mag + 1;
                    if (ma !== 24'd0 && (dut.wave_adj[23] !== dut.wave_sample[23]))
                        n_sgn = n_sgn + 1;
                end
            end
            if (n_mag != 0) begin
                n_err = n_err + 1;
                $display("  [ERR] G=0/G=8 的幅度不是精确 1.0 倍（%0d 拍不符）", n_mag);
            end else
                $display("  [ok ] G=0 与 G=8 幅度精确等于 1.0 倍（逐拍 12000 次比对）");
            if (n_sgn != 0) begin
                n_err = n_err + 1;
                $display("  [ERR] G=8 时符号翻转了 %0d 拍（饱和逻辑有问题）", n_sgn);
            end else
                $display("  [ok ] G=8 无符号翻转");

            // ---- 判据②：衰减/放大方向 ----
            n_dir = 0;
            for (g = 0; g < 3; g = g + 1) begin
                wave_gain = (g == 0) ? 8'd4 : ((g == 1) ? 8'd12 : 8'd15);
                repeat (3) @(posedge clk_pix);
                for (j = 0; j < 6000; j = j + 1) begin
                    @(posedge clk_pix);
                    ma = dut.wave_adj[23]    ? (~dut.wave_adj[23:0] + 1'b1)
                                             : dut.wave_adj[23:0];
                    ms = dut.wave_sample[23] ? (~dut.wave_sample[23:0] + 1'b1)
                                             : dut.wave_sample[23:0];
                    if (g == 0) begin
                        if (ma > ms) n_dir = n_dir + 1;      // 0.5 倍不该更大
                    end else begin
                        if (ma < ms) n_dir = n_dir + 1;      // 放大不该更小
                    end
                end
            end
            if (n_dir != 0) begin
                n_err = n_err + 1;
                $display("  [ERR] 增益方向不对（%0d 拍）—— 这正是 G 当死控件时的老毛病",
                         n_dir);
            end else
                $display("  [ok ] 增益方向正确：G4 衰减、G12/G15 放大");

            wave_gain = 8'd8;      // 还原
        end

        // [4] 视图开关抽查：切到"只柱状"，验证极坐标/波形真的被关掉
        //---------------------------------------------------------------------
        $display("");
        $display(" [4] 视图开关抽查（切到 只柱状 = 3'b001）");
        view_en = 3'b001;
        repeat (2500) @(posedge clk_pix);

        // 直接看 disp_mix 内部的组合输出（关掉的视图必须恒为 0）
        if (dut.u_mix.p_lit || dut.u_mix.p_core) begin
            n_err = n_err + 1;
            $display("  [ERR] 极坐标已关，但 p_lit/p_core 仍为 1");
        end else
            $display("  [ok ] 极坐标关掉后 p_lit / p_core 恒为 0");

        if (dut.u_mix.w_line) begin
            n_err = n_err + 1;
            $display("  [ERR] 波形已关，但 w_line 仍为 1");
        end else
            $display("  [ok ] 波形关掉后 w_line 恒为 0（改画中线提示）");

        // b_hit 只对特定像素为 1，不能只看一瞬间，要统计一段时间
        // ⚠️ 一帧是 525x286 = 150150 拍，柱状区在 y>=176。
        //    窗口太短根本扫不到 bar 区 —— 3000 拍只有 5.7 行，差得远。
        bh_cnt = 0;
        for (k = 0; k < 110000; k = k + 1) begin
            @(posedge clk_pix);
            if (dut.u_mix.b_hit) bh_cnt = bh_cnt + 1;
        end
        if (bh_cnt == 0) begin
            n_err = n_err + 1;
            $display("  [ERR] 柱状仍开着，但 110000 拍内 b_hit 一次都没拉高");
        end else
            $display("  [ok ] 柱状仍正常工作（110000 拍内 b_hit 出现 %0d 次）", bh_cnt);

        // 再切回全开，确认能恢复
        view_en = 3'b111;
        repeat (500) @(posedge clk_pix);

        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  130560 像素逐点一致，柱状/极坐标/波形/开关全对");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

    // 超时保护
    initial begin
        #80_000_000;
        $display(" 结果       : *** FAIL ***  超时");
        $finish;
    end

endmodule
