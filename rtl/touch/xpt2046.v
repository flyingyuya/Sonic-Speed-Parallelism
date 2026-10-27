//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    xpt2046
// Module Name:    xpt2046
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    xpt2046.v - XPT2046 电阻触摸屏控制器（四线 SPI）
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps


module xpt2046 #(
    parameter integer CLK_HZ  = 48_000_000,
    parameter integer SCLK_HZ = 1_000_000       // DCLK 频率
) (
    input  wire        clk,
    input  wire        rst_n,

    //--------------------- 控制 ---------------------
    input  wire        start,       // 单拍脉冲：启动一次"读 X + 读 Y"
    output reg         busy,        // 转换进行中
    output reg         valid,       // 读数有效（单拍脉冲）
    output reg  [11:0] x_pos,
    output reg  [11:0] y_pos,

    //-------------------------------------------------------------------------
    // 诊断量：上板排查"到底通没通"用
    //-----------------------------------------------------------------------------
    //   dbg_edges : 最近一次转换里 DOUT 跳变了几次
    //   dbg_low   : 最近一次转换里 DOUT 有没有出现过低电平（粘滞到下一次 start）
    //
    //   判据：
    //     · dbg_low 一直是 0 -> 器件根本没回话（没选中 / 没供电 / DOUT 接错脚）
    //     · 有跳变但值不对     -> 接线基本对，是协议或时序问题
    //   这比"看读回来的数字对不对"更能定位问题，因为数字对不对还需要校准作前提。
    //-------------------------------------------------------------------------
    output reg  [11:0] dbg_edges,
    output reg         dbg_low,

    //--------------------- 引脚 ---------------------
    output reg         tp_dclk,
    output reg         tp_cs_n,
    output reg         tp_din,
    input  wire        tp_dout
);

    // 半周期分频系数：DCLK 的一个完整周期 = 2*DIV 个 clk
    localparam integer DIV = (CLK_HZ / (2 * SCLK_HZ)) < 1 ? 1 : (CLK_HZ / (2 * SCLK_HZ));

    // PD=11 走内部参考（子卡 R10 未焊，外部 VREF 悬空）。
    //   如果以后把 R10 焊上了，可以改成 8'hD0/8'h90 省点电（转换间掉电）。
    // ⚠️⚠️ 【命令字节：原来两个都是错的】
    //   控制字节格式： S | A2 A1 A0 | MODE | SER/DFR | PD1 PD0
    //   手册原文（Control Byte 一节）：
    //     MODE：=0 -> 12 位转换；=1 -> 【8 位转换】
    //     SER/DFR：=1 单端；=0 差分（比率式）—— 手册说 X/Y 位置测量"preferred"
    //     PD1:PD0：=11 -> 内部参考开 + ADC 开
    //
    //   原来写的是 0xDC = 1 101 1 1 00：
    //                        ↑MODE=1（8位！） ↑SER=1  ↑PD=00（掉电）
    //   三个位全错 -> 拿到的数据毫无意义 -> 现象是
    //   "DOUT 有跳变、诊断量在动，但触摸完全没反应"。
    //   （TB 里的注释还写着 "MODE=0"，注释和值不符，一路烧到板上。）
    //
    //   正确值：
    //     X = 1 101 0 0 11 = 0xD3
    //     Y = 1 001 0 0 11 = 0x93
    //   ⚠️⚠️ PD1 必须为 0！子卡原理图把 VREF(pin9) 经 R10(0Ω) 直接接到 VDD_3V3，
    //     ⟹ 用的是【外部参考】。手册原文：internal reference "must be commanded to be
    //     off"（PD1=0），否则内部 2.5V 参考会和外部 3.3V 打架。
    //   PD0 = 1 ⟹ ADC 常开（不进入转换间掉电）。
    localparam [7:0] CMD_X = 8'hD1;     // 1 101 0 0 01 : X, 12bit, 差分, 外部参考, ADC on
    localparam [7:0] CMD_Y = 8'h91;     // 1 001 0 0 01 : Y, 12bit, 差分, 外部参考, ADC on

    // 状态机
    localparam S_IDLE = 2'd0,
               S_X    = 2'd1,
               S_GAP  = 2'd2,       // 两次转换之间把 nCS 抬起来
               S_Y    = 2'd3;
    localparam S_DONE = 3'd4;        // 单列出来，避免和上面挤在 2 位里

    localparam integer GAP_CYC = 8;  // nCS 抬高的最小拍数（远大于手册要求）

    reg [2:0]  st;
    reg [4:0]  bitn;        // 0..23
    reg        phase;       // 0 = DCLK 低（准备 DIN），1 = DCLK 高（采 DOUT）
    reg [15:0] div;
    reg [3:0]  gap;
    reg [11:0] sh;          // 本次转换的移位结果
    reg        dout_d;      // 上一拍的 DOUT，用来数跳变
    reg [11:0] edge_cnt;    // 本次事务累计跳变数
    reg [7:0]  cmd;         // 当前在发的命令字节

    wire tick = (div == DIV - 1);

    // 当前位是不是"结果位"：bit 9..20 是 12 位结果（MSB 先出）
    wire is_dat = (bitn >= 5'd9) && (bitn <= 5'd20);

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE;
            bitn <= 5'd0; phase <= 1'b0; div <= 16'd0; gap <= 4'd0;
            dout_d <= 1'b0; edge_cnt <= 12'd0;
            sh <= 12'd0; cmd <= CMD_X;
            busy <= 1'b0; valid <= 1'b0;
            x_pos <= 12'd0; y_pos <= 12'd0;
            tp_dclk <= 1'b0; tp_cs_n <= 1'b1; tp_din <= 1'b0;
        end else begin
            valid <= 1'b0;

            case (st)
                //---------------------------------------------------------
                S_IDLE: begin
                    tp_cs_n <= 1'b1;
                    tp_dclk <= 1'b0;
                    tp_din  <= 1'b0;
                    busy    <= 1'b0;
                    bitn    <= 5'd0;
                    div     <= 16'd0;
                    phase   <= 1'b0;
                    if (start) begin
                        st   <= S_X;
                        cmd  <= CMD_X;
                        busy <= 1'b1;
                        tp_cs_n <= 1'b0;    // 拉低片选，开始转换
                        // 每轮事务开始前清掉诊断量
                        edge_cnt <= 12'd0;
                        dbg_low  <= 1'b0;
                    end
                end

                //---------------------------------------------------------
                // 两次转换用同一套时序：24 拍，8 位命令 + 1 位忙 + 12 位结果
                //---------------------------------------------------------
                S_X, S_Y: begin
                    if (tick) begin
                        div <= 16'd0;

                        if (phase == 1'b0) begin
                            // ---- DCLK 低：准备 DIN，同时把 DCLK 拉高 ----
                            //   bit 0..7 发命令（MSB 先出）
                            if (bitn < 5'd8)
                                tp_din <= cmd[3'd7 - bitn[2:0]];
                            else
                                tp_din <= 1'b0;     // 命令之后 DIN 保持低
                            tp_dclk <= 1'b1;
                            phase   <= 1'b1;
                        end else begin
                            // ---- DCLK 高：采样 DOUT，然后拉低 DCLK ----
                            //   结果位按 MSB 先出：第 9 位是 bit11，第 20 位是 bit0
                            if (is_dat)
                                sh[5'd20 - bitn] <= tp_dout;

                            // 数 DOUT 跳变 + 记录有没有见过低电平（整个事务范围）
                            // ⚠️ 这里又是那个坑：RTL 里不能用 === / !==（仿真专用、
                            //   不可综合，综合器会替换掉并报 [Synth 8-589]）。
                            //   账本第 68 条刚记过一次，写这里时又犯了 ——
                            //   所以"每次构建都数一遍日志里的 WARNING 行数"这条纪律
                            //   不是形式主义，它是唯一能兜住这类疏漏的东西。
                            if (tp_dout != dout_d)
                                edge_cnt <= edge_cnt + 1'b1;
                            if (tp_dout == 1'b0)
                                dbg_low <= 1'b1;
                            tp_dclk <= 1'b0;
                            phase   <= 1'b0;

                            dout_d <= tp_dout;

                            if (bitn == 5'd23) begin
                                // 一次转换结束
                                bitn <= 5'd0;
                                if (st == S_Y)
                                    dbg_edges <= edge_cnt;   // 两次都读完再快照
                                if (st == S_X) begin
                                    // 存下 X，然后【必须先把 nCS 抬起来】再读 Y。
                                    // ⚠️ 这不是可有可无的细节：XPT2046 只在
                                    //    nCS 下降沿之后的头 8 位采样 DIN，
                                    //    保持 CS 低继续打时钟只会用【旧命令】
                                    //    再转一次同一个通道，换不了通道。
                                    //    这个 bug 是行为模型抓出来的（见 TB）。
                                    //    sh 此刻已经完整：最后一位结果在 bitn=20
                                    //    采到，到这里已经过了 3 拍，非阻塞早就落定。
                                    x_pos <= sh;
                                    gap   <= 4'd0;
                                    st    <= S_GAP;
                                end else begin
                                    st <= S_DONE;
                                end
                            end else begin
                                bitn <= bitn + 1'b1;
                            end
                        end
                    end else begin
                        div <= div + 1'b1;
                    end
                end

                //---------------------------------------------------------
                // 抬起 nCS 几个周期，让器件结束本次事务（也顺便按 PD=00 进掉电）
                //---------------------------------------------------------
                S_GAP: begin
                    tp_cs_n <= 1'b1;
                    tp_dclk <= 1'b0;
                    tp_din  <= 1'b0;
                    bitn    <= 5'd0;
                    phase   <= 1'b0;
                    div     <= 16'd0;
                    if (gap == GAP_CYC - 1) begin
                        cmd     <= CMD_Y;
                        tp_cs_n <= 1'b0;    // 重新拉低，开始第二次转换
                        st      <= S_Y;
                    end else begin
                        gap <= gap + 1'b1;
                    end
                end

                //---------------------------------------------------------
                S_DONE: begin
                    tp_cs_n <= 1'b1;        // 抬片选，让器件进入掉电
                    tp_dclk <= 1'b0;
                    y_pos   <= sh;
                    valid   <= 1'b1;
                    busy    <= 1'b0;
                    st      <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
