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
    parameter integer NLEN = 17,       // 【每行】字符数（共 3 行 = NLEN*3 个）
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
    input  wire [11:0] tp_edges,        // 诊断：最近一次转换 DOUT 跳变次数
    input  wire        tp_low,          // 诊断：DOUT 是否出现过低电平

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
    reg [11:0] te_d;
    reg        tl_d;

    // ⚠️ 必须用 != 而不是 !==。
    //   `!==` 是【仿真专用】运算符（会比较 X/Z），**不可综合** ——
    //   综合器会自动替换成 != 并报 [Synth 8-589] 警告。
    //   这里用 != 是安全的：复位时 *_d 都被初始化成 8'hFF，不会出现 X。
    //   （TB 里用 ===/!== 没问题，因为 TB 不综合；RTL 里一律不要用。）
    wire changed = (cfg_view      != v_d) || (cfg_style     != s_d) ||
                   (cfg_hue_spd   != h_d) || (cfg_wave_gain != g_d) ||
                   (cfg_bg_mode   != b_d) || (cfg_demo      != m_d) ||
                   (tp_x != tx_d) || (tp_y != ty_d) ||
                   (tp_edges != te_d) || (tp_low != tl_d);

    //=========================================================================
    // 2. 逐字符写入
    //=========================================================================
    reg [5:0] cnt;      // 0..NLEN*3-1（三行）
    reg       busy;

    // 十六进制数字 -> ASCII（'0'..'9' / 'A'..'F'）
    function [7:0] hexc;
        input [3:0] v;
        begin
            hexc = (v < 4'd10) ? ("0" + v) : ("A" + v - 4'd10);
        end
    endfunction

    // 12 位值 -> 4 位十进制 ASCII
    //   ⚠️ 必须是 4 位！12 位最大 4095，3 位装不下。
    //   第一版写的是"百位 = v/100"，v=4095 时算出 40，再 "0"+40 得到
    //   码 88 也就是字母 'X' —— 屏幕上显示出 "TXX95"，
    //   看起来像乱码，其实是在告诉你"读回来是 0xFFF"。
    function [7:0] dec4;
        input [11:0] v;
        input [2:0]  d;          // 0=千位 1=百位 2=十位 3=个位
        reg [11:0]   t;
        begin
            case (d)
                3'd0:    t = (v / 1000) % 10;
                3'd1:    t = (v / 100) % 10;
                3'd2:    t = (v / 10) % 10;
                default: t = v % 10;
            endcase
            dec4 = "0" + t[7:0];
        end
    endfunction

    //-------------------------------------------------------------------------
    // 字符表（cnt = 行*NLEN + 列）
    //
    //   第 1 行 (0..16)  : "V7 S0 H6 G8 B0 D0"      配置，与 UART 回执同格式
    //   第 2 行 (17..33) : "TX0000 TY0000"          触摸原始读数（4 位十进制）
    //   第 3 行 (34..50) : "E0000 L0"               诊断（DOUT 跳变数 / 见过低电平吗）
    //
    //   ⚠️ 12 位读数最大 4095，所以必须 4 位十进制 —— 3 位装不下，
    //      会把 v/100 算出 40 再 "0"+40 变成字母 'X'。
    //-------------------------------------------------------------------------
    reg [7:0] ch;
    always @(*) begin
        case (cnt)
            //-------- 第 1 行：配置 --------
            6'd0:  ch = "V";   6'd1:  ch = hexc(cfg_view[3:0]);
            6'd2:  ch = " ";   6'd3:  ch = "S";
            6'd4:  ch = hexc(cfg_style[3:0]);
            6'd5:  ch = " ";   6'd6:  ch = "H";
            6'd7:  ch = hexc(cfg_hue_spd[3:0]);
            6'd8:  ch = " ";   6'd9:  ch = "G";
            6'd10: ch = hexc(cfg_wave_gain[3:0]);
            6'd11: ch = " ";   6'd12: ch = "B";
            6'd13: ch = hexc(cfg_bg_mode[3:0]);
            6'd14: ch = " ";   6'd15: ch = "D";
            6'd16: ch = hexc(cfg_demo[3:0]);
            //-------- 第 2 行：触摸读数 "TX0000 TY0000" --------
            6'd17: ch = "T";   6'd18: ch = "X";
            6'd19: ch = dec4(tp_x, 3'd0);
            6'd20: ch = dec4(tp_x, 3'd1);
            6'd21: ch = dec4(tp_x, 3'd2);
            6'd22: ch = dec4(tp_x, 3'd3);
            6'd23: ch = " ";
            6'd24: ch = "T";   6'd25: ch = "Y";
            6'd26: ch = dec4(tp_y, 3'd0);
            6'd27: ch = dec4(tp_y, 3'd1);
            6'd28: ch = dec4(tp_y, 3'd2);
            6'd29: ch = dec4(tp_y, 3'd3);
            6'd30: ch = " ";   6'd31: ch = " ";   6'd32: ch = " ";   6'd33: ch = " ";
            //-------- 第 3 行：诊断 "E0000 L0" --------
            6'd34: ch = "E";
            6'd35: ch = dec4(tp_edges, 3'd0);
            6'd36: ch = dec4(tp_edges, 3'd1);
            6'd37: ch = dec4(tp_edges, 3'd2);
            6'd38: ch = dec4(tp_edges, 3'd3);
            6'd39: ch = " ";
            6'd40: ch = "L";
            6'd41: ch = tp_low ? "1" : "0";
            6'd42: ch = " ";   6'd43: ch = " ";   6'd44: ch = " ";
            6'd45: ch = " ";   6'd46: ch = " ";   6'd47: ch = " ";
            6'd48: ch = " ";   6'd49: ch = " ";   6'd50: ch = " ";
            default: ch = " ";
        endcase
    end

    always @(posedge clk) begin
        if (!rst_n) begin
            v_d <= 8'hFF; s_d <= 8'hFF; h_d <= 8'hFF;
            g_d <= 8'hFF; b_d <= 8'hFF; m_d <= 8'hFF;   // 上电必触发一次
            tx_d <= 12'hFFF; ty_d <= 12'hFFF;
            te_d <= 12'hFFF; tl_d <= 1'b1;
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
                // 三行一起写：cnt 从 0 数到 NLEN*3-1
                if (cnt == NLEN*3 - 1) begin
                    busy <= 1'b0;
                    // 记下这次写的是什么配置，下次只有再变才重写
                    v_d <= cfg_view;      s_d <= cfg_style;
                    h_d <= cfg_hue_spd;   g_d <= cfg_wave_gain;
                    b_d <= cfg_bg_mode;   m_d <= cfg_demo;
                    tx_d <= tp_x;         ty_d <= tp_y;
                    te_d <= tp_edges;     tl_d <= tp_low;
                end else begin
                    cnt <= cnt + 1'b1;
                end
            end
        end
    end

endmodule
