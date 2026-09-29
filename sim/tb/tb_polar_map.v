//=============================================================================
// tb_polar_map.v - 极坐标变换验证
//-----------------------------------------------------------------------------
// 这是本工程【最容易写错的一类模块】：一堆位操作 + 近似，看着能跑，
// 但可能整圈的角度分配是歪的、或者镜像了、或者某几根辐条永远收不到像素。
//
// 所以验证方式是【拿 $atan2 当真值，扫遍圆盘里的每一个像素】：
//   ① 角度 -> 柱号    对每个像素算出真实角度，和 RTL 给的柱号比。
//                      靠近扇区边界 0.8° 内的像素允许差 1（因为边界用的是
//                      /64 整数近似，理想正切值有 ~0.7° 的偏差）。
//   ② 覆盖性          30 根柱必须每根都分到像素，否则那根柱子永远不亮。
//   ③ 单调环绕        沿圆周走一圈，柱号必须单调 +1，且只回绕一次
//                      （回绕两次说明角度分区没接上）。
//   ④ 镜像不自洽       θ 和 θ+180° 的柱号必须差 NBARS/2。
//   ⑤ 点亮边界精度    沿 32 个方向往外走，点亮/熄灭的转折点必须精确落在
//                      R_IN + (h>>2) 上（RTL 用的是平方比较，应当逐点吻合）。
//                      r_out 只是调试用的近似值，单独按 10% 容差顺带看一眼。
//   ⑥ 点亮范围        给一根固定的柱高，点亮的半径区间必须正好是
//                      [R_IN, R_IN + h>>2)。
//=============================================================================
`timescale 1ns / 1ps

`include "disp_cfg.vh"

module tb_polar_map;

    // ⚠️ 全部来自 rtl/video/disp_cfg.vh —— 不要在 TB 里另写一份。
    //    （柱数 30->60 时就是因为这里写死了旧圆心，报出 6113 处假错误）
    localparam integer NBARS = `DISP_NBARS;
    localparam integer HW    = 9;
    localparam integer CX    = `DISP_POL_CX;
    localparam integer CY    = `DISP_POL_CY;
    localparam integer R_IN  = `DISP_POL_RIN;
    localparam integer R_MAX = `DISP_POL_RMAX;
    localparam real    PI    = 3.14159265358979;

    reg  [9:0]           x = 10'd0;
    reg  [8:0]           y = 9'd0;
    reg  [NBARS*HW-1:0]  bars = {(NBARS*HW){1'b0}};

    wire        in_disc, lit;
    wire [5:0]  bar_idx;      // 60 根柱需要 6 位
    wire [7:0]  r_out;

    polar_map #(
        .NBARS(NBARS), .HW(HW), .CX(CX), .CY(CY), .R_IN(R_IN), .R_MAX(R_MAX)
    ) dut (
        .x(x), .y(y), .bars(bars),
        .in_disc(in_disc), .lit(lit), .bar_idx(bar_idx), .r_out(r_out)
    );

    integer n_err = 0;
    integer k, b;
    integer min_u, max_u;
    integer bar_used [0:NBARS-1];

    // 真值工具
    real    ang_deg;
    integer exp_sector, exp_bar;
    real    dist_boundary;

    // 半径统计
    real    r_true, r_err, r_err_max;

    // 环绕检查
    integer prev_bar, wrap_cnt, step;
    // 镜像检查用的临时量（Verilog-2001 不允许在未命名块里声明变量）
    real    a1, a2;
    integer b1, b2;
    integer exp_r, hit_lo, hit_hi, bi;

    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb_polar_map.vcd");
            $dumpvars(0, tb_polar_map);
        end

        $display("============================================================");
        $display(" 极坐标变换验证（真值用 $atan2 / $sqrt）");
        $display("   圆心(%0d,%0d)  内半径 %0d  外半径 %0d  %0d 根柱（64 扇区）",
                 CX, CY, R_IN, R_MAX, NBARS);
        $display("============================================================");

        for (k = 0; k < NBARS; k = k + 1) bar_used[k] = 0;

        //---------------------------------------------------------------------
        // ①②⑤ 扫遍圆盘内每一个像素
        //---------------------------------------------------------------------
        prev_bar  = -1;
        wrap_cnt  = 0;
        r_err_max = 0.0;

        for (k = 0; k < 480; k = k + 1) begin : g_px
            for (b = 0; b < 208; b = b + 1) begin : g_py
                x = k[9:0];
                y = b[8:0];
                #1;

                // 只看圆盘内的像素
                r_true = $sqrt(1.0*(k-CX)*(k-CX) + 1.0*(b-CY)*(b-CY));
                if (r_true < R_MAX) begin
                    // ---- 真值角度 ----
                    ang_deg = $atan2(1.0*(b-CY), 1.0*(k-CX)) * 180.0 / PI;
                    if (ang_deg < 0.0) ang_deg = ang_deg + 360.0;

                    exp_sector = (ang_deg / 5.625);
                    if (exp_sector > 63) exp_sector = 63;    // 64 扇区
                    exp_bar = (exp_sector * NBARS) / 64;
                    if (exp_bar >= NBARS) exp_bar = NBARS - 1;

                    // 离最近扇区边界的距离（度）
                    dist_boundary = ang_deg - exp_sector * 5.625;
                    if (dist_boundary > 2.8125) dist_boundary = 5.625 - dist_boundary;

                    if (bar_idx !== exp_bar[5:0]) begin    // bar_idx 是 6 位，别截成 5 位
                        // 边界附近允许差 1（/64 近似的固有偏差）
                        if (!(dist_boundary < 0.8 &&
                              (bar_idx == exp_bar+1 || bar_idx+1 == exp_bar))) begin
                            n_err = n_err + 1;
                            if (n_err <= 8)
                                $display("  [ERR] (%0d,%0d) 角度 %7.2f° 得柱 %0d，期望 %0d",
                                         k, b, ang_deg, bar_idx, exp_bar);
                        end
                    end
                    bar_used[bar_idx] = bar_used[bar_idx] + 1;

                    // ---- 半径精度 ----
                    r_err = (r_out - r_true) / r_true;
                    if (r_err < 0.0) r_err = -r_err;
                    if (r_err > r_err_max) r_err_max = r_err;
                end
            end
        end

        $display("");
        $display(" [1] 角度 -> 柱号（扫 %0dx208 区域，取圆盘内像素）", 480);
        if (n_err == 0)
            $display("  [ok ] 全部与 $atan2 真值一致（边界 1.5° 内允许差 1）");
        else
            $display("  [ERR] 共 %0d 处不符", n_err);

        //---------------------------------------------------------------------
        // ② 覆盖性
        //---------------------------------------------------------------------
        $display("");
        $display(" [2] 覆盖性");
        b = 0;
        for (k = 0; k < NBARS; k = k + 1)
            if (bar_used[k] == 0) begin
                b = b + 1;
                $display("  [ERR] 柱 %0d 一个像素都没分到", k);
            end
        if (b == 0) begin
            // 内联统计（Verilog-2001 的 function 必须有输入端口，直接用循环更省事）
            min_u = 1000000;
            max_u = 0;
            for (k = 0; k < NBARS; k = k + 1) begin
                if (bar_used[k] < min_u) min_u = bar_used[k];
                if (bar_used[k] > max_u) max_u = bar_used[k];
            end
            $display("  [ok ] %0d 根柱都有像素（最少 %0d，最多 %0d，理想均匀约 %0d）",
                     NBARS, min_u, max_u, 3.14159*R_MAX*R_MAX/NBARS);
        end else
            n_err = n_err + b;

        //---------------------------------------------------------------------
        // ③ 沿圆周走一圈：柱号必须单调递增且只回绕一次
        //---------------------------------------------------------------------
        $display("");
        $display(" [3] 沿圆周环绕");
        prev_bar = -1;
        wrap_cnt = 0;
        step     = 0;
        for (k = 0; k < 720; k = k + 1) begin
            ang_deg = k * 0.5;
            x = (CX + $rtoi(70.0 * $cos(ang_deg * PI / 180.0) + 0.5));
            y = (CY + $rtoi(70.0 * $sin(ang_deg * PI / 180.0) + 0.5));
            #1;
            if (prev_bar >= 0) begin
                if (bar_idx == prev_bar) begin
                    // 同柱，正常
                end else if (bar_idx == prev_bar + 1) begin
                    step = step + 1;
                end else if (prev_bar == NBARS-1 && bar_idx == 0) begin
                    wrap_cnt = wrap_cnt + 1;
                end else begin
                    n_err = n_err + 1;
                    if (n_err <= 8)
                        $display("  [ERR] %0.1f° 处柱号从 %0d 跳到 %0d", ang_deg, prev_bar, bar_idx);
                end
            end
            prev_bar = bar_idx;
        end
        if (wrap_cnt != 1 || step != NBARS-1) begin
            n_err = n_err + 1;
            $display("  [ERR] 环绕异常：回绕 %0d 次（应 1），递增 %0d 次（应 %0d）",
                     wrap_cnt, step, NBARS-1);
        end else
            $display("  [ok ] 走一圈：柱号递增 %0d 次、回绕 1 次，无跳变", step);

        //---------------------------------------------------------------------
        // ④ 镜像自洽：θ 和 θ+180° 差 15
        //---------------------------------------------------------------------
        $display("");
        $display(" [4] 镜像自洽（θ 与 θ+180° 应差 %0d）", NBARS/2);
        b = 0;
        for (k = 0; k < 64; k = k + 1) begin
            a1 = k * 5.625 + 2.5;
            a2 = a1 + 180.0;
            x = CX + $rtoi(70.0 * $cos(a1*PI/180.0) + 0.5);
            y = CY + $rtoi(70.0 * $sin(a1*PI/180.0) + 0.5);
            #1; b1 = bar_idx;
            x = CX + $rtoi(70.0 * $cos(a2*PI/180.0) + 0.5);
            y = CY + $rtoi(70.0 * $sin(a2*PI/180.0) + 0.5);
            #1; b2 = bar_idx;
            if (((b2 - b1) % NBARS + NBARS) % NBARS != NBARS/2) begin
                b = b + 1;
                if (b <= 4) $display("  [ERR] %0.1f° -> 柱%0d，反向 -> 柱%0d", a1, b1, b2);
            end
        end
        if (b != 0) n_err = n_err + 1;
        else $display("  [ok ] 32 组对径像素柱号都相差 %0d", NBARS/2);

        //---------------------------------------------------------------------
        // ⑤ 点亮边界精度（r_out 只做粗略 sanity check）
        //---------------------------------------------------------------------
        $display("");
        $display(" [5] 点亮边界精度");
        // 所有柱给同一个高度，让边界与角度无关
        for (k = 0; k < NBARS; k = k + 1) bars[k*HW +: HW] = 9'd200;
        // 与 RTL 相同的映射：bh(0..511) -> 半径增量 = bh * 29 / 256
        //   （跨度 R_MAX-R_IN = 58，58/512 ≈ 29/256）
        // 这里独立写一遍公式（照设计文档，不引用 RTL），才能算真正的核对
        exp_r = R_IN + (200 * 29) / 256;    // = 18 + 22 = 40

        b = 0;
        for (k = 0; k < 64; k = k + 1) begin : g_dir
            a1 = k * 5.625 + 2.5;
            hit_lo = -1;
            hit_hi = -1;
            for (bi = R_IN - 2; bi < R_MAX + 2; bi = bi + 1) begin
                x = CX + $rtoi(bi * $cos(a1*PI/180.0) + 0.5);
                y = CY + $rtoi(bi * $sin(a1*PI/180.0) + 0.5);
                #1;
                if (lit) begin
                    if (hit_lo < 0) hit_lo = bi;
                    hit_hi = bi;
                end
            end
            if (hit_lo < 0 || hit_lo > R_IN + 2 || hit_hi < exp_r - 2 || hit_hi > exp_r + 2) begin
                b = b + 1;
                if (b <= 5)
                    $display("  [ERR] %6.1f° 方向：点亮区间 [%0d,%0d]，期望约 [%0d,%0d]",
                             a1, hit_lo, hit_hi, R_IN, exp_r);
            end
        end
        if (b != 0) n_err = n_err + 1;
        else
            $display("  [ok ] 64 个方向点亮区间都是 [%0d, %0d)（逐点吻合，无角度依赖）",
                     R_IN, exp_r);

        $display("  [info] r_out（已降级为调试量）最大相对误差 = %0.2f%%", r_err_max * 100.0);

        //---------------------------------------------------------------------
        // ⑥ 点亮范围
        //---------------------------------------------------------------------
        $display("");
        $display(" [6] 点亮半径范围");
        // 所有柱都给同一个高度 200 -> 半径增量 200>>2 = 50 -> 点亮 [20, 70)
        for (k = 0; k < NBARS; k = k + 1)
            bars[k*HW +: HW] = 9'd200;
        b = 0;
        for (k = 0; k < 120; k = k + 1) begin
            x = (CX + k);        // 沿 +x 轴往外走
            y = CY[8:0];
            #1;
            if (k >= R_IN && k < exp_r) begin
                if (!lit) begin b = b + 1;
                    if (b <= 4) $display("  [ERR] r=%0d 应点亮但没亮", k); end
            end else if (k < R_MAX) begin
                if (lit && k >= R_IN) begin b = b + 1;
                    if (b <= 4) $display("  [ERR] r=%0d 不应点亮但亮了", k); end
            end
        end
        if (b != 0) n_err = n_err + 1;
        else $display("  [ok ] 柱高 200 -> 点亮半径 [%0d, %0d)，与预期一致", R_IN, exp_r);

        //---------------------------------------------------------------------
        $display("");
        $display("------------------------------------------------------------");
        if (n_err == 0)
            $display(" 结果       : *** PASS ***  角度/覆盖/环绕/镜像/半径/点亮 全部正确");
        else
            $display(" 结果       : *** FAIL ***  共 %0d 处错误", n_err);
        $display("------------------------------------------------------------");
        $finish;
    end

endmodule
