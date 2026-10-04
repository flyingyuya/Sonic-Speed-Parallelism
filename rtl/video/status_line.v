//=============================================================================
// status_line.v - 状态行生成器
//-----------------------------------------------------------------------------
// 【干什么】
//   把当前配置拼成一行文字，写进 text_buf：
//
//       V7 S0 H6 G8 B0 D0        <- 第一行：配置（与 UART 回执同格式）
//       TX123 TY456              <- 第二行：触摸屏原始读数（十进制 3 位）
//       ↑  ↑
//       |  └─ 该字段的值
//       └──── 字段名
//
//   第二行是给【上板验证触摸管脚】用的：手指按下去，数字必须跟着变。
//   如果一直是 000 或者一直是 FFF，说明管脚推错了或者 SPI 没通。
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
    parameter integer NLEN = 17,       // 【每行】字符数（共 2 行 = NLEN*2 个）
    parameter integer NC   = 60        // text_buf 每行能放多少字符（地址换算用）
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
    input  wire [11:0] tp_x,            // 触摸屏原始 X（用于上板验证管脚）
    input  wire [11:0] tp_y,

    //--------------------- 写 text_buf ---------------------
    output reg         we,
    output reg  [15:0] waddr,
    output reg  [7:0]  wdata
);

    //=========================================================================
    // 1. 配置变化检测
    //=========================================================================
    reg [7:0]  v_d, s_d, h_d, g_d, b_d, m_d;
    reg [11:0] tx_d, ty_d;

    // ⚠️ 必须用 != 而不是 !==。
    //   `!==` 是【仿真专用】运算符（会比较 X/Z），**不可综合** ——
    //   综合器会自动替换成 != 并报 [Synth 8-589] 警告。
    //   这里用 != 是安全的：复位时 *_d 都被初始化成 8'hFF，不会出现 X。
    //   （TB 里用 ===/!== 没问题，因为 TB 不综合；RTL 里一律不要用。）
    wire changed = (cfg_view      != v_d) || (cfg_style     != s_d) ||
                   (cfg_hue_spd   != h_d) || (cfg_wave_gain != g_d) ||
                   (cfg_bg_mode   != b_d) || (cfg_demo      != m_d) ||
                   (tp_x != tx_d) || (tp_y != ty_d);

    //=========================================================================
    // 2. 逐字符写入
    //=========================================================================
    reg [5:0] cnt;
    reg       busy;

    // 十六进制数字 -> ASCII（'0'..'9' / 'A'..'F'）
    function [7:0] hexc;
        input [3:0] v;
        begin
            hexc = (v < 4'd10) ? ("0" + v) : ("A" + v - 4'd10);
        end
    endfunction

    // 12 位值 -> 3 位十进制 ASCII（触摸读数用十进制看着直观）
    function [7:0] dec3;
        input [11:0] v;
        input [1:0]  d;          // 0 = 百位，1 = 十位，2 = 个位
        reg [11:0]   t;
        begin
            case (d)
                2'd0:    t = v / 100;
                2'd1:    t = (v / 10) % 10;
                default: t = v % 10;
            endcase
            dec3 = "0" + t[7:0];
        end
    endfunction

    // 第 cnt 个字符是什么
    reg [7:0] ch;
    always @(*) begin
        // 第二行的列号（0..16）
        case (cnt)
            //-------- 第一行 "V7 S0 H6 G8 B0 D0" --------
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
            5'd16: ch = hexc(cfg_demo[3:0]);
            //-------- 第二行 "TX000 TY000" --------
            5'd17: ch = "T";     5'd18: ch = "X";
            5'd19: ch = dec3(tp_x, 2'd0);
            5'd20: ch = dec3(tp_x, 2'd1);
            5'd21: ch = dec3(tp_x, 2'd2);
            5'd22: ch = " ";     5'd23: ch = "T";
            5'd24: ch = "Y";
            5'd25: ch = dec3(tp_y, 2'd0);
            5'd26: ch = dec3(tp_y, 2'd1);
            5'd27: ch = dec3(tp_y, 2'd2);
            5'd28: ch = " ";     5'd29: ch = " ";
            5'd30: ch = " ";     5'd31: ch = " ";
            default: ch = " ";
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            v_d <= 8'hFF; s_d <= 8'hFF; h_d <= 8'hFF;
            g_d <= 8'hFF; b_d <= 8'hFF; m_d <= 8'hFF;   // 上电必触发一次
            tx_d <= 12'hFFF; ty_d <= 12'hFFF;
            cnt <= 6'd0;
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
                    cnt  <= 6'd0;
                end
            end else begin
                we    <= 1'b1;
                // ⚠️ text_buf 的地址是【行*NC + 列】，不是线性字符号。
                //   一开始直接发 cnt，第二行（cnt 17..33）就被写到了
                //   "第一行的第 17~33 列"，屏幕上第二行永远是空的。
                waddr <= {11'd0, (cnt / NLEN) * NC + (cnt % NLEN)};
                wdata <= ch;
                // 两行一起写：cnt 从 0 数到 NLEN*2-1
                if (cnt == NLEN*2 - 1) begin
                    busy <= 1'b0;
                    // 记下这次写的是什么配置，下次只有再变才重写
                    v_d <= cfg_view;      s_d <= cfg_style;
                    h_d <= cfg_hue_spd;   g_d <= cfg_wave_gain;
                    b_d <= cfg_bg_mode;   m_d <= cfg_demo;
                    tx_d <= tp_x;         ty_d <= tp_y;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

endmodule
