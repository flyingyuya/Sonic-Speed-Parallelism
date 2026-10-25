//=============================================================================
// sd_img_load.v  ——  把 SD 卡的字节流搬成像素，写进帧缓冲
//=============================================================================
//   【数据格式约定】
//     PC 端脚本（scripts/sdcard/mkimage.py）按【RGB565 小端】写盘：
//       第 0 字节 = 像素 0 的低 8 位
//       第 1 字节 = 像素 0 的高 8 位
//       第 2 字节 = 像素 1 的低 8 位
//       ...
//     所以这里"两字节凑一个像素"，先来的放低位。
//
//   【为什么地址就是计数器】
//     图片是逐行紧凑存的：像素线性地址 = y*W + x。
//     SD 读到第 n 个像素，就写帧缓冲的第 n 个地址 ⟹ 地址 = 计数器，
//     不需要行/列展开（那是显示端的事）。
//
//   【和 sd_read 的握手】
//     byte_valid 是 sd_read 的 dout_valid（每个字节一个脉冲）。
//     本模块只在 byte_valid 时推进，所以 SD 读多慢都不会丢数据
//     —— 前提是 sd_read 的字节输出速率不超过 clk 的处理能力，
//     而 sd_read 跑在 clk/4，本模块跑在 clk ⟹ 天然满足。
//=============================================================================

`timescale 1ns / 1ps

module sd_img_load #(
    parameter integer W = 480,
    parameter integer H = 272,
    //-------------------------------------------------------------------------
    // 第二个写口：只写"中心裁剪区"（给 HDMI 用）
    //   LCD  缓冲 480x272（完整图）⟹ 每像素都写
    //   HDMI 缓冲 320x180（中心裁剪）⟹ 只有落在 [CX,CX+CW) x [CY,CY+CH) 才写
    //   为什么：两个显示器时钟不同 ⟹ 同一份缓冲要"1 写 2 读"⟹ Vivado 推断失败
    //           退化成 LUTRAM ⟹ LUT 爆掉。两份不同尺寸的缓冲更省（26 vs 58 块）。
    parameter integer EN_CROP = 1,
    parameter integer CX = 80,
    parameter integer CY = 46,
    parameter integer CW = 320,
    parameter integer CH = 180
) (
    input  wire        clk,
    input  wire        rst_n,

    // 开始新一帧加载（清计数器）。单拍脉冲。
    input  wire        start,

    // 来自 sd_read 的字节流
    input  wire        byte_valid,
    input  wire [7:0]  byte_data,

    // 帧缓冲写口
    output reg         wr_en,
    output reg  [18:0] wr_addr,
    output reg  [15:0] wr_data,

    // 一帧写满
    output reg         done,
    // 已写入的像素数（调试用）
    // 第二个写口（裁剪区，给 HDMI 缓冲）
    output reg         wr2_en,
    output reg  [18:0] wr2_addr,

    output reg  [18:0] pix_cnt
);

    localparam integer DEPTH = W * H;

    // 用行列计数器代替除法/取模（整除会吃掉 DSP 和时序）
    reg [15:0] x_cnt;      // 列 0..W-1
    reg [15:0] y_cnt;      // 行 0..H-1

    // 裁剪判定：当前像素是否在中心区内
    wire crop_x_ok = (x_cnt >= CX) && (x_cnt < (CX + CW));
    wire crop_y_ok = (y_cnt >= CY) && (y_cnt < (CY + CH));
    wire crop_ok   = EN_CROP && crop_x_ok && crop_y_ok;

    // 裁剪区内的相对坐标 + 线性地址（乘 320 = 256+64 ⟹ 两次移位相加，零 DSP）
    wire [15:0] crop_dx = x_cnt - CX[15:0];
    wire [15:0] crop_dy = y_cnt - CY[15:0];
    wire [18:0] crop_addr = ({3'd0, crop_dy} << 8) + ({3'd0, crop_dy} << 6) + {3'd0, crop_dx};

    reg        hi_lo;          // 0 = 等低字节，1 = 等高字节
    reg [7:0]  lo_byte;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            // ⚠️ wr_addr / wr_data 故意【不加异步复位】：
            //    它们直接驱动 BRAM 的地址/数据引脚，而 Vivado 的
            //    DRC REQP-1839 明确警告"带异步复位的寄存器驱动 RAMB 控制脚
            //    可能破坏存储内容"。这两个寄存器本来就由 start 清零、
            //    由数据流赋值，不需要复位。
            // wr_en 同理：它驱动 RAMB 的 ENARDEN，也不能带异步复位
            hi_lo    <= 1'b0;
            lo_byte  <= 8'd0;
            done     <= 1'b0;
            pix_cnt  <= 19'd0;
            x_cnt    <= 16'd0;
            y_cnt    <= 16'd0;
            // ⚠️ wr2_en / wr2_addr 同样【不能带异步复位】：
            //    它们驱动 BRAM 的 ENARDEN / ADDRARDADDR ⟹ DRC REQP-1839
            //    （漏了这条 ⟹ 合成报 40 条 REQP-1839 警告）
        end else begin
            wr_en  <= 1'b0;         // 默认单拍
            wr2_en <= 1'b0;         // 同理：使能必须每拍给值，不能"保持"

            if (start) begin
                hi_lo   <= 1'b0;
                lo_byte <= 8'd0;
                done    <= 1'b0;
                pix_cnt <= 19'd0;
                wr_addr  <= 19'd0;
                x_cnt    <= 16'd0;
                y_cnt    <= 16'd0;
                wr2_en   <= 1'b0;
                wr2_addr <= 19'd0;
            end else if (byte_valid && !done) begin
                // ⚠️ 必须加 !done：写满之后 pix_cnt 停住了，但 byte_valid 还会来
                //    （SD 卡一次读的是整块 512 扇区 = 262144 字节，比一帧的
                //     261120 字节多 1024 字节），如果不挡，就会反复写最后一个
                //     地址，把画面右下角那一片像素踩坏。
                //    TB 的判据④ 就是专门抓这个的（我第一次漏了）。
                if (!hi_lo) begin
                    // 收到低字节
                    lo_byte <= byte_data;
                    hi_lo   <= 1'b1;
                end else begin
                    // 收到高字节 ⟹ 凑成一个像素，写帧缓冲
                    hi_lo <= 1'b0;
                    // 小端：先来的字节是低位
                    wr_data <= {byte_data, lo_byte};
                    wr_addr <= pix_cnt;
                    wr_en   <= 1'b1;

                    // 第二个写口：只在裁剪区内写
                    wr2_en   <= crop_ok;
                    wr2_addr <= crop_addr;

                    // 行列推进（x 到 W-1 归零，y 加一）
                    if (x_cnt == (W - 1)) begin
                        x_cnt <= 16'd0;
                        y_cnt <= y_cnt + 16'd1;
                    end else begin
                        x_cnt <= x_cnt + 16'd1;
                    end

                    if (pix_cnt == (DEPTH - 1)) begin
                        done <= 1'b1;      // 这一帧写满了
                        // 计数器停住，不再越界写
                    end else begin
                        pix_cnt <= pix_cnt + 19'd1;
                    end
                end
            end
        end
    end

endmodule
