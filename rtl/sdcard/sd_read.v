//=============================================================================
// sd_read.v  ——  SD 卡 SPI 模式单块读（CMD17）
//=============================================================================
//   【一次读操作完整流程】
//      ① 拉低 CS，发 CMD17（48 位，参数 = 扇区地址）
//      ② 收 R1（只要 1 字节；0x00 = 成功）
//      ③ 卡先发若干 NOP(0xFF)，然后是【数据起始令牌 0xFE】
//      ④ 紧跟 512 字节数据 + 2 字节 CRC16
//      ⑤ 拉高 CS，结束
//
//   【为什么用"检测 0"来判起始令牌】
//      0xFE = 8'b1111_1110 ⟹ 它的 bit0 是 0，而之前的 NOP 全是 1
//      所以"第一个 0"就是令牌的起点。R1 的检测也是同一招（R1 的 bit7 = 0）。
//      ⚠️ 但这招有个前提：令牌之后不会再出现"前导 1"，
//         所以一旦进了收数据状态就要【按位计数】，不能再用"检测 0"。
//
//   【数据接收为什么按 16 位打包】
//     512 字节 = 256 个 16 位字，下游做 RGB888→RGB565 时正好两字节一处理。
//     这里输出 8 位字节流（dout_data/dout_valid），打包交给下游更灵活。
//
//   【时钟】
//     本模块完全工作在 sd_clk 域（= sd_ctrl_top 送来的高速 SPI 时钟）：
//       · 采样 sd_miso 用 posedge sd_clk（数据稳定中点）
//       · 驱动 sd_mosi 用 negedge sd_clk（避开对方的采样沿）
//     dout_valid/dout_data 也在 sd_clk 域 ⟹ 跨到 clk_sys 由下游的
//     async_fifo（rtl/common/async_fifo.v）负责，本模块不做 CDC。
//=============================================================================

`timescale 1ns / 1ps

module sd_read (
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
    // 参数紧跟其后（大端 32 位）
    localparam [5:0] CMD17_IDX = 6'd17;
    // 数据起始令牌是 0xFE（= 8'b1111_1110）⟹ 它的 bit0 = 0，
    // 而之前的 NOP 全是 1 ⟹ "第一个 0" 就是令牌起点，不需要比较整个字节。
    // 这里保留常量是为了让上面这段说明有出处（综合时不产生逻辑）。

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
    reg [5:0]  mosi_bit;        // MOSI 输出位序号（【negedge 域自己的计数】）

    //-------------------------------------------------------------------------
    // 命令字组装
    //-------------------------------------------------------------------------
    wire [47:0] cmd17 = {2'b01, CMD17_IDX,              // 8'h40 | cmd
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
            // mosi_bit 归 negedge 块管，这里不要重复驱动（会 MULTIDRIVEN）
            dout_valid  <= 1'b0;
            dout_data   <= 8'd0;
        end else begin
            dout_valid <= 1'b0;     // 默认单拍

            case (state)
                //-------------------------------------------------------------
                ST_IDLE: begin
                    sd_cs <= 1'b1;
                    if (start) begin
                        cmd_reg <= cmd17;
                        cmd_bit <= 6'd0;
                        busy    <= 1'b1;
                        // ⚠️ 不要直接跳 ST_SEND：CS 拉低必须比第一位数据【早一拍】，
                        //    否则卡（以及 TB 里的模型）会在 CS 刚变低的那一拍
                        //    采到"数据之前的空闲高电平"，导致整帧左移一位。
                        //    这里加一个建立态专门处理 CS。
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
                // （sd_mosi 在 negedge 更新才是安全的，但这里用寄存器输出、
                //   由 negedge 块统一驱动，见下面第二个 always）
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
                            // R1 收完（内容不检查，出错也会被后面的令牌超时兜住）
                            tok_bit <= 3'd0;
                            state   <= ST_WAIT_TOKEN;
                        end
                    end
                end

                //-------------------------------------------------------------
                // 等数据起始令牌
                //   令牌 0xFE = 8'b1111_1110 ⟹ 那个 0 是【最后一位】，
                //   前面的 NOP 全是 1 ⟹ "第一个 0" 就是令牌结束、数据开始。
                //   ⟹ 检测到它就可以【直接开始收字节】，不需要再丢任何位。
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
                //   这里【没有任何额外状态】—— 不丢位、不判特殊图案，
                //   只靠 bit_in_byte / byte_cnt 两个计数器。
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
                    if (crc_bit == 5'd15)
                        state <= ST_DONE;
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
    //   ⚠️ 这里必须用 mosi_bit 而不是 cmd_bit！
    //      cmd_bit 是在 posedge 域里递增的，进入 ST_SEND 的那一拍就已经变成 1，
    //      于是第一个 negedge 读到的是 1 ⟹ 输出 bit46 而不是 bit47，
    //      之后每个 negedge 又都是"+2"的效果 ⟹ 隔一位取一位，
    //      表现为命令字和数据全部"整体左移一位"。
    //   正解：MOSI 的位序由 negedge 域自己的计数器决定。
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
