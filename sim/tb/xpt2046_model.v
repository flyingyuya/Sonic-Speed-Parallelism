//=============================================================================
// xpt2046_model.v - XPT2046 从机行为模型（仿真用，不综合）
//-----------------------------------------------------------------------------
// 【为什么值得写一个行为模型】
//   SPI 这类协议最容易错在"边沿对不对"：器件在下降沿改数据、主机在上升沿采样，
//   差半个周期就整帧错位。光看 RTL 看不出来，而且波形上也不明显。
//   有个从机模型就能把 DUT 的行为【逐位】核对：
//     ① 它按 XPT2046 的时序吐数据（下降沿更新、忙位、12 位 MSB 先出）
//     ② 它把收到的命令字节记下来，测试可以查"你发的命令对不对"
//     ③ 期望值由测试给，所以能验证"读回来的坐标是不是我期望的那个"
//
// 【这里的时序按 XPT2046 手册来】
//   · nCS 拉低后，第一个 DCLK 上升沿开始收命令
//   · 命令 8 位（MSB 先出）之后是 1 位忙位（拉低），再 12 位结果（MSB 先出）
//   · DOUT 在 DCLK 的【下降沿】更新
//=============================================================================
`timescale 1ns/1ps

module xpt2046_model #(
    parameter integer TDCLK_NS = 500        // DCLK 半周期（仅用于内部延时检查）
) (
    input  wire        tp_dclk,
    input  wire        tp_cs_n,
    input  wire        tp_din,
    output reg         tp_dout,

    //--------------------- 测试侧控制 ---------------------
    input  wire [11:0] force_x,     // 读 X 时返回这个值
    input  wire [11:0] force_y,     // 读 Y 时返回这个值
    output reg  [7:0]  last_cmd,    // 最近收到的命令字节
    output reg  [3:0]  n_cmd,       // 一共收到几个命令（用来查"读了几次"）
    output reg  [7:0]  n_dclk       // 最近一次转换里数到几个 DCLK
);

    integer    bitn;
    reg [7:0]  sh;          // 收到的命令移位
    reg [11:0] result;      // 本次要返回的 12 位
    reg        rcv_cmd;     // 是否已经收齐命令

    initial begin
        bitn = 0; sh = 8'h00; result = 12'h000;
        rcv_cmd = 1'b0; tp_dout = 1'b1;
        last_cmd = 8'h00; n_cmd = 4'd0; n_dclk = 8'd0;
    end

    //---------------------------------------------------------------------
    // nCS 下降沿：开始一次转换
    //---------------------------------------------------------------------
    always @(negedge tp_cs_n) begin
        bitn    = 0;
        sh      = 8'h00;
        rcv_cmd = 1'b0;
        n_dclk  = 8'd0;
        tp_dout = 1'b1;         // 忙位之前先给高
    end

    //---------------------------------------------------------------------
    // DCLK 上升沿：采样 DIN（前 8 位），并把 DOUT 摆好
    //   注意：真实的 XPT2046 是在【下降沿】更新 DOUT，
    //   这里为了让测试好写，改成在上升沿之后一点点更新 —— 效果一样，
    //   因为主机是在【下一个上升沿】才采样。
    //---------------------------------------------------------------------
    always @(posedge tp_dclk) begin
        if (!tp_cs_n) begin
            if (bitn < 8) begin
                // 收命令（MSB 先出）
                sh = {sh[6:0], tp_din};
                if (bitn == 7) begin
                    rcv_cmd  = 1'b1;
                    last_cmd = {sh[6:0], tp_din};
                    n_cmd    = n_cmd + 1'b1;
                    // 按 A2:A0 选通道。命令字节是 S A2 A1 A0 MODE SER/DFR PD1 PD0，
                    // 所以通道在 bit6:4 —— 一开始写成 [5:3]，把 MODE 位当成了通道，
                    // 结果两个通道都落到 default，读回来永远是 0xFFF。
                    case ({sh[6:4]})
                        3'b101:  result = force_x;
                        3'b001:  result = force_y;
                        default: result = 12'hFFF;
                    endcase
                end
            end
            bitn   = bitn + 1;
            n_dclk = n_dclk + 1'b1;
        end
    end

    //---------------------------------------------------------------------
    // 下降沿更新 DOUT：bit 8 是忙位（低），bit 9..20 是 12 位结果
    //---------------------------------------------------------------------
    always @(negedge tp_dclk) begin
        if (!tp_cs_n) begin
            // 位序（0 基）：0..7 = 命令，8 = 忙位，9..20 = 12 位结果（MSB 先出）
            if (bitn == 8)       tp_dout = 1'b0;              // 忙位
            else if (bitn >= 9 && bitn <= 20)
                tp_dout = result[20 - bitn];                  // MSB 先出
            else if (bitn > 20)  tp_dout = 1'b0;
        end
    end

endmodule
