//=============================================================================
// wave_buf.v - 波形缓冲（双时钟 BRAM，固定窗口显示）
//-----------------------------------------------------------------------------
// 用途：把 clk_sys 域（音频 48 kHz）的采样送到 clk_pix 域，供示波器式波形显示。
//
// 【窗口怎么定】
//   写指针 wptr 按 48 kHz 一直往前走；显示侧在【帧起始】锁存
//       base = wptr - SPAN
//   然后第 x 列读 mem[base + x]。也就是"永远显示最近 SPAN 个采样"。
//
//   屏幕 480 列 → SPAN = 480 个采样 = 10 ms @48kHz ✓
//   每帧时间 12.01 ms，写指针前进约 577 个采样 —— 所以波形每帧会
//   "滑过"比屏幕更宽的一段，看起来是连续向左滚动的。
//
// 【为什么深度要 1024 而不是 512】
//   窗口是 [base, base+480)，而写指针在一帧内会前进到 base+577。
//   如果深度只有 512，写指针绕回来就会踩进正在显示的窗口里，出现撕裂。
//   深度 1024 时，要写坏 base 处得等 wptr 走满 1024 个点（21 ms > 帧周期），
//   安全。
//
// 【跨时钟域怎么处理】
//   写指针是多比特计数器，直接同步会出现"采到中间态"的经典问题。
//   所以在线路上跑的是【格雷码】：相邻值只差 1 位，两级同步器
//   要么采到旧值、要么采到新值，不会采到非法值。
//   （和 rtl/common/async_fifo.v 里用的是同一个技巧。）
//
// 【为什么读用 BRAM 同步输出而不是分布式 RAM 组合输出】
//   BRAM 有独立时钟的两个端口，正好一个写 clk_sys 一个读 clk_pix。
//   代价是读出有一拍延迟 —— 表现为波形整体右移 1 个像素。肉眼无感，
//   因为同一行内 y 不变，采样值和行号比较不受影响。
//   换来的是省掉 1024x24 的分布式 RAM（约 384 个 LUT）。
//
// 【为什么复位【不】碰 RAM 的控制脚】（踩过 DRC REQP-1839）
//   把 wrst_n / rrst_n 写进写使能或读复位里，会让它们被接到 BRAM 的
//   WEA / RSTRAMB 控制脚上。而这两个复位来自 rst_sync（带异步复位），
//   于是一片 BRAM 报 5 条 REQP-1839。
//   正确做法：**只复位指针，不复位 RAM 内容**。
//   本项目在 rtl/fft/fft_core.v、rtl/common/audio_fifo.v 里也是同样的处理。
//=============================================================================
`timescale 1ns/1ps

module wave_buf #(
    parameter integer DW   = 24,        // 采样位宽
    parameter integer AW   = 10,        // 地址位宽（深度 = 2^AW）
    parameter integer SPAN = 480,       // 每帧显示的采样点数
    // 列坐标位宽（P1-3a）。默认 10 对应 480 宽。
    // ⚠️ AW 必须 >= $clog2(SPAN)，否则 x 的高位会被截掉。
    parameter integer XW   = 10
) (
    //----------------------- 写侧：clk_sys -----------------------
    input  wire                  wclk,
    input  wire                  wrst_n,
    input  wire                  we,
    input  wire signed [DW-1:0]  din,

    //----------------------- 读侧：clk_pix -----------------------
    input  wire                  rclk,
    input  wire                  rrst_n,
    input  wire                  sof,     // 帧起始，锁存新的显示窗口
    input  wire [XW-1:0]         x,       // 当前列（0..SPAN-1）
    output reg  signed [DW-1:0]  dout
);

    localparam integer DEPTH = 1 << AW;

    (* ram_style = "block" *) reg signed [DW-1:0] mem [0:DEPTH-1];

    reg [AW-1:0] wbin;
    reg [AW-1:0] wgray;
    reg  [AW-1:0] rbase;
    wire [AW-1:0] raddr;      // 组合算出，给 BRAM 地址

    //=========================================================================
    // 1. 写端口（clk_sys）
    //=========================================================================
    // 【为什么这里【不】把 wrst_n 写进写使能】
    //   如果写成 `if (!wrst_n) ... else if (we) mem[wbin] <= din;`，
    //   综合器会把 wrst_n 一起做进 BRAM 的 WEA 控制逻辑（WEA = ~wrst_n & we）。
    //   而 wrst_n 来自 rst_sync（异步复位、同步释放），于是 WEA 由带异步复位的
    //   触发器驱动 —— 触发 [DRC REQP-1839]，且复位期间的写不受时序分析保护。
    //
    //   关键认识：**RAM 的内容本来就不需要复位**。
    //   这是个滚动窗口，读到旧数据也无所谓，立刻会被新采样覆盖。
    //   所以只复位【指针】，不复位 RAM。
    wire [AW-1:0] wbin_nxt = wbin + 1'b1;

    always @(posedge wclk) begin
        if (we) begin
            mem[wbin] <= din;                           // 只受 we 控制 → WEA = we
            wbin      <= wbin_nxt;
            wgray     <= wbin_nxt ^ (wbin_nxt >> 1);     // 二进制 -> 格雷码
        end
        if (!wrst_n) begin                              // 后写的优先：复位压过上面
            wbin  <= {AW{1'b0}};
            wgray <= {AW{1'b0}};
        end
    end

    //=========================================================================
    // 2. 写指针同步到读域（格雷码 + 两级同步器）
    //=========================================================================
    (* ASYNC_REG = "TRUE" *) reg [AW-1:0] wgray_s1, wgray_s2;

    always @(posedge rclk) begin
        if (!rrst_n) begin
            wgray_s1 <= {AW{1'b0}};
            wgray_s2 <= {AW{1'b0}};
        end else begin
            wgray_s1 <= wgray;
            wgray_s2 <= wgray_s1;
        end
    end

    // 格雷码 -> 二进制（组合，AW 级异或链）
    function [AW-1:0] gray2bin;
        input [AW-1:0] g;
        integer i;
        begin
            gray2bin[AW-1] = g[AW-1];
            for (i = AW - 2; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i+1] ^ g[i];
        end
    endfunction

    wire [AW-1:0] wbin_s = gray2bin(wgray_s2);

    //=========================================================================
    // 3. 读侧：帧起始锁存窗口基准，然后按列地址读
    //=========================================================================
    always @(posedge rclk) begin
        if (!rrst_n)
            rbase <= {AW{1'b0}};
        else if (sof)
            rbase <= wbin_s - SPAN[AW-1:0];     // 回退 SPAN 个采样 = 一屏
    end

    assign raddr = rbase + x[AW-1:0];

    // 【为什么读端口不复位】
    //   写成 `if (!rrst_n) dout <= 0; else dout <= mem[raddr];` 的话，
    //   综合器会把 rrst_n 接到 BRAM 的 RSTRAMB 脚上 → 同样触发 REQP-1839。
    //   读出的旧值是多少也无所谓 —— 波形窗口立刻会被新数据填满。
    always @(posedge rclk)
        dout <= mem[raddr];                             // BRAM 同步读，一拍延迟

endmodule
