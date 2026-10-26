//////////////////////////////////////////////////////////////////////////////////
// Company:        个人项目 / SonicTwin-Engine
// Engineer:       flyingyu
//
// Create Date:    2026-10-26
// Design Name:    wave_buf
// Module Name:    wave_buf
// Project Name:   音速双擎（SonicTwin-Engine）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    wave_buf.v - 波形缓冲（示波器式【触发采集】+ 双 bank 乒乓）
//                 用途：把 clk_sys 域（音频 48 kHz）的采样送到 clk_pix 域，供波形显示。
//                 【为什么不是"最近 N 个点"】
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
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

    // 1 = 用 th_in（自适应门限，来自 env_track）；0 = 用固定参数 TH。
    //   把 TH 保留成参数是为了让 TB 能单独测"固定门限"这条路径。
    parameter integer ADAPT  = 0,

    //---------------------------------------------------------------------
    // HOLD_SHIFT：每 2^HOLD_SHIFT 次采集才【换一次显示】
    //---------------------------------------------------------------------
    //   【为什么需要】
    //     一个 bank 装 SPAN=480 个采样，采样率 48 kHz
    //     ⟹ 480/48000 = 10 ms 填满一屏 ⟹ 每秒抓 100 屏
    //     而 LCD 只刷新 60 Hz ⟹ 每帧看到的都是不同的采集
    //     ⟹ 屏上看起来像"多条波形叠在一起"（不是触发不稳，是太快了看不清）
    //   注意：这【只影响波形】✗ 频谱走的是另一条路（spectrum→bars）✗ 不受影响 ✓
    //   参考工程 Music-Spectrum 里也有类似的 hold_cnt（保持计数器）✓
    //
    //   0 = 每次采集都换（原来行为）
    //   3 = 每 8 次换一次（12.5 屏/秒）← 推荐
    parameter integer HOLD_SHIFT = 0,

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
    // 自适应门限（正数，来自 env_track）。ADAPT=0 时不用。
    input  wire signed [DW-1:0]  th_in,
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
    reg  [7:0]    hold_cnt;     // 采集计数（到 2^HOLD_SHIFT 才真的换显示）
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

    // 门限来源：自适应（th_in）或固定（TH 参数）。
    //   【为什么不是"永远用 th_in"】固定值那条路径是 TB 的独立判据基准，
    //   去掉它就没法区分"门限自适应错了"和"触发器本身错了"。
    wire signed [DW-1:0] th   = ADAPT ? th_in : TH[DW-1:0];
    wire signed [DW-1:0] th_n = -th;

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
            hold_cnt   <= 8'd0;
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
                        // ★ 只在 hold_cnt 数满时才换显示 bank
                        //   （HOLD_SHIFT=0 时每次都换 ✗ 与原行为一致 ✓）
                        if (HOLD_SHIFT == 0) begin
                            done_tog <= ~done_tog;
                            hold_cnt <= 8'd0;
                        end else if (hold_cnt == ((1 << HOLD_SHIFT) - 1)) begin
                            done_tog <= ~done_tog;
                            hold_cnt <= 8'd0;
                        end else begin
                            hold_cnt <= hold_cnt + 8'd1;
                        end
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
