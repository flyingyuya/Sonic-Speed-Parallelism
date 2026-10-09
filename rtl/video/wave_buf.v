//=============================================================================
// wave_buf.v - 波形缓冲（示波器式【触发采集】+ 双 bank 乒乓）
//-----------------------------------------------------------------------------
// 用途：把 clk_sys 域（音频 48 kHz）的采样送到 clk_pix 域，供波形显示。
//
// 【为什么不是"最近 N 个点"】
//   最早的版本是滚动窗口：帧起始时 base = 写指针 - 480，永远显示"最近一屏"。
//   问题是帧周期 12 ms 里写指针走了 577 个采样，而窗口只有 480
//   -> 每帧相对上一帧错开 97 个点 -> 画面一直向左滚。
//
//   这不是 bug，是"滚动窗口"的定义。但它对【周期性信号】非常难看：
//   每次截取的相位都不一样，看起来永远在动。
//
// 【示波器怎么解决：触发】
//   不去问"最近 N 个点是哪 N 个"，而是问"从哪个【有意义的事件】开始数 N 个点"。
//   最常用的事件就是【向上过零点】：
//
//        信号              ╱╲          ╱╲          ╱╲
//                        ╱  ╲        ╱  ╲        ╱  ╲
//        ───────────────╱────╲──────╱────╲──────╱────╲────
//                      ↑      ↑    ↑      ↑    ↑      ↑
//                    触发    触发   触发   触发  触发   触发
//                    ↓
//                   从这里往后抓 480 个点
//
//   周期性信号每个周期都有一次向上过零 -> 每次抓到的波形相位完全相同
//   -> **画面静止**。
//
//   注意：触发【不改变任何数据】，它只决定"从哪一点开始截取"。
//
// 【两种触发模式（和真示波器一样）】
//   · 正常（normal）：只在过零点抓。信号太弱/有直流偏置时可能一直抓不到。
//   · 自动（auto）  ：等够 TO_MAX 个采样还没有过一次触发，就【强行抓一次】。
//   只做正常模式的话，一旦抓不到触发，画面会永久冻住 —— 上板时极难排查。
//   所以这里两个都做：正常优先，超时兜底。
//
// 【迟滞（hysteresis / 施密特触发）】
//   直接判 `din >= 0` 的话，信号在零点附近的噪声会让它连续触发好几次，
//   画面反而更抖。所以要求：信号先【低于 -TH】，然后才允许在 `din >= 0` 时触发。
//   这样"过零"必须是一次真的从负半周到正半周的过程，噪声骗不过去。
//
// 【为什么要双 bank（乒乓）】
//   写侧正在抓第 N 帧的时候，读侧正在显示第 N-1 帧 —— 必须是两块内存。
//   正好：AW=10 -> 深度 1024，而我们每屏只要 480 个点
//   -> 天然就是两个 512 深的 bank（用最高位当地标记），**白送**。
//
//   握手协议（两个方向各一个 1 bit 信号，两级同步器）：
//     写 -> 读：done_tog，每完成一次采集翻转一次（读侧据此知道有新数据）
//     读 -> 写：rd_tog，  读侧在 sof 锁存了哪个 bank（写侧据此知道可以抓下一帧了）
//   写侧【等读侧取走】才抓下一帧，保证读侧永远读到完整的一帧，不会撕裂。
//
//   代价：更新率被显示帧率限制（抓 10 ms + 等一帧 <= 22 ms -> 约 45 Hz）。
//   对一个"本该静止"的波形来说完全够。
//
// 【跨时钟域为什么只用 1 bit】
//   done_tog / rd_tog 都是单比特"翻转"信号，两级同步即可，不需要格雷码。
//   （多比特指针才需要格雷码，见 rtl/common/async_fifo.v。）
//
// 【为什么复位【不】碰 RAM 的控制脚】（踩过 DRC REQP-1839，第 4 次同族）
//   把 wrst_n / rrst_n 写进写使能或读复位里，会让它们被接到 BRAM 的
//   WEA / RSTRAMB 控制脚上，触发 [DRC REQP-1839]。
//   正确做法：**只复位指针和状态机，不复位 RAM 内容**。
//   抓到的旧数据在下一帧就被覆盖，无所谓。
//=============================================================================
`timescale 1ns/1ps

module wave_buf #(
    parameter integer DW   = 24,        // 采样位宽
    parameter integer AW   = 10,        // 总地址位宽（深度 = 2^AW，一半一个 bank）
    parameter integer SPAN = 480,       // 一屏显示多少个采样点
    // 列坐标位宽（P1-3a）。默认 10 对应 480 宽。
    // ⚠️ SPAN 必须 <= 2^(AW-1)，否则会跨过 bank 边界。
    parameter integer XW   = 10,

    //---------------------------------------------------------------------
    // 触发参数
    //---------------------------------------------------------------------
    // TH：迟滞阈值（绝对值）。信号必须先低于 -TH 才允许触发。
    //     131072 = 2^17 = 满量程(2^23)的 1/64。
    //     太大 -> 弱信号永远触发不了（会退回自动触发）；太小 -> 挡不住噪声。
    parameter integer TH     = 131072,

    // TO_MAX：多少个采样没触发就强行抓一次（自动触发兜底）。
    //     2048 @48kHz = 43 ms —— 比显示帧周期(12 ms)长一些即可：
    //     太短会让"正常模式"被自动触发抢走，太长会让画面冻住几百毫秒才跳一次。
    //     必须 <= 65535。
    parameter integer TO_MAX = 2048
) (
    //----------------------- 写侧：clk_sys -----------------------
    input  wire                  wclk,
    input  wire                  wrst_n,
    input  wire                  we,       // 每个采样一个 strobe（= rx_valid）
    input  wire signed [DW-1:0]  din,

    //----------------------- 读侧：clk_pix -----------------------
    input  wire                  rclk,
    input  wire                  rrst_n,
    input  wire                  sof,      // 帧起始，锁存新的显示 bank
    input  wire [XW-1:0]         x,        // 当前列（0..SPAN-1）
    output reg  signed [DW-1:0]  dout,

    //----------------------- 观测（接调试/测试用）-----------------------
    output reg                   trig_pulse,   // 触发那一拍（写域，单周期）
    output reg                   done_pulse    // 一帧抓满那一拍（写域，单周期）
);

    localparam integer CB = AW - 1;          // 每个 bank 的地址位宽
    localparam [CB-1:0] SPAN_L = SPAN[CB-1:0];

    (* ram_style = "block" *) reg signed [DW-1:0] mem [0:(1<<AW)-1];

    //=========================================================================
    // 1. 写侧：触发采集状态机
    //=========================================================================
    //   S_ARM  -> 等触发（迟滞武装 + 向上过零，或自动触发超时）
    //   S_CAP  -> 往当前 bank 里写 SPAN 个点
    //   S_WAIT -> 等读侧把刚写满的那个 bank 取走（否则不许覆盖）
    localparam [1:0] S_ARM = 2'd0, S_CAP = 2'd1, S_WAIT = 2'd2;

    reg  [1:0]    st;
    reg  [CB-1:0] cap_idx;      // 已采集点数
    reg           done_tog;     // 每完成一次采集翻转
    reg           below;        // 迟滞：信号最近到过 -TH 以下
    reg  [15:0]   to_cnt;       // 自动触发计数（按采样数，不按时钟）

    // 读侧锁存的 bank（在读域里的寄存器）。
    // ⚠️ 必须【声明在写域同步器之前】—— Verilog 没有前置声明，
    //    写在后面就会报 `Unable to bind wire/reg/memory`。
    reg           rd_tog;

    // 读 -> 写 的两级同步器。
    // ⚠️ 声明也要提前：状态机 S_WAIT 里要用 rt_s2 做判断，
    //    而这个 always 块（第 2 节）写在状态机后面 ——
    //    **同一根因这次又踩了一遍**（和 disp_top 里 demo_touch 那次一样）。
    reg           rt_s1, rt_s2;

    // 阈值做成有符号常量。TH 是正数，th_n 是它的相反数。
    wire signed [DW-1:0] th_n = -TH[DW-1:0];

    wire        armed    = (st == S_ARM);
    wire        pos_edge = below && ~din[DW-1];            // 武装过 + 当前非负 = 向上过零
    wire        to_fire  = (to_cnt == TO_MAX[15:0]);
    wire        fire     = armed && we && (pos_edge || to_fire);

    // 写哪个 bank：永远是"另一个"（不是刚写满的那个）
    wire        wr_bank = ~done_tog;
    wire [CB-1:0] wr_idx = armed ? {CB{1'b0}} : cap_idx;

    // 触发那一拍本身也要写进去（它是第 0 个点）
    wire        wr_en = we && (fire || (st == S_CAP));

    // ⚠️ 复位【不】出现在这里 —— 否则会连到 BRAM 的 WEA 脚 -> DRC REQP-1839
    always @(posedge wclk)
        if (wr_en) mem[{wr_bank, wr_idx}] <= din;

    always @(posedge wclk) begin
        if (!wrst_n) begin
            st         <= S_ARM;
            cap_idx    <= {CB{1'b0}};
            done_tog   <= 1'b0;
            below      <= 1'b0;
            to_cnt     <= 16'd0;
            trig_pulse <= 1'b0;
            done_pulse <= 1'b0;
        end else begin
            trig_pulse <= 1'b0;
            done_pulse <= 1'b0;

            case (st)
            //-------------------------------------------------------------
            S_ARM: begin
                if (we) begin
                    // 迟滞：低于 -TH 就把"可以触发"的闸门打开，触发后关上
                    if (din < th_n)    below <= 1'b1;
                    else if (pos_edge) below <= 1'b0;

                    if (pos_edge || to_fire) begin
                        st         <= S_CAP;
                        cap_idx    <= {{(CB-1){1'b0}}, 1'b1};   // 第 0 点就是本次
                        below      <= 1'b0;
                        to_cnt     <= 16'd0;
                        trig_pulse <= 1'b1;
                    end else if (!to_fire) begin
                        to_cnt <= to_cnt + 1'b1;                // 数【采样】不是数时钟
                    end
                end
            end
            //-------------------------------------------------------------
            S_CAP: begin
                if (we) begin
                    if (cap_idx == SPAN_L - 1'b1) begin
                        st         <= S_WAIT;
                        done_tog   <= ~done_tog;                // 这一 bank 满了
                        done_pulse <= 1'b1;
                    end else begin
                        cap_idx <= cap_idx + 1'b1;
                    end
                end
            end
            //-------------------------------------------------------------
            // 等读侧切到刚写满的那个 bank（rd_tog 追上 done_tog）。
            // 没有这一步的话，写侧会在读侧还没取走时就覆盖掉它 -> 画面撕裂。
            S_WAIT: begin
                if (rt_s2 == done_tog) begin
                    st      <= S_ARM;
                    cap_idx <= {CB{1'b0}};
                end
            end
            //-------------------------------------------------------------
            default: st <= S_ARM;
            endcase
        end
    end

    //=========================================================================
    // 2. 跨时钟域握手
    //=========================================================================
    // 写 -> 读：done_tog 两级同步
    reg dt_s1, dt_s2;

    always @(posedge rclk) begin
        if (!rrst_n) begin
            dt_s1 <= 1'b0;
            dt_s2 <= 1'b0;
        end else begin
            dt_s1 <= done_tog;
            dt_s2 <= dt_s1;
        end
    end

    // 读 -> 写：rd_tog 两级同步
    always @(posedge wclk) begin
        if (!wrst_n) begin
            rt_s1 <= 1'b0;
            rt_s2 <= 1'b0;
        end else begin
            rt_s1 <= rd_tog;
            rt_s2 <= rt_s1;
        end
    end

    //=========================================================================
    // 3. 读侧：帧起始锁存 bank，然后按列读
    //=========================================================================
    //   ⚠️ rd_tog 【只能】在 sof 变 —— 一帧之内必须固定，
    //      否则同一帧上半段读 bank0、下半段读 bank1，画面错位。
    always @(posedge rclk) begin
        if (!rrst_n)
            rd_tog <= 1'b0;
        else if (sof && (dt_s2 != rd_tog))
            rd_tog <= dt_s2;
    end

    // 【为什么地址要用"切换后"的 bank，而不是直接用 rd_tog】
    //   rd_tog 是在 sof 那一拍的时钟沿才更新的（非阻塞），
    //   所以 sof 当拍算地址时用的还是【旧】bank —— 那一列会读到上一帧的数据。
    //   真实时序里 sof 在行同步处、x 还是 0，所以出问题的是 frame 的第 0 列。
    //   这里直接让地址"提前"用上新 bank，就与 sof / x 的对齐方式无关了。
    wire        take    = sof && (dt_s2 != rd_tog);
    wire        rd_bank = take ? dt_s2 : rd_tog;
    wire [AW-1:0] raddr = {rd_bank, x[CB-1:0]};

    // ⚠️ 读端口【不】复位 —— 理由同写侧，否则触发 REQP-1839。
    //    BRAM 同步读有一拍延迟：表现为波形整体右移 1 个像素，肉眼无感。
    always @(posedge rclk)
        dout <= mem[raddr];

endmodule
