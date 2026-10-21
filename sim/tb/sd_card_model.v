//=============================================================================
// sd_card_model.v  ——  SD 卡 SPI 模式行为模型（仿真专用）
//=============================================================================
//   【设计原则：数拍数，不推理沿】
//     前三版都在"哪个时钟沿读哪个信号"上反复出错（错一次就整帧位移，
//     而且从现象上极难看出偏移了几位）。这一版彻底改成【显式计数】：
//
//       定义 edge_n = "从 CS 下降沿算起，已经过了多少个 posedge sd_clk"
//         · edge_n 0 ..              ：命令的 48 位
//         · edge_n 48                ：命令收完，解析
//         · edge_n 49 .. 56          ：NOP 字节（8 个 1）
//         · edge_n 57 .. 104         ：48 位响应
//
//     MOSI 在 posedge sd_clk 采样（那是数据稳定区的中点：
//     DUT 在 posedge div_clk 更新 MOSI，而 posedge sd_clk == negedge div_clk）。
//     MISO 在 negedge sd_clk 更新（避开对方采样的那个沿）。
//     每条命令收完会把 rx 打印出来 —— 出问题时能直接看到比特流，
//     不用靠 cmd_index 反推。
//=============================================================================

`timescale 1ns / 1ps

module sd_card_model #(
    parameter integer ACMD41_POLLS = 3,    // 第几次 ACMD41 才回"就绪"
    // CMD18 多块读时，连续发多少个数据块（每块 512 字节）
    parameter integer BLOCKS       = 510
) (
    input  wire sd_clk,
    input  wire sd_cs,
    input  wire sd_mosi,
    output reg  sd_miso,

    output reg  [5:0]  cmd_index,     // 最近一条命令号（低 6 位）
    output reg  [31:0] cmd_arg,       // 最近一条命令参数
    output reg         cmd_valid,     // 命令解析完成（单拍脉冲）
    output reg  [7:0]  acmd41_cnt     // ACMD41 收到多少次
);

    //-------------------------------------------------------------------------
    // 计数器与寄存器
    //-------------------------------------------------------------------------
    reg [15:0] edge_n;         // 本帧已过的 sd_clk 上升沿数
    reg [47:0] rx;             // 接收移位寄存器
    reg [47:0] tx;             // 待发送的 48 位响应
    reg        rsp_en;         // 本帧是否要发响应
    reg        is_cmd17;       // CMD17（单块）或 CMD18（多块）⟹ 后面跟数据块
    reg        is_cmd18;       // CMD18 ⟹ 连续 BLOCKS 块
    reg [12:0] data_bit;       // 数据块内的位序号（0..4095）

    reg [5:0]  cur_cmd;
    reg [31:0] cur_arg;

    // rx 是寄存器，在 edge_n==CMD_BITS-1 那一拍还没更新（非阻塞赋值），
    // 所以要把"当前这一位"拼进去才算完整的 48 位。
    // ⚠️ 这是我踩过的坑：直接读 rx[45:40] 会拿到【移位前】的旧值，
    //    于是 CMD8 被解析成 0x24 ⟹ 走到 default 分支回 R1=0x01
    //    ⟹ DUT 检查 resp_data[19:16] 不对 ⟹ 永远停在 ST_SEND_CMD8。
    wire [47:0] rx_next = {rx[46:0], sd_mosi};

    // 时序常量
    localparam integer CMD_BITS   = 48;
    localparam integer NOP_BYTES  = 1;
    localparam integer NOP_BITS   = NOP_BYTES * 8;              // 8
    localparam integer RSP_START  = CMD_BITS + NOP_BITS;        // 56
    localparam integer RSP_END    = RSP_START + CMD_BITS;       // 104
    // CMD17 的数据块紧随 R1 之后：NOP(8) + 令牌(8) + 512*8 + CRC(16)
    localparam integer DAT_NOP    = RSP_END;                    // 104
    localparam integer DAT_TOKEN  = DAT_NOP + 8;                // 112
    localparam integer DAT_DATA   = DAT_TOKEN + 8;               // 120
    localparam integer DAT_CRC    = DAT_DATA + 512*8;            // 4216
    localparam integer DAT_END    = DAT_CRC + 16;                // 4232
    // CMD18：一个数据块（令牌 8 + 数据 4096 + CRC 16）= 4120 位
    localparam integer BLK_BITS   = 8 + 512*8 + 16;              // 4120

    // CMD18 的块内偏移 + 块号（组合计算）
    //   ⚠️ 必须放在上面这些 localparam 之后（Verilog-2001 不支持先用后声明）
    wire [16:0] dat_off = (edge_n >= DAT_DATA) ? ({1'b0, edge_n} - DAT_DATA) : 17'd0;
    wire [16:0] in_blk  = dat_off % BLK_BITS;
    wire [16:0] blk_idx = dat_off / BLK_BITS;

    // 预设数据：第 i 个字节 = i[7:0]（0x00,0x01,...,0xFF,0x00,...）
    // TB 用同一个公式核对 ⟹ 只要有一个字节错位就会报出来
    // （用位选而不是 function：Verible 对 function 参数类型有额外风格要求，
    //   而 Verilog-2001 里没法写 `input logic ...`，用位选最简单）

    //-------------------------------------------------------------------------
    // CS 下降沿：新的一帧开始
    //-------------------------------------------------------------------------
    always @(negedge sd_cs) begin
        edge_n     <= 16'd0;
        rx         <= 48'd0;
        rsp_en     <= 1'b0;
        is_cmd17   <= 1'b0;
        is_cmd18   <= 1'b0;
        sd_miso    <= 1'b1;
        // ⚠️ acmd41_cnt 不能在这里清零！
        //    每条命令结束时 CS 都会拉高，如果在这里清零，
        //    "第几次 ACMD41"就永远回不到 3 ⟹ 模型永远回"还在忙"⟹ DUT 死循环。
        //    它是"整张卡的初始化进度"，只在仿真开始时置一次。
    end

    initial acmd41_cnt = 8'd0;

    //-------------------------------------------------------------------------
    // 接收：在 posedge sd_clk 采样 MOSI
    //-------------------------------------------------------------------------
    always @(posedge sd_clk) begin
        if (sd_cs) begin
            // 空闲：保持计数器干净
            edge_n <= 16'd0;
            rx     <= 48'd0;
        end else begin
            edge_n <= edge_n + 16'd1;

            if (edge_n < CMD_BITS) begin
                rx <= {rx[46:0], sd_mosi};

                if (edge_n == (CMD_BITS - 1)) begin
                    // 48 位收满 ⟹ 解析成命令
                    cur_cmd     <= rx_next[45:40];
                    cur_arg     <= rx_next[39:8];
                    cmd_index   <= rx_next[45:40];
                    cmd_arg     <= rx_next[39:8];
                    cmd_valid   <= 1'b1;
                    rsp_en      <= 1'b1;
                    is_cmd17    <= (rx_next[45:40] == 6'h11) || (rx_next[45:40] == 6'h12);
                    is_cmd18    <= (rx_next[45:40] == 6'h12);
                    data_bit    <= 13'd0;
                    $display("    [模型] 收满 48 位 = 0x%012h  ⟹ cmd=0x%02h arg=0x%08h",
                             rx_next, rx_next[45:40], rx_next[39:8]);
                end else begin
                    cmd_valid <= 1'b0;
                end
            end else begin
                cmd_valid <= 1'b0;
            end
        end
    end

    //-------------------------------------------------------------------------
    // 组织响应内容（命令解析完就定下来，发的时候只管移位）
    //-------------------------------------------------------------------------
    always @(posedge sd_clk) begin
        if ((!sd_cs) && (edge_n == (CMD_BITS - 1))) begin
            case (rx_next[45:40])
                6'd0:  tx <= {8'h01, 40'h00_0000_0000};                        // CMD0  ⟹ R1=0x01
                6'd8:  tx <= {8'h01, 8'h00, 8'h00, 8'h01, 8'hAA, 8'hFF};       // CMD8  ⟹ R7
                6'h11: tx <= {8'h00, 40'h00_0000_0000};                        // CMD17 ⟹ R1=0x00
                6'h12: tx <= {8'h00, 40'h00_0000_0000};                        // CMD18 ⟹ R1=0x00
                6'd55: tx <= {8'h01, 40'h00_0000_0000};                        // CMD55 ⟹ R1=0x01
                6'd41: begin                                                   // ACMD41
                    acmd41_cnt <= acmd41_cnt + 8'd1;
                    if (acmd41_cnt >= (ACMD41_POLLS - 1))
                        tx <= {8'h00, 40'h00_0000_0000};                       // 就绪
                    else
                        tx <= {8'h01, 40'h00_0000_0000};                       // 还忙
                end
                default: tx <= {8'h01, 40'h00_0000_0000};
            endcase
        end
    end

    //-------------------------------------------------------------------------
    // 发送：在 negedge sd_clk 更新 MISO
    //   edge_n 是 posedge 计数，所以 negedge 时 edge_n 恰好是"刚跳过的那个"
    //-------------------------------------------------------------------------
    //-------------------------------------------------------------------------
    // 发送：按 edge_n 的区间决定输出什么
    //   CMD17 的命令，R1 之后还要跟：NOP + 令牌 0xFE + 512 字节 + CRC16
    //-------------------------------------------------------------------------
    // CMD17 的响应只有 1 个字节（R1），不是 48 位！
    // ⚠️ 这是个真 bug：原先 CMD17 的 tx 是 {8'h00, 40'h0}，48 位全 0，
    //    而模型把整 48 位都发了出去 ⟹ DUT 收完 8 位 R1 后，
    //    剩下那 40 个 0 被它当成"令牌"了 ⟹ 数据从 R1 中间就开始收。
    //    SD 规范：命令响应按命令类型定长（R1 = 1 字节），不是统一 48 位。
    wire [12:0] rsp_end_sel = is_cmd17 ? (RSP_START + 13'd8) : RSP_END;

    // 第 n 位对应的数据位（第 n/8 字节 = (n/8)[7:0]，字节内 MSB 先出）
    function pat_bit;
        input [12:0] n;
        reg [7:0] byte_v;
        begin
            byte_v = (n >> 3) & 12'h1FF;      // 第几个字节，取低 9 位
            pat_bit = byte_v[7 - n[2:0]];
        end
    endfunction

    // 数据块内当前位序号（组合计算，便于直接索引）
    // 用大位宽算完再截断，避免 unsigned 下溢
    wire [16:0] dat_idx_wide = {4'd0, edge_n} - {4'd0, DAT_DATA};
    wire [12:0] dat_idx = (edge_n >= DAT_DATA) ? dat_idx_wide[12:0] : 13'd0;
    wire [8:0]  dat_byte = dat_idx[12:3];      // 第几个字节
    wire [2:0]  dat_bitpos = dat_idx[2:0];     // 字节内第几位（0 = MSB）
    wire [7:0]  dat_val = dat_byte[7:0];      // 第 i 个字节 = i[7:0]
    wire        dat_out = dat_val[7 - dat_bitpos];

    always @(negedge sd_clk) begin
        if (sd_cs) begin
            sd_miso <= 1'b1;
        end else if (!rsp_en) begin
            sd_miso <= 1'b1;
        end else if (edge_n < RSP_START) begin
            sd_miso <= 1'b1;                                  // NOP：全 1
        end else if (edge_n < rsp_end_sel) begin
            sd_miso <= tx[47 - (edge_n - RSP_START)];         // 响应，MSB 先
        end else if (!is_cmd17) begin
            sd_miso <= 1'b1;
        end else if (!is_cmd18 && (edge_n < DAT_TOKEN)) begin
            sd_miso <= 1'b1;                                  // NOP（仅单块）
        end else if (!is_cmd18) begin
            //------------------- CMD17：单个数据块 -------------------
            if (edge_n < DAT_DATA) begin
                sd_miso <= (edge_n == (DAT_TOKEN + 7)) ? 1'b0 : 1'b1;  // 令牌 0xFE
            end else if (edge_n < DAT_CRC) begin
                sd_miso <= dat_out;                           // 512 字节数据
            end else if (edge_n < DAT_END) begin
                sd_miso <= 1'b0;                              // CRC16
            end else begin
                sd_miso <= 1'b1;
            end
        end else begin
            //------------------- CMD18：连续 BLOCKS 个块 -------------------
            //   块 k 从 DAT_DATA + k*BLK_BITS 开始，块内：
            //     0..7     令牌 0xFE
            //     8..4103  512 字节数据
            //     4104..   16 位 CRC
            if ((edge_n >= DAT_DATA) && (blk_idx < BLOCKS)) begin
                if (in_blk < 8)
                    sd_miso <= (in_blk == 7) ? 1'b0 : 1'b1;    // 令牌
                else if (in_blk < (8 + 512*8))
                    sd_miso <= pat_bit((in_blk - 8));          // 数据
                else
                    sd_miso <= 1'b0;                           // CRC
            end else begin
                sd_miso <= 1'b1;
            end
        end
    end

endmodule
