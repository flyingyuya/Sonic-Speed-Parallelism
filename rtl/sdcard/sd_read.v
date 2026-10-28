//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    sd_read
// Module Name:    sd_read
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    sd_read.v  ——  SD 卡 SPI 模式单块读（CMD17）
// Dependencies:
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps


module sd_read #(
    // 一次读多少块（512 字节/块）
    //   480x272x2 = 261120 字节 = 正好 510 块
    //   用 CMD18（多块读）：卡自己递增地址，主机只要一直收
    parameter integer BLOCKS = 510
) (
    input  wire        sd_clk,        // SPI 时钟（高速档）
    input  wire        rst_n,         // 复位（低有效，sd_clk 域）

    // 用户接口：start 为单拍脉冲（需要先同步到 sd_clk 域）
    input  wire        start,
    input  wire [31:0] sec_addr,      // 扇区地址（512 字节为单位）
    output reg         busy,

    output reg         dout_valid,    // 单拍脉冲，表示 dout_data 有效
    output reg  [7:0]  dout_data,

    // SD 卡 SPI
    input  wire        sd_miso,
    output reg         sd_cs,
    output reg         sd_mosi
);

    //-------------------------------------------------------------------------
    // 常量
    //-------------------------------------------------------------------------
    localparam integer CMD_BITS   = 48;
    localparam integer BLOCK_BYTES = 512;
    // CMD17 = 0x40 | 17 = 0x51；CRC 在 SPI 模式下不检查，填 0xFF
    localparam [5:0] CMD18_IDX = 6'd18;   // CMD18 = 多块读（CMD17 是单块）

    //-------------------------------------------------------------------------
    // 状态
    //-------------------------------------------------------------------------
    localparam [2:0] ST_IDLE       = 3'd0;   // 等 start
    localparam [2:0] ST_SETUP      = 3'd7;   // CS 拉低 + 第一位 MOSI 就位（建立时间）
    localparam [2:0] ST_SEND       = 3'd1;   // 发 48 位命令
    localparam [2:0] ST_R1         = 3'd2;   // 收 R1
    localparam [2:0] ST_WAIT_TOKEN = 3'd3;   // 等 0xFE
    localparam [2:0] ST_DATA       = 3'd4;   // 收 512 字节
    localparam [2:0] ST_CRC        = 3'd5;   // 收 2 字节 CRC（丢弃）
    localparam [2:0] ST_DONE       = 3'd6;   // 拉高 CS

    reg [2:0]  state;

    // 命令发送
    reg [47:0] cmd_reg;
    reg [5:0]  cmd_bit;

    // 响应 / 令牌
    reg [2:0]  r1_bit;          // 已收 R1 的位数
    reg [2:0]  tok_bit;         // 令牌对齐用的位计数

    // 数据接收
    reg [8:0]  byte_cnt;        // 0..511
    reg [2:0]  bit_in_byte;     // 0..7
    reg [7:0]  byte_shift;
    reg [4:0]  crc_bit;         // CRC16 的 16 位计数
    reg [9:0]  blk_cnt;         // 已收完的块数（0..BLOCKS-1）
    reg [5:0]  mosi_bit;        // MOSI 输出位序号（negedge 域自己的计数）

    //-------------------------------------------------------------------------
    // 命令字组装
    //-------------------------------------------------------------------------
    wire [47:0] cmd18 = {2'b01, CMD18_IDX,              // 8'h40 | cmd
                         sec_addr[31:24], sec_addr[23:16],
                         sec_addr[15:8],  sec_addr[7:0],
                         8'hFF};                        // CRC 不检查

    //-------------------------------------------------------------------------
    // 主状态机：全部在 posedge sd_clk 上
    //-------------------------------------------------------------------------
    always @(posedge sd_clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= ST_IDLE;
            busy        <= 1'b0;
            sd_cs       <= 1'b1;
            cmd_reg     <= 48'd0;
            cmd_bit     <= 6'd0;
            r1_bit      <= 3'd0;
            tok_bit     <= 3'd0;
            byte_cnt    <= 9'd0;
            bit_in_byte <= 3'd0;
            byte_shift  <= 8'd0;
            crc_bit     <= 5'd0;
            blk_cnt     <= 10'd0;
            dout_valid  <= 1'b0;
            dout_data   <= 8'd0;
        end else begin
            dout_valid <= 1'b0;     // 默认单拍

            case (state)
                //-------------------------------------------------------------
                ST_IDLE: begin
                    sd_cs <= 1'b1;
                    if (start) begin
                        cmd_reg <= cmd18;
                        cmd_bit <= 6'd0;
                        busy    <= 1'b1;
                        blk_cnt <= 10'd0;
                        state   <= ST_SETUP;
                    end
                end

                //-------------------------------------------------------------
                // CS 建立态：只拉低 CS，数据位由 negedge 域在下一拍推出
                //-------------------------------------------------------------
                ST_SETUP: begin
                    sd_cs <= 1'b0;
                    state <= ST_SEND;
                end

                //-------------------------------------------------------------
                // 发 48 位：MSB 先出，每次 posedge 更新一位
                //-------------------------------------------------------------
                ST_SEND: begin
                    sd_cs   <= 1'b0;
                    cmd_bit <= cmd_bit + 6'd1;
                    if (cmd_bit == (CMD_BITS - 1)) begin
                        r1_bit <= 3'd0;
                        state  <= ST_R1;
                    end
                end

                //-------------------------------------------------------------
                // 收 R1：跳过前的 NOP(全 1)，第一个 0 就是 R1 的 bit7
                //-------------------------------------------------------------
                ST_R1: begin
                    if (r1_bit == 3'd0) begin
                        if (sd_miso == 1'b0) begin
                            r1_bit <= 3'd1;   // 找到起始位
                        end
                    end else begin
                        r1_bit <= r1_bit + 3'd1;
                        if (r1_bit == 3'd7) begin
                            // R1 收完
                            tok_bit <= 3'd0;
                            state   <= ST_WAIT_TOKEN;
                        end
                    end
                end

                //-------------------------------------------------------------
                // 等数据起始令牌
                //-------------------------------------------------------------
                ST_WAIT_TOKEN: begin
                    if (sd_miso == 1'b0) begin
                        byte_cnt    <= 9'd0;
                        bit_in_byte <= 3'd0;
                        byte_shift  <= 8'd0;
                        state       <= ST_DATA;
                    end
                end

                //-------------------------------------------------------------
                // 收 512 字节：纯粹的比特流打包，每 8 位出一个字节
                //-------------------------------------------------------------
                ST_DATA: begin
                    byte_shift <= {byte_shift[6:0], sd_miso};
                    if (bit_in_byte == 3'd7) begin
                        bit_in_byte <= 3'd0;
                        dout_valid  <= 1'b1;
                        dout_data   <= {byte_shift[6:0], sd_miso};

                        if (byte_cnt == (BLOCK_BYTES - 1)) begin
                            crc_bit <= 5'd0;
                            state   <= ST_CRC;
                        end else begin
                            byte_cnt <= byte_cnt + 9'd1;
                        end
                    end else begin
                        bit_in_byte <= bit_in_byte + 3'd1;
                    end
                end

                //-------------------------------------------------------------
                // CRC16 两字节：只数 16 个时钟，内容丢弃
                //-------------------------------------------------------------
                ST_CRC: begin
                    crc_bit <= crc_bit + 5'd1;
                    if (crc_bit == 5'd15) begin
                        // 一块收完
                        if (blk_cnt == (BLOCKS - 1)) begin
                            state <= ST_DONE;          // 收满预定块数，结束
                        end else begin
                            blk_cnt <= blk_cnt + 10'd1;
                            state   <= ST_WAIT_TOKEN;
                        end
                    end
                end

                //-------------------------------------------------------------
                ST_DONE: begin
                    sd_cs <= 1'b1;
                    busy  <= 1'b0;
                    state <= ST_IDLE;
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // MOSI 输出：在 negedge sd_clk 更新（避开卡在 posedge 的采样）
    //-------------------------------------------------------------------------
    always @(negedge sd_clk or negedge rst_n) begin
        if (!rst_n) begin
            sd_mosi  <= 1'b1;
            mosi_bit <= 6'd0;
        end else if (state == ST_SEND) begin
            if (mosi_bit < CMD_BITS) begin
                sd_mosi  <= cmd_reg[CMD_BITS - 1 - mosi_bit];
                mosi_bit <= mosi_bit + 6'd1;
            end else begin
                sd_mosi <= 1'b1;
            end
        end else begin
            sd_mosi  <= 1'b1;     // 非发送期间保持高（发 NOP 时钟）
            mosi_bit <= 6'd0;
        end
    end

endmodule
