//=============================================================================
// xpt2046.v - XPT2046 电阻触摸屏控制器（四线 SPI）
//-----------------------------------------------------------------------------
// 【XPT2046 怎么读】
//   SPI 模式 0（空闲低、上升沿采样），一次转换 24 个 DCLK：
//
//     bit  0..7  : 主机发命令字节（MSB 先出）
//     bit  8     : 忙位（器件拉低，主机忽略）
//     bit  9..20 : 12 位转换结果（MSB 先出）
//     bit 21..23 : 补零
//
//   命令字节格式： S A2 A1 A0 MODE SER/DFR PD1 PD0
//     S        = 1（起始位）
//     A2:A0    = 通道。101 = X，001 = Y（本项目只用这两个）
//     MODE     = 0 -> 12 位（1 就是 8 位）
//     SER/DFR  = 1 -> 单端（0 是差分）
//     PD1:PD0  = 00 -> 转换后掉电，省电
//
//     所以：读 X 的命令 = 8'b1101_0000 = 0xD0
//           读 Y 的命令 = 8'b1001_0000 = 0x90
//
// 【DIN / DOUT 的边沿】
//   器件在 DCLK 的【下降沿】更新 DOUT，主机在【上升沿】采样。
//   所以本模块：低电平期间准备 DIN，高电平期间采 DOUT。
//
// 【为什么要读两次】
//   一次 start 读 X 再读 Y（两次 24 拍转换），读完后一起给出去。
//   这样上层拿到的 x/y 是同一时刻的，不会一个是一秒前的值。
//
// 【DCLK 频率】
//   XPT2046 手册上限 2 MHz。排线比较长，取 1 MHz 更稳。
//=============================================================================
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

    //--------------------- 引脚 ---------------------
    output reg         tp_dclk,
    output reg         tp_cs_n,
    output reg         tp_din,
    input  wire        tp_dout
);

    // 半周期分频系数：DCLK 的一个完整周期 = 2*DIV 个 clk
    localparam integer DIV = (CLK_HZ / (2 * SCLK_HZ)) < 1 ? 1 : (CLK_HZ / (2 * SCLK_HZ));

    localparam [7:0] CMD_X = 8'hD0;     // 101 -> X
    localparam [7:0] CMD_Y = 8'h90;     // 001 -> Y

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
    reg [7:0]  cmd;         // 当前在发的命令字节

    wire tick = (div == DIV - 1);

    // 当前位是不是"结果位"：bit 9..20 是 12 位结果（MSB 先出）
    wire is_dat = (bitn >= 5'd9) && (bitn <= 5'd20);

    always @(posedge clk) begin
        if (!rst_n) begin
            st <= S_IDLE;
            bitn <= 5'd0; phase <= 1'b0; div <= 16'd0; gap <= 4'd0;
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
                            tp_dclk <= 1'b0;
                            phase   <= 1'b0;

                            if (bitn == 5'd23) begin
                                // 一次转换结束
                                bitn <= 5'd0;
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
