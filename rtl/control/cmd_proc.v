//=============================================================================
// cmd_proc.v - UART 命令解析（ASCII，给人在终端里敲）
//-----------------------------------------------------------------------------
// 【命令格式】一句话：一个字母 + 两位十六进制，回车生效。
//
//     V07<回车>     设置 VIEW   = 0x07（三视图全开）
//     V01<回车>     只开柱状
//     H02<回车>     色相每 4 帧滚一级（0 = 不滚）
//     G05<回车>     波形增益
//     B01<回车>     背景模式
//     A01<回车>     打开自动循环视图
//     ?<回车>       回传当前全部配置
//
//   字母映射： V=VIEW  S=STYLE  H=HUESPD  G=WAVEG  B=BGMODE  A=AUTO
//   容错：只写一位十六进制也接受（例 `V7`）；分隔符只认 \r 和 \n，其它字符忽略。
//
// 【为什么做成 ASCII 而不是二进制】
//   二进制协议（地址字节 + 数据字节）实现更简单，但必须在电脑上写脚本才能用。
//   ASCII 可以直接用 minicom / screen / 串口助手敲，调试体验天差地别。
//
// 【回执】
//   上电时主动发一行横幅 + 当前配置；收到 `?` 也回一行。
//   这样"板子活着吗""参数改对了吗"一眼就能看出来。
//=============================================================================
`timescale 1ns/1ps

module cmd_proc #(
    parameter integer NREG = 6
) (
    input  wire       clk,
    input  wire       rst_n,

    //-------------------- UART 接收 --------------------
    input  wire [7:0] rx_data,
    input  wire       rx_valid,

    //-------------------- UART 发送 --------------------
    output reg  [7:0] tx_data,
    output reg        tx_send,
    input  wire       tx_busy,

    //-------------------- 配置寄存器（读）--------------------
    input  wire [7:0] cfg_view,
    input  wire [7:0] cfg_style,
    input  wire [7:0] cfg_hue_spd,
    input  wire [7:0] cfg_wave_gain,
    input  wire [7:0] cfg_bg_mode,
    input  wire [7:0] cfg_auto,

    //-------------------- 写端口（给 ui_ctrl）--------------------
    output reg        wr_en,
    output reg  [3:0] wr_addr,
    output reg  [7:0] wr_data
);

    //=========================================================================
    // 1. 解析状态机
    //=========================================================================
    localparam [2:0] S_CMD = 3'd0,   // 等字母
                     S_HI  = 3'd1,   // 等高位 hex
                     S_LO  = 3'd2,   // 等低位 hex
                     S_END = 3'd3;   // 等回车

    reg [2:0] st;
    reg [3:0] addr_r;
    reg [7:0] hi_r;

    // 十六进制字符 -> 值；不是 hex 返回 4'hF
    function [3:0] hexval;
        input [7:0] c;
        begin
            if      (c >= "0" && c <= "9") hexval = c - "0";
            else if (c >= "A" && c <= "F") hexval = c - "A" + 4'd10;
            else if (c >= "a" && c <= "f") hexval = c - "a" + 4'd10;
            else                           hexval = 4'hF;
        end
    endfunction

    // 字母 -> 寄存器地址；不认识返回 4'hF
    function [3:0] cmdidx;
        input [7:0] c;
        begin
            case (c)
                "V", "v": cmdidx = 4'h0;
                "S", "s": cmdidx = 4'h1;
                "H", "h": cmdidx = 4'h2;
                "G", "g": cmdidx = 4'h3;
                "B", "b": cmdidx = 4'h4;
                "A", "a": cmdidx = 4'h5;
                default : cmdidx = 4'hF;
            endcase
        end
    endfunction

    wire is_term = (rx_data == 8'h0D) || (rx_data == 8'h0A);    // \r 或 \n
    wire is_hex  = (hexval(rx_data) != 4'hF);

    //=========================================================================
    // 2. 回执缓冲（20 字节）
    //    "V07 S00 H02 G03 B0\r\n"        —— 共 18 字符 + CRLF = 20
    //
    //    字段布局（这是【协议的唯一真相源】，上位机脚本按这个解析）：
    //        [0] 'V'  [1:2] view 2位hex
    //        [3] ' '  [4] 'S'  [5:6] style 2位hex
    //        [7] ' '  [8] 'H'  [9:10] hue_spd 2位hex
    //        [11] ' ' [12] 'G' [13:14] wave_gain 2位hex
    //        [15] ' ' [16] 'B' [17]    bg_mode 【1 位】hex
    //        [18] CR  [19] LF
    //
    //    ⚠️ 注意两个容易写错的地方：
    //      ①  B 只有【1 位】hex（直接取 cfg_bg_mode[3:0]），不是 2 位；
    //      ②  回执里【没有】A（cfg_auto）字段，虽然 A 是合法命令。
    //    这个注释以前写成 "V07 S00 H02 G03 B00 A00\r\n"（24 字符），
    //    和代码实际产生的 18 字符对不上 —— 属于账本第 34 条
    //    「文档数字凭印象写」的同类问题。
    //=========================================================================
    reg [7:0] tbuf [0:19];
    integer   ti;

    function [7:0] hexchar;         // 0..15 -> '0'..'F'
        input [3:0] v;
        begin
            hexchar = (v < 4'd10) ? ("0" + v) : ("A" + v - 4'd10);
        end
    endfunction

    task fill_tbuf;
        begin
            tbuf[0] = "V"; tbuf[1] = hexchar(cfg_view[7:4]);     tbuf[2] = hexchar(cfg_view[3:0]);
            tbuf[3] = " "; tbuf[4] = "S"; tbuf[5] = hexchar(cfg_style[7:4]);
            tbuf[6] = hexchar(cfg_style[3:0]);
            tbuf[7] = " "; tbuf[8] = "H"; tbuf[9]  = hexchar(cfg_hue_spd[7:4]);
            tbuf[10] = hexchar(cfg_hue_spd[3:0]);
            tbuf[11] = " "; tbuf[12] = "G"; tbuf[13] = hexchar(cfg_wave_gain[7:4]);
            tbuf[14] = hexchar(cfg_wave_gain[3:0]);
            tbuf[15] = " "; tbuf[16] = "B"; tbuf[17] = hexchar(cfg_bg_mode[3:0]);
            tbuf[18] = 8'h0D;
            tbuf[19] = 8'h0A;
        end
    endtask

    //=========================================================================
    // 3. 发送调度：上电发一次横幅，收到 '?' 再发一次
    //=========================================================================
    reg        tx_go;       // 请求发送整个缓冲区
    reg [4:0]  txc;         // 已发到第几个
    reg [31:0] power_cnt;   // 50ms @48MHz = 2.4M，16 位装不下
    reg        did_banner;

    localparam integer BANNER_DLY = 48_000_000 / 1000 * 50;     // 上电 50 ms 后发

    //=========================================================================
    // 4. 主逻辑
    //=========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            st         <= S_CMD;
            addr_r     <= 4'd0;
            hi_r       <= 8'd0;
            wr_en      <= 1'b0;
            wr_addr    <= 4'd0;
            wr_data    <= 8'd0;
            tx_data    <= 8'd0;
            tx_send    <= 1'b0;
            tx_go      <= 1'b0;
            txc        <= 5'd0;
            power_cnt  <= 32'd0;        // 和声明一致（账本第 42 条：16 位装不下 2.4M）
            did_banner <= 1'b0;
            for (ti = 0; ti < 20; ti = ti + 1) tbuf[ti] <= 8'h20;
        end else begin
            wr_en   <= 1'b0;
            tx_send <= 1'b0;

            //---------------------------------------------------------------
            // 上电横幅：等 I2C 之类的杂事过去再发，避免抢占
            //---------------------------------------------------------------
            if (!did_banner) begin
                if (power_cnt == BANNER_DLY[31:0] - 1) begin
                    fill_tbuf();
                    tx_go      <= 1'b1;
                    did_banner <= 1'b1;
                end else
                    power_cnt <= power_cnt + 1'b1;
            end

            //---------------------------------------------------------------
            // 解析
            //---------------------------------------------------------------
            if (rx_valid) begin
                case (st)
                    S_CMD: begin
                        if (rx_data == "?") begin
                            fill_tbuf();
                            tx_go <= 1'b1;
                        end else if (cmdidx(rx_data) != 4'hF) begin
                            addr_r <= cmdidx(rx_data);
                            st     <= S_HI;
                        end
                        // 其它字符一律忽略（回车、空白等）
                    end

                    S_HI: begin
                        if (rx_data == "?") begin
                            // '?' 是【全局】命令：命令写了一半也能回读。
                            // 上板踩过：S_HI/S_LO 里不认 '?'，它就掉进“非法字符”
                            // 分支被吃掉，用户要按两次 '?' 才看得到回执；
                            // 更糟的是下一次命令的字母也被吃、
                            // 第一个 hex 位会和残留的 hi_r 拼成错值。
                            fill_tbuf();
                            tx_go <= 1'b1;
                            st    <= S_CMD;
                        end else if (is_hex) begin
                            hi_r <= {4'd0, hexval(rx_data)};
                            st   <= S_LO;
                        end else begin
                            // 其余非法字符（含 \r/\n）：放弃当前命令，回主态。
                            // 没有这个 else 就会永久卡住，之后所有命令全死。
                            st <= S_CMD;
                        end
                    end

                    S_LO: begin
                        if (rx_data == "?") begin
                            fill_tbuf();
                            tx_go <= 1'b1;
                            st    <= S_CMD;
                        end else if (is_hex) begin
                            // 立刻执行（不必等回车，敲起来更顺手）
                            wr_en   <= 1'b1;
                            wr_addr <= addr_r;
                            wr_data <= {hi_r[3:0], hexval(rx_data)};
                            st      <= S_CMD;
                        end else if (is_term) begin
                            // 只写了一位：当成高 4 位用
                            wr_en   <= 1'b1;
                            wr_addr <= addr_r;
                            wr_data <= {hi_r[3:0], 4'd0};
                            st      <= S_CMD;
                        end else begin
                            st <= S_CMD;                // 同上：非法字符要能脱困
                        end
                    end

                    default: st <= S_CMD;
                endcase
            end

            //---------------------------------------------------------------
            // 发送调度：每次 tx_busy 落下就发下一个字节
            //---------------------------------------------------------------
            if (tx_go) begin
                if (!tx_busy && !tx_send) begin
                    tx_data <= tbuf[txc];
                    tx_send <= 1'b1;
                    if (txc == 5'd19) begin
                        txc   <= 5'd0;
                        tx_go <= 1'b0;
                    end else
                        txc <= txc + 1'b1;
                end
            end
        end
    end

endmodule
