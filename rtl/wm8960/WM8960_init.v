//=============================================================================
// WM8960_init.v - WM8960 上电初始化（通过 I2C 顺序写寄存器表）
//-----------------------------------------------------------------------------
// 来源：参考 docs/Music-Spectrum 工程的 WM8960_Init.v，针对我们的板子做了
//       五处必要修改（见文件末尾「相对参考工程的改动」）。
//
// 【为什么要留延时 DLY_MS】
//   我们的配置启用 WM8960 内部 PLL：24 MHz 晶振 -> PLL -> SYSCLK = 12.288 MHz。
//   PLL 从使能到锁定需要时间（典型 1~10 ms）。如果在这之前就把 CLKSEL 切到
//   PLL，SYSCLK 会短暂没有时钟 —— BCLK/LRCLK 乱掉，而 FPGA 侧是 I2S 从机，
//   会收到一堆垃圾。
//   寄存器表把 `CLKSEL=1` 放在【最后一条】，并在每条之间留 DLY_MS 毫秒，
//   这样从 PLLEN=1 到 CLKSEL=1 之间至少有几个 ms，足够锁定。
//
// 【时序预算】LUT_SIZE(20) x DLY_MS(1ms) ≈ 20 ms，只在 Go 拉高时跑一次。
//=============================================================================
`timescale 1ns / 1ps

module WM8960_init #(
    parameter integer CLK_FREQ_HZ = 48_000_000,   // 本模块工作时钟频率
    parameter integer DLY_MS      = 1              // 每条寄存器之间插入的延时(ms)
) (
    input           Clk,
    input           Rst_n,

    input           Go,
    input [7:0]     device_id,     // I2C 7 位地址 + R/W 位（WM8960 = 0x34）
    output reg      Init_Done,

    output          i2c_sclk,
    inout           i2c_sdat
);

    //-------------------------------------------------------------------------
    // 寄存器表（内容由 scripts/golden/gen_wm8960_table.py 生成）
    //-------------------------------------------------------------------------
    localparam integer LUT_SIZE = 20;              // 本表实际条数
    localparam integer TBL_AW   = $clog2(LUT_SIZE);// 恰好装得下 LUT_SIZE 的位宽
    localparam integer DLY_CNT  = CLK_FREQ_HZ / 1000 * DLY_MS;
    localparam        ADDR_MODE = 1'b0;

    wire [TBL_AW-1:0] tbl_addr;
    wire [15:0]       lut;

    WM8960_init_table #(
        .ADDR_WIDTH (TBL_AW)
    ) WM8960_init_table (
        .addr (tbl_addr),
        .clk  (Clk),
        .q    (lut)
    );

    // lut = {7 位寄存器地址, 9 位数据}
    //   I2C 按字节发 16 位字：高字节 = {reg[6:0], data[8]}，低字节 = data[7:0]
    //   i2c_control 的 addr_mode=0 分支会跳过 cnt==2，正好只发 3 个字节
    wire [7:0] addr   = lut[15:8];
    wire [7:0] wrdata = lut[7:0];

    reg  [7:0] cnt;                                // 表项计数器
    reg        wrreg_req;
    reg  [1:0] state;

    wire [7:0] rddata;
    wire       RW_Done;
    wire       ack;

    assign tbl_addr = cnt[TBL_AW-1:0];

    //-------------------------------------------------------------------------
    // I2C 字节级控制器
    //-------------------------------------------------------------------------
    i2c_control #(
        .SYS_CLOCK(CLK_FREQ_HZ),
        .SCL_CLOCK()
    ) i2c_control (
        .Clk         (Clk),
        .Rst_n       (Rst_n),

        .wrreg_req   (wrreg_req),
        .rdreg_req   (1'b0),          // 只写不读（显式 1 位，避免位宽告警）
        .addr        ({8'h00, addr}), // 8 位寄存器地址扩展到 16 位端口
        .addr_mode   (ADDR_MODE),
        .wrdata      (wrdata),
        .rddata      (rddata),
        .device_id   (device_id),
        .RW_Done     (RW_Done),
        .ack         (ack),

        .dly_cnt_max (DLY_CNT),       // 每条之间留出 PLL 锁定时间
        .i2c_sclk    (i2c_sclk),
        .i2c_sdat    (i2c_sdat)
    );

    //-------------------------------------------------------------------------
    // 表项计数器
    //   原来的写法在 cnt 到 LUT_SIZE 后会清零，于是整个表被反复重写；
    //   只是因为参考工程给的是 Go 脉冲、且 state 停住了才没暴露。
    //   这里改成【停在 LUT_SIZE 不动】，不再依赖 Go 是不是脉冲。
    //-------------------------------------------------------------------------
    always @(posedge Clk or negedge Rst_n) begin
        if (!Rst_n)
            cnt <= 8'd0;
        else if (Go)
            cnt <= 8'd0;
        else if (cnt < LUT_SIZE) begin
            if (RW_Done && (!ack))
                cnt <= cnt + 1'b1;
            else
                cnt <= cnt;
        end else
            cnt <= cnt;                            // 保持，不回绕
    end

    //-------------------------------------------------------------------------
    // 完成标志：写完最后一条之后拉高并保持
    //-------------------------------------------------------------------------
    always @(posedge Clk or negedge Rst_n) begin
        if (!Rst_n)
            Init_Done <= 1'b0;
        else if (Go)
            Init_Done <= 1'b0;
        else if (cnt == LUT_SIZE)
            Init_Done <= 1'b1;
    end

    //-------------------------------------------------------------------------
    // 主状态机：0=空闲  1=发起一次写  2=等这次写完
    //-------------------------------------------------------------------------
    always @(posedge Clk or negedge Rst_n) begin
        if (!Rst_n) begin
            state     <= 2'd0;
            wrreg_req <= 1'b0;
        end else if (cnt < LUT_SIZE) begin
            case (state)
                2'd0: begin
                    if (Go)
                        state <= 2'd1;
                    else
                        state <= 2'd0;
                end

                2'd1: begin
                    wrreg_req <= 1'b1;
                    state     <= 2'd2;
                end

                2'd2: begin
                    wrreg_req <= 1'b0;
                    if (RW_Done)
                        state <= 2'd1;              // 继续写下一条
                    else
                        state <= 2'd2;
                end

                default: state <= 2'd0;
            endcase
        end else begin
            state     <= 2'd0;
            wrreg_req <= 1'b0;                      // 明确清零，不留悬空
        end
    end

endmodule

//=============================================================================
// 相对参考工程（docs/Music-Spectrum）的改动
//-----------------------------------------------------------------------------
//  1. LUT_SIZE 14 -> 20
//     新增 6 条：R8(BCLKDIV) + R52/R53/R54/R55(PLL) + R4(CLKSEL)
//     并把 R26 拆成两次写（先不带 PLLEN，PLL 配好后再置 PLLEN=1）
//
//  2. R26 数据 0x060 -> 0x1E1
//     补上 DACL=1 / DACR=1 —— 参考工程只用 ADC 做频谱，不需要 DAC；
//     我们要做音频回放（EQ 通路），DAC 必须开。
//
//  3. 新增 CLK_FREQ_HZ / DLY_MS 参数，dly_cnt_max 由 0 改为 DLY_CNT
//     PLL 需要锁定时间，且留延时还能避免 I2C 连续写得太快。
//
//  4. 表项计数器到 LUT_SIZE 后保持，不再清零回绕
//
//  5. rdreg_req 显式写 1'b0（原来是 32 位常量 0，iverilog 报位宽修剪告警）；
//     addr 显式扩展到 16 位
//=============================================================================
