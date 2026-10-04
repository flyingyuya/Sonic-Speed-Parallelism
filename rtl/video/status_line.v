//=============================================================================
// status_line.v - 状态行生成器
//-----------------------------------------------------------------------------
// 【干什么】
//   把当前配置拼成一行文字，写进 text_buf：
//
//       V7 S0 H6 G8 B0 D0
//       ↑  ↑
//       |  └─ 该字段的值（十六进制，和 UART 回执同一个约定）
//       └──── 字段名
//
//   这样屏上显示的内容和串口 '?' 回读的内容【完全一致】，
//   调试时两边可以对着看，不用换算。
//
// 【什么时候刷】
//   只在【配置真的变了】的时候重写一遍，不是每帧都刷。
//   做法：存一份上次的配置，和新值比较，不同就启动一次"逐字符写入"。
//   写一次只要 17 个周期（text_buf 每周期能收一个字符），
//   相对于 12 ms 一帧完全可以忽略。
//
// 【为什么不做成"每帧重刷"】
//   每帧重刷要多一路比较和状态机开销，而且会在帧中间改缓冲 ——
//   虽然肉眼看不见，但会让"帧内一致性"这条验证判据变复杂。
//   按需刷新最干净。
//=============================================================================
`timescale 1ns/1ps

module status_line #(
    parameter integer NLEN = 17        // 状态行字符数
) (
    input  wire        clk,
    input  wire        rst_n,

    //--------------------- 要显示的配置 ---------------------
    input  wire [7:0]  cfg_view,
    input  wire [7:0]  cfg_style,
    input  wire [7:0]  cfg_hue_spd,
    input  wire [7:0]  cfg_wave_gain,
    input  wire [7:0]  cfg_bg_mode,
    input  wire [7:0]  cfg_demo,

    //--------------------- 写 text_buf ---------------------
    output reg         we,
    output reg  [15:0] waddr,
    output reg  [7:0]  wdata
);

    //=========================================================================
    // 1. 配置变化检测
    //=========================================================================
    reg [7:0] v_d, s_d, h_d, g_d, b_d, m_d;

    wire changed = (cfg_view      !== v_d) || (cfg_style     !== s_d) ||
                   (cfg_hue_spd   !== h_d) || (cfg_wave_gain !== g_d) ||
                   (cfg_bg_mode   !== b_d) || (cfg_demo      !== m_d);

    //=========================================================================
    // 2. 逐字符写入
    //=========================================================================
    reg [4:0] cnt;
    reg       busy;

    // 十六进制数字 -> ASCII（'0'..'9' / 'A'..'F'）
    function [7:0] hexc;
        input [3:0] v;
        begin
            hexc = (v < 4'd10) ? ("0" + v) : ("A" + v - 4'd10);
        end
    endfunction

    // 第 i 个字符是什么
    reg [7:0] ch;
    always @(*) begin
        case (cnt)
            //        "V7 S0 H6 G8 B0 D0"
            5'd0:  ch = "V";     5'd1:  ch = hexc(cfg_view[3:0]);
            5'd2:  ch = " ";     5'd3:  ch = "S";
            5'd4:  ch = hexc(cfg_style[3:0]);
            5'd5:  ch = " ";     5'd6:  ch = "H";
            5'd7:  ch = hexc(cfg_hue_spd[3:0]);
            5'd8:  ch = " ";     5'd9:  ch = "G";
            5'd10: ch = hexc(cfg_wave_gain[3:0]);
            5'd11: ch = " ";     5'd12: ch = "B";
            5'd13: ch = hexc(cfg_bg_mode[3:0]);
            5'd14: ch = " ";     5'd15: ch = "D";
            default: ch = hexc(cfg_demo[3:0]);
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            v_d <= 8'hFF; s_d <= 8'hFF; h_d <= 8'hFF;
            g_d <= 8'hFF; b_d <= 8'hFF; m_d <= 8'hFF;   // 上电必触发一次
            cnt <= 5'd0;
            busy <= 1'b0;
            we <= 1'b0;
            waddr <= 16'd0;
            wdata <= 8'h20;
        end else begin
            we <= 1'b0;

            if (!busy) begin
                // 配置变了就启动一次重写
                if (changed) begin
                    busy <= 1'b1;
                    cnt  <= 5'd0;
                end
            end else begin
                we    <= 1'b1;
                waddr <= {11'd0, cnt};
                wdata <= ch;
                if (cnt == NLEN - 1) begin
                    busy <= 1'b0;
                    // 记下这次写的是什么配置，下次只有再变才重写
                    v_d <= cfg_view;      s_d <= cfg_style;
                    h_d <= cfg_hue_spd;   g_d <= cfg_wave_gain;
                    b_d <= cfg_bg_mode;   m_d <= cfg_demo;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

endmodule
