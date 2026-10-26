//////////////////////////////////////////////////////////////////////////////////
// Company:        个人项目 / SonicTwin-Engine
// Engineer:       flyingyu
//
// Create Date:    2026-10-26
// Design Name:    tmds_enc
// Module Name:    tmds_enc
// Project Name:   音速双擎（SonicTwin-Engine）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    tmds_enc.v —— TMDS 8b/10b 编码器（DVI / HDMI 的数据通道编码）
//                 【为什么必须自己写】
//                 Xilinx 没有提供 TMDS 编码的"原语"（能在代码里例化一个名字就出来的那种）。
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns/1ps

`default_nettype none

module tmds_enc (
    input  wire        clk,         // 像素时钟
    input  wire        rst_n,

    input  wire [7:0]  din,         // 像素分量（8 位）
    input  wire        c0,          // 控制位 0（蓝通道 = hsync）
    input  wire        c1,          // 控制位 1（蓝通道 = vsync）
    input  wire        de,          // 数据有效（= VDE，消隐期为 0）

    output reg  [9:0]  dout         // TMDS 字符（10 位，输出比输入晚 2 拍）
);

    //-------------------------------------------------------------------------
    // 统计 din 里 1 的个数（0..8）
    //-------------------------------------------------------------------------
    wire [3:0] n1_d = {2'b0, din[7]} + {2'b0, din[6]} + {2'b0, din[5]} + {2'b0, din[4]}
                    + {2'b0, din[3]} + {2'b0, din[2]} + {2'b0, din[1]} + {2'b0, din[0]};

    //-------------------------------------------------------------------------
    // 第一级：D -> q_m
    //   q_m[8] 是"这一组有没有被反相"的标志，第二级还要用它。
    //   两个分支都是"前缀异或"：q_m[k] 其实等于 D[0]^D[1]^...^D[k]
    //   （XNOR 分支就是异或之后再取反）。这样写省掉了链式依赖的中间量。
    //-------------------------------------------------------------------------
    reg  [8:0] q_m;

    always @(posedge clk) begin
        if (!rst_n) begin
            q_m <= 9'd0;
        end else if ((n1_d > 4'd4) || ((n1_d == 4'd4) && (din[0] == 1'b0))) begin
            // 1 偏多（或 4:4 且 LSB=0）-> 走 XNOR 链 + 标记"已反相"
            q_m[0] <= din[0];
            q_m[1] <= din[0] ~^ din[1];
            q_m[2] <= din[0] ~^ din[1] ~^ din[2];
            q_m[3] <= din[0] ~^ din[1] ~^ din[2] ~^ din[3];
            q_m[4] <= din[0] ~^ din[1] ~^ din[2] ~^ din[3] ~^ din[4];
            q_m[5] <= din[0] ~^ din[1] ~^ din[2] ~^ din[3] ~^ din[4] ~^ din[5];
            q_m[6] <= din[0] ~^ din[1] ~^ din[2] ~^ din[3] ~^ din[4] ~^ din[5] ~^ din[6];
            q_m[7] <= din[0] ~^ din[1] ~^ din[2] ~^ din[3] ~^ din[4] ~^ din[5] ~^ din[6] ~^ din[7];
            q_m[8] <= 1'b0;
        end else begin
            // 0 偏多 -> 走 XOR 链 + 标记"未反相"
            q_m[0] <= din[0];
            q_m[1] <= din[0] ^  din[1];
            q_m[2] <= din[0] ^  din[1] ^  din[2];
            q_m[3] <= din[0] ^  din[1] ^  din[2] ^  din[3];
            q_m[4] <= din[0] ^  din[1] ^  din[2] ^  din[3] ^  din[4];
            q_m[5] <= din[0] ^  din[1] ^  din[2] ^  din[3] ^  din[4] ^  din[5];
            q_m[6] <= din[0] ^  din[1] ^  din[2] ^  din[3] ^  din[4] ^  din[5] ^  din[6];
            q_m[7] <= din[0] ^  din[1] ^  din[2] ^  din[3] ^  din[4] ^  din[5] ^  din[6] ^  din[7];
            q_m[8] <= 1'b1;
        end
    end

    //-------------------------------------------------------------------------
    // q_m[7:0] 里 1 的个数（0..8）
    //-------------------------------------------------------------------------
    wire [3:0] n1_qm = {2'b0, q_m[7]} + {2'b0, q_m[6]} + {2'b0, q_m[5]} + {2'b0, q_m[4]}
                     + {2'b0, q_m[3]} + {2'b0, q_m[2]} + {2'b0, q_m[1]} + {2'b0, q_m[0]};

    //-------------------------------------------------------------------------
    // DE/C0/C1 打一拍，跟 q_m 对齐（第二级要用）
    //-------------------------------------------------------------------------
    reg de_m, c0_m, c1_m;

    always @(posedge clk) begin
        if (!rst_n) begin
            de_m <= 1'b0;  c0_m <= 1'b0;  c1_m <= 1'b0;
        end else begin
            de_m <= de;    c0_m <= c0;    c1_m <= c1;
        end
    end

    //-------------------------------------------------------------------------
    // 第二级：q_m -> Q
    //   cnt = "运行不一致度"：到目前为止累计的 (1 的个数 - 0 的个数)，
    //   用来保证长时间看 0/1 数量平衡（DC 平衡）。
    //   范围大约 -10..+10，所以用 5 位【有符号】。
    //-------------------------------------------------------------------------
    reg signed [4:0] cnt;

    always @(posedge clk) begin
        if (!rst_n) begin
            cnt  <= 5'sd0;
            dout <= 10'd0;
        end else if (!de_m) begin
            // ---------------- 控制期：发同步码，不一致度清零 ----------------
            cnt <= 5'sd0;
            case ({c1_m, c0_m})
                2'b00: dout <= 10'b1101010100;
                2'b01: dout <= 10'b0010101011;
                2'b10: dout <= 10'b0101010100;
                2'b11: dout <= 10'b1010101011;
                default: dout <= 10'b1101010100;   // 不会发生（2 位case 已穷举），只为消 lint
            endcase
        end else if ((cnt == 5'sd0) || (n1_qm == 4'd4)) begin
            // -------- 不一致度为 0 或 q_m 本身正好平衡：按 q_m[8] 决定 --------
            dout <= {~q_m[8], q_m[8], q_m[8] ? q_m[7:0] : ~q_m[7:0]};
            if (q_m[8])
                cnt <= cnt + (n1_qm + n1_qm - 5'd8);        // +(N1-N0)
            else
                cnt <= cnt + (5'd8 - n1_qm - n1_qm);        // +(N0-N1)
        end else if (((cnt > 5'sd0) && (n1_qm > 4'd4)) ||
                     ((cnt < 5'sd0) && (n1_qm < 4'd4))) begin
            // ---------------- 不一致度会变大：反相输出压回来 ----------------
            dout <= {1'b1, q_m[8], ~q_m[7:0]};
            cnt  <= cnt + {3'b0, q_m[8], 1'b0} + (5'd8 - n1_qm - n1_qm);
        end else begin
            // ---------------- 不一致度会变小：原样输出 ----------------
            dout <= {1'b0, q_m[8], q_m[7:0]};
            cnt  <= cnt - {3'b0, ~q_m[8], 1'b0} + (n1_qm + n1_qm - 5'd8);
        end
    end

endmodule

`default_nettype wire
