//////////////////////////////////////////////////////////////////////////////////
// Company:        个人项目 / SonicTwin-Engine
// Engineer:       flyingyu
//
// Create Date:    2026-10-26
// Design Name:    sd_init
// Module Name:    sd_init
// Project Name:   音速双擎（SonicTwin-Engine）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    sd_init.v  ——  SD 卡 SPI 模式初始化
//                 【这个模块做什么】
//                 让一张 SD 卡从"上电状态"进入"SPI 模式且已完成初始化"，
// Dependencies:   无
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps


module sd_init #(
    parameter integer CLK_HZ        = 48_000_000,  // 输入时钟频率
    parameter integer DIV_FREQ      = 240,         // 分频系数：48M/240 = 200 kHz
    parameter integer POWER_ON_NUM  = 5000,        // 上电等待拍数（200kHz 下约 25 ms）
    parameter integer OVER_TIME_NUM = 25000        // 命令超时拍数（200kHz 下 125 ms）
) (
    input  wire clk,          // 系统时钟（clk_sys）
    input  wire rst_n,        // 同步复位，低有效

    // SD 卡 SPI 接口
    input  wire sd_miso,      // 卡 -> 主机
    output wire sd_clk,       // SPI 时钟（初始化阶段 200 kHz）
    output reg  sd_cs,        // 片选，低有效
    output reg  sd_mosi,      // 主机 -> 卡

    output reg  init_done     // 初始化完成，保持为 1
);

    //-------------------------------------------------------------------------
    // 命令常量
    //   第 1 字节 = 0x40 | 命令号
    //   第 2~5 字节 = 32 位参数（大端）
    //   第 6 字节 = CRC7 + 结束位
    //     · 只有 CMD0 / CMD8 的 CRC 是规范写死的（0x95 / 0x87）
    //       因为 SPI 模式下卡只在"还没切进 SPI 模式"时才校验 CRC
    //     · 其余命令的 CRC 填 0xFF 即可（卡不检查）
    //-------------------------------------------------------------------------
    localparam [47:0] CMD0   = {8'h40, 8'h00, 8'h00, 8'h00, 8'h00, 8'h95};
    localparam [47:0] CMD8   = {8'h48, 8'h00, 8'h00, 8'h01, 8'hAA, 8'h87};
    localparam [47:0] CMD55  = {8'h77, 8'h00, 8'h00, 8'h00, 8'h00, 8'hFF};
    localparam [47:0] ACMD41 = {8'h69, 8'h40, 8'h00, 8'h00, 8'h00, 8'hFF};

    //-------------------------------------------------------------------------
    // 状态编码（独热码，便于在波形上直接看出当前状态）
    //-------------------------------------------------------------------------
    localparam [6:0] ST_IDLE        = 7'b000_0001;  // 上电等待稳定
    localparam [6:0] ST_SEND_CMD0   = 7'b000_0010;  // 发 CMD0
    localparam [6:0] ST_WAIT_CMD0   = 7'b000_0100;  // 等 CMD0 响应（可超时）
    localparam [6:0] ST_SEND_CMD8   = 7'b000_1000;  // 发 CMD8 并等响应
    localparam [6:0] ST_SEND_CMD55  = 7'b001_0000;  // 发 CMD55 并等响应
    localparam [6:0] ST_SEND_ACMD41 = 7'b010_0000;  // 发 ACMD41 并等响应
    localparam [6:0] ST_INIT_DONE   = 7'b100_0000;  // 完成

    // 一次命令 = 48 位 = 6 字节
    localparam integer CMD_BITS = 48;

    //-------------------------------------------------------------------------
    // 状态与计数器
    //-------------------------------------------------------------------------
    reg [6:0]  cur_state;
    reg [6:0]  next_state;

    reg [15:0] div_cnt;          // 分频计数器
    reg        div_clk;          // 200 kHz 派生时钟

    reg [12:0] poweron_cnt;      // 上电等待计数器（在 div_clk 域）

    reg        res_en;           // 响应接收完成（单拍脉冲）
    reg [47:0] resp_data;        // 收到的 6 字节（MSB 先到）
    reg        res_flag;         // 正在接收响应
    reg [5:0]  res_bit_cnt;      // 响应位计数

    reg [5:0]  cmd_bit_cnt;      // 命令发送位计数
    reg [15:0] over_time_cnt;    // 超时计数器
    reg        over_time_en;     // 超时标志（单拍脉冲）



    //-------------------------------------------------------------------------
    // SPI 时钟：sd_clk = ~div_clk
    //   发送在 div_clk 上升沿更新 MOSI
    //   采样在 sd_clk 上升沿（= div_clk 下降沿）锁存 MISO
    //-------------------------------------------------------------------------
    assign sd_clk = ~div_clk;

    //-------------------------------------------------------------------------
    // 分频：clk -> div_clk
    //   每 DIV_FREQ/2 个 clk 周期翻转一次 ⟹ div_clk 频率 = CLK_HZ / DIV_FREQ
    //-------------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            div_clk <= 1'b0;
            div_cnt <= 16'd0;
        end else if (div_cnt == (DIV_FREQ / 2) - 1) begin
            div_clk <= ~div_clk;
            div_cnt <= 16'd0;
        end else begin
            div_cnt <= div_cnt + 16'd1;
        end
    end

    //-------------------------------------------------------------------------
    // 上电等待：在 IDLE 里数满 POWER_ON_NUM 个 div_clk 周期
    //   规范要求上电后至少 74 个时钟；这里给到约 25 ms，非常宽松
    //-------------------------------------------------------------------------
    always @(posedge div_clk or negedge rst_n) begin
        if (!rst_n)
            poweron_cnt <= 13'd0;
        else if (cur_state == ST_IDLE) begin
            if (poweron_cnt < POWER_ON_NUM)
                poweron_cnt <= poweron_cnt + 13'd1;
        end else begin
            poweron_cnt <= 13'd0;
        end
    end

    //-------------------------------------------------------------------------
    // 响应接收
    //   在 div_clk 的下降沿（= sd_clk 的上升沿）采样 sd_miso
    //   ⟹ 直接写 negedge div_clk —— 不要再"造一个反相时钟再当 posedge 用"：
    //      那样等于是把派生时钟又派生了一次，相位关系容易错，也没必要。
    //
    //   起始判决：响应一定以 0 开头（起始位），看到 0 就开始收
    //   固定收 48 位：R1 只有 1 字节，多出的部分由 NOP 填满，
    //                这样不必为 R1/R3/R7 各写一套逻辑
    //-------------------------------------------------------------------------
    always @(negedge div_clk or negedge rst_n) begin
        if (!rst_n) begin
            res_en      <= 1'b0;
            resp_data   <= 48'd0;
            res_flag    <= 1'b0;
            res_bit_cnt <= 6'd0;
        end else if ((sd_miso == 1'b0) && (res_flag == 1'b0)) begin
            res_flag    <= 1'b1;
            resp_data   <= {resp_data[46:0], sd_miso};
            res_bit_cnt <= 6'd1;
            res_en      <= 1'b0;
        end else if (res_flag) begin
            resp_data   <= {resp_data[46:0], sd_miso};
            res_bit_cnt <= res_bit_cnt + 6'd1;
            if (res_bit_cnt == (CMD_BITS - 1)) begin
                res_flag    <= 1'b0;
                res_bit_cnt <= 6'd0;
                res_en      <= 1'b1;
            end
        end else begin
            res_en <= 1'b0;
        end
    end

    //-------------------------------------------------------------------------
    // 状态寄存器
    //-------------------------------------------------------------------------
    always @(posedge div_clk or negedge rst_n) begin
        if (!rst_n)
            cur_state <= ST_IDLE;
        else
            cur_state <= next_state;
    end

    //-------------------------------------------------------------------------
    // 次态逻辑
    //-------------------------------------------------------------------------
    always @(*) begin
        next_state = ST_IDLE;
        case (cur_state)
            ST_IDLE: begin
                if (poweron_cnt == POWER_ON_NUM)
                    next_state = ST_SEND_CMD0;
                else
                    next_state = ST_IDLE;
            end

            ST_SEND_CMD0: begin
                if (cmd_bit_cnt == (CMD_BITS - 1))
                    next_state = ST_WAIT_CMD0;
                else
                    next_state = ST_SEND_CMD0;
            end

            ST_WAIT_CMD0: begin
                if (res_en) begin
                    // R1 的 bit0..我们只看最高字节：0x01 = IDLE 状态 ⟹ 复位成功
                    if (resp_data[47:40] == 8'h01)
                        next_state = ST_SEND_CMD8;
                    else
                        next_state = ST_IDLE;      // 不识别的响应，重来
                end else if (over_time_en) begin
                    next_state = ST_IDLE;          // 卡没插/无响应，重来
                end else begin
                    next_state = ST_WAIT_CMD0;
                end
            end

            ST_SEND_CMD8: begin
                if (res_en) begin
                    // R7 的 [19:16] = 卡接受的电压范围，4'b0001 = 2.7~3.6 V
                    if (resp_data[19:16] == 4'b0001)
                        next_state = ST_SEND_CMD55;
                    else
                        next_state = ST_IDLE;
                end else begin
                    next_state = ST_SEND_CMD8;
                end
            end

            ST_SEND_CMD55: begin
                if (res_en) begin
                    if (resp_data[47:40] == 8'h01) // 仍在 IDLE ⟹ 可以发 ACMD
                        next_state = ST_SEND_ACMD41;
                    else
                        next_state = ST_SEND_CMD55;  // 重发
                end else begin
                    next_state = ST_SEND_CMD55;
                end
            end

            ST_SEND_ACMD41: begin
                if (res_en) begin
                    if (resp_data[47:40] == 8'h00) // 0x00 ⟹ 初始化完成
                        next_state = ST_INIT_DONE;
                    else
                        next_state = ST_SEND_CMD55;  // 还在忙 ⟹ 再问一遍
                end else begin
                    next_state = ST_SEND_ACMD41;
                end
            end

            ST_INIT_DONE:
                next_state = ST_INIT_DONE;

            default:
                next_state = ST_IDLE;
        endcase
    end

    //-------------------------------------------------------------------------
    // 输出逻辑：发送 MOSI / 驱动 CS / 超时计数
    //   注意 MOSI 在 div_clk 上升沿更新，卡在 sd_clk 上升沿采样
    //   （sd_clk = ~div_clk，两者相差半个周期，采样点落在数据中点）
    //-------------------------------------------------------------------------
    always @(posedge div_clk or negedge rst_n) begin
        if (!rst_n) begin
            sd_cs         <= 1'b1;
            sd_mosi       <= 1'b1;
            init_done     <= 1'b0;
            cmd_bit_cnt   <= 6'd0;
            over_time_cnt <= 16'd0;
            over_time_en  <= 1'b0;
        end else begin
            over_time_en <= 1'b0;
            case (cur_state)
                ST_IDLE: begin
                    sd_cs   <= 1'b1;      // 上电等待期间 CS=1, MOSI=1（全 1 的空闲时钟）
                    sd_mosi <= 1'b1;
                end

                ST_SEND_CMD0: begin
                    cmd_bit_cnt <= cmd_bit_cnt + 6'd1;
                    sd_cs       <= 1'b0;
                    sd_mosi     <= CMD0[CMD_BITS - 1 - cmd_bit_cnt]; // MSB 先出
                    if (cmd_bit_cnt == (CMD_BITS - 1))
                        cmd_bit_cnt <= 6'd0;
                end

                ST_WAIT_CMD0: begin
                    // 等响应期间 CS 保持低、MOSI 保持高（发 NOP 时钟）
                    sd_mosi <= 1'b1;
                    if (res_en)
                        sd_cs <= 1'b1;     // 收到响应后再放开 CS ⟹ 已进入 SPI 模式

                    over_time_cnt <= over_time_cnt + 16'd1;
                    if (over_time_cnt == (OVER_TIME_NUM - 1))
                        over_time_en <= 1'b1;
                    if (over_time_en)
                        over_time_cnt <= 16'd0;
                end

                ST_SEND_CMD8: begin
                    if (cmd_bit_cnt <= (CMD_BITS - 1)) begin
                        cmd_bit_cnt <= cmd_bit_cnt + 6'd1;
                        sd_cs       <= 1'b0;
                        sd_mosi     <= CMD8[CMD_BITS - 1 - cmd_bit_cnt];
                    end else begin
                        sd_mosi <= 1'b1;
                        if (res_en) begin
                            sd_cs       <= 1'b1;
                            cmd_bit_cnt <= 6'd0;
                        end
                    end
                end

                ST_SEND_CMD55: begin
                    if (cmd_bit_cnt <= (CMD_BITS - 1)) begin
                        cmd_bit_cnt <= cmd_bit_cnt + 6'd1;
                        sd_cs       <= 1'b0;
                        sd_mosi     <= CMD55[CMD_BITS - 1 - cmd_bit_cnt];
                    end else begin
                        sd_mosi <= 1'b1;
                        if (res_en) begin
                            sd_cs       <= 1'b1;
                            cmd_bit_cnt <= 6'd0;
                        end
                    end
                end

                ST_SEND_ACMD41: begin
                    if (cmd_bit_cnt <= (CMD_BITS - 1)) begin
                        cmd_bit_cnt <= cmd_bit_cnt + 6'd1;
                        sd_cs       <= 1'b0;
                        sd_mosi     <= ACMD41[CMD_BITS - 1 - cmd_bit_cnt];
                    end else begin
                        sd_mosi <= 1'b1;
                        if (res_en) begin
                            sd_cs       <= 1'b1;
                            cmd_bit_cnt <= 6'd0;
                        end
                    end
                end

                ST_INIT_DONE: begin
                    init_done <= 1'b1;
                    sd_cs     <= 1'b1;
                    sd_mosi   <= 1'b1;
                end

                default: begin
                    sd_cs   <= 1'b1;
                    sd_mosi <= 1'b1;
                end
            endcase
        end
    end

endmodule
