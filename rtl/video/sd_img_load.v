//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    sd_img_load
// Module Name:    sd_img_load
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    sd_img_load.v  ——  把 SD 卡的字节流搬成像素，写进帧缓冲
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps


module sd_img_load #(
    parameter integer W = 480,
    parameter integer H = 272,
    //-------------------------------------------------------------------------
    // 第二个写口：只写"中心裁剪区"（给 HDMI 用）
    parameter integer EN_CROP = 1,
    parameter integer CX = 80,
    parameter integer CY = 46,
    parameter integer CW = 320,
    parameter integer CH = 180
) (
    input  wire        clk,
    input  wire        rst_n,

    // 开始新一帧加载（清计数器），单拍脉冲
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

    // 用行列计数器代替除法/取模
    reg [15:0] x_cnt;      // 列 0..W-1
    reg [15:0] y_cnt;      // 行 0..H-1

    // 裁剪判定：当前像素是否在中心区内
    wire crop_x_ok = (x_cnt >= CX) && (x_cnt < (CX + CW));
    wire crop_y_ok = (y_cnt >= CY) && (y_cnt < (CY + CH));
    wire crop_ok   = EN_CROP && crop_x_ok && crop_y_ok;

    // 裁剪区内的相对坐标 + 线性地址
    wire [15:0] crop_dx = x_cnt - CX[15:0];
    wire [15:0] crop_dy = y_cnt - CY[15:0];
    wire [18:0] crop_addr = ({3'd0, crop_dy} << 8) + ({3'd0, crop_dy} << 6) + {3'd0, crop_dx};

    reg        hi_lo;          // 0 = 等低字节，1 = 等高字节
    reg [7:0]  lo_byte;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hi_lo    <= 1'b0;
            lo_byte  <= 8'd0;
            done     <= 1'b0;
            pix_cnt  <= 19'd0;
            x_cnt    <= 16'd0;
            y_cnt    <= 16'd0;
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
                if (!hi_lo) begin
                    // 收到低字节
                    lo_byte <= byte_data;
                    hi_lo   <= 1'b1;
                end else begin
                    // 收到高字节，凑成一个像素，写帧缓冲
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
