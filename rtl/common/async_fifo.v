//=============================================================================
// async_fifo.v - 异步 FIFO（双时钟，格雷码指针，show-ahead 输出）
//-----------------------------------------------------------------------------
// 用途：本工程有两处必须跨时钟域传数据
//   ① BCLK 域（WM8960 输出的 3.072 MHz）→ clk_sys 域（48 MHz）
//      把 audio_rcv 采到的 24 bit 样本安全送进 DSP 流水线
//   ② clk_sys 域（48 MHz）→ clk_pix 域（12.5 MHz）
//      把频谱柱高送到显示扫描逻辑
//   两处的数据量都很小（深度 16~32），所以用分布式 RAM，不用 BRAM。
//
// 为什么不用 BRAM 做存储体：
//   BRAM 的读端口是【同步】的（地址进去、数据下一拍才出来）。要做成
//   show-ahead（rd_en 当拍数据就有效）就必须再加一级输出寄存器，于是
//   一次弹出之后要 2 拍才能补上新数据 —— 出现 1 拍气泡，吞吐率掉到 1/3。
//   深度只有 16~32 时，分布式 RAM 面积更小，而且【组合读端口】天然就是
//   show-ahead，一个寄存器都不用。深度上千时再考虑换 BRAM。
//
// 跨时钟域的核心：格雷码指针
//   二进制指针进位时会有多位同时翻转（0111 -> 1000 翻了 4 位）。
//   同步器恰好在翻转瞬间采样，就会采到一个"从来没存在过的地址"，
//   读侧于是误判空/满，数据全乱。
//   格雷码保证相邻两个码字只差 1 位，所以同步器的两级触发器要么采到
//   旧值、要么采到新值，不会采到非法值 —— 不需要握手，两级触发器搞定。
//
// 复位风格为什么是【同步】而不是 `or negedge rst_n`：
//   指针寄存器的值会一路传到 BRAM 的地址/使能脚（例如 fft_core 里
//   RAMB 的 WEBWE 就是由 empty -> in_pop -> we_a 决定的）。
//   带异步复位的寄存器在复位有效时会在两个时钟沿之间异步跳变，
//   时钟沿万一落在跳变中，BRAM 可能被非法地址/使能写坏 —— 而默认静态
//   时序分析【不覆盖】这条路径。Vivado 会为此报 REQP-1839。
//   改成同步复位后，复位走 D 端选择逻辑，不碰 FF 的 CLR 脚，DRC 干净。
//   前提：两个时钟在复位期间都必须一直运行（本工程由 MMCM 保证）。
//
// 空/满判据为什么不对称：
//   empty 比较的是【同域的两个格雷码指针】(rgray vs wgray 的同步版)，
//         格雷码直接比相等即可，不需要转二进制。
//   full  要判断"两个指针正好差 DEPTH"，这是算术运算，必须先转回二进制。
//   所以 full 比 empty 贵一点，这是这类 FIFO 的固有形态。
//=============================================================================
`timescale 1ns/1ps

module async_fifo #(
    parameter integer DW    = 24,       // 数据宽度
    parameter integer DEPTH = 16        // 深度（建议取 2 的幂）
) (
    //------------------------ 写侧（写时钟域）------------------------
    input  wire                     wclk,
    input  wire                     wrst_n,
    input  wire                     wr_en,
    input  wire [DW-1:0]            din,
    output wire                     full,
    output wire [$clog2(DEPTH):0]   wr_level,   // 写侧看到的占用数
    output wire [7:0]               wr_drop,    // 写满被丢弃的次数（诊断用）

    //------------------------ 读侧（读时钟域）------------------------
    input  wire                     rclk,
    input  wire                     rrst_n,
    input  wire                     rd_en,
    output wire [DW-1:0]            dout,       // show-ahead：!empty 当拍即有效
    output wire                     empty,
    output wire [$clog2(DEPTH):0]   rd_level
);

    localparam integer AW = $clog2(DEPTH);      // 地址位宽
    localparam integer PW = AW + 1;             // 指针位宽（多一位用来判满）

    //-------------------------------------------------------------------------
    // 存储体：分布式 RAM，组合读端口
    //   不加复位 —— 复位存储体会综合出 DEPTH x DW 个带复位端的触发器，
    //   白白增加扇出、恶化时序，而且 FIFO 只要能保证"写过的位置才可能被读"
    //   就够了（由指针同步保证），不需要清零。
    //-------------------------------------------------------------------------
    (* ram_style = "distributed" *) reg [DW-1:0] mem [0:DEPTH-1];

    //-------------------------------------------------------------------------
    // 格雷码 <-> 二进制转换
    //   bin2gray:  g = b ^ (b >> 1)
    //   gray2bin: 从最高位往下逐位异或（组合逻辑，PW 级）
    //-------------------------------------------------------------------------
    // 非 ANSI 风格参数声明 —— Verible 的 explicit-function-task-parameter-type
    // 规则只对 ANSI 风格 (input [N:0] x) 报错，本工程统一用这种写法
    function [PW-1:0] bin2gray;
        input [PW-1:0] b;
        begin
            bin2gray = b ^ (b >> 1);
        end
    endfunction

    function [PW-1:0] gray2bin;
        input [PW-1:0] g;
        integer i;
        begin
            gray2bin[PW-1] = g[PW-1];
            for (i = PW - 2; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    //-------------------------------------------------------------------------
    // 指针与同步器声明（写域和读域各一套）
    //
    // ASYNC_REG = "TRUE" 是给工具看的标记，作用有三个：
    //   ① 把这两级触发器紧挨着放（缩短第一级的布线延迟，提高 MTBF）
    //   ② 禁止工具对它们做 retiming / 复制 / 优化掉
    //   ③ Vivado 的 report_cdc 会因为打了这个标记才判定为"安全同步器"
    // 养成习惯：所有跨时钟域的同步器触发器都要打这个属性。
    //-------------------------------------------------------------------------
    reg  [PW-1:0] wbin,  wgray;         // 写指针（写域）
    reg  [PW-1:0] rbin,  rgray;         // 读指针（读域）

    (* ASYNC_REG = "TRUE" *) reg [PW-1:0] rgray_w1, rgray_w2;  // 读指针 -> 写域
    (* ASYNC_REG = "TRUE" *) reg [PW-1:0] wgray_r1, wgray_r2;  // 写指针 -> 读域

    //=========================================================================
    //                              写时钟域
    //=========================================================================

    // 读指针（格雷码）同步到写域
    always @(posedge wclk) begin
        if (!wrst_n) begin
            rgray_w1 <= {PW{1'b0}};
            rgray_w2 <= {PW{1'b0}};
        end else begin
            rgray_w1 <= rgray;
            rgray_w2 <= rgray_w1;
        end
    end

    wire [PW-1:0] rbin_w = gray2bin(rgray_w2);

    // 写指针推进
    always @(posedge wclk) begin
        if (!wrst_n) begin
            wbin  <= {PW{1'b0}};
            wgray <= {PW{1'b0}};
        end else if (wr_en && !full) begin
            wbin  <= wbin + 1'b1;
            wgray <= bin2gray(wbin + 1'b1);
        end
    end

    // 写存储体（同一 always 块内同时更新指针和数据，避免多驱动）
    always @(posedge wclk) begin
        if (wr_en && !full)
            mem[wbin[AW-1:0]] <= din;
    end

    // 满：占用数正好等于 DEPTH。
    //   用【当前】的 wbin 算，不用 wbin_nxt —— 避免 wbin -> wbin_nxt -> full
    //   -> 写使能 这条路径被综合工具当成组合环（之前 audio_fifo 踩过）。
    assign wr_level = wbin - rbin_w;
    assign full     = (wr_level == DEPTH);

    // 写满被丢弃计数（正常工作时应当恒为 0）
    reg [7:0] wr_drop_r;
    always @(posedge wclk) begin
        if (!wrst_n)
            wr_drop_r <= 8'd0;
        else if (wr_en && full)
            wr_drop_r <= wr_drop_r + 1'b1;
    end
    assign wr_drop = wr_drop_r;

    //=========================================================================
    //                              读时钟域
    //=========================================================================

    // 写指针（格雷码）同步到读域
    always @(posedge rclk) begin
        if (!rrst_n) begin
            wgray_r1 <= {PW{1'b0}};
            wgray_r2 <= {PW{1'b0}};
        end else begin
            wgray_r1 <= wgray;
            wgray_r2 <= wgray_r1;
        end
    end

    // 读指针推进
    always @(posedge rclk) begin
        if (!rrst_n) begin
            rbin  <= {PW{1'b0}};
            rgray <= {PW{1'b0}};
        end else if (rd_en && !empty) begin
            rbin  <= rbin + 1'b1;
            rgray <= bin2gray(rbin + 1'b1);
        end
    end

    // 空：两个格雷码指针相等 —— 纯比较，不需要转二进制
    assign empty = (rgray == wgray_r2);

    assign rd_level = gray2bin(wgray_r2) - rbin;

    // show-ahead 输出：组合读，永远显示队首，rd_en 只负责"弹出"
    assign dout = mem[rbin[AW-1:0]];

endmodule
