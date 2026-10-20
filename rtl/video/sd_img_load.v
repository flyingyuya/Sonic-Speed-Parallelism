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
    parameter integer H = 272
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
    output reg  [18:0] pix_cnt
);

    localparam integer DEPTH = W * H;

    reg        hi_lo;          // 0 = 等低字节，1 = 等高字节
    reg [7:0]  lo_byte;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_en    <= 1'b0;
            wr_addr  <= 19'd0;
            wr_data  <= 16'd0;
            hi_lo    <= 1'b0;
            lo_byte  <= 8'd0;
            done     <= 1'b0;
            pix_cnt  <= 19'd0;
        end else begin
            wr_en <= 1'b0;          // 默认单拍

            if (start) begin
                hi_lo   <= 1'b0;
                lo_byte <= 8'd0;
                done    <= 1'b0;
                pix_cnt <= 19'd0;
                wr_addr <= 19'd0;
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
