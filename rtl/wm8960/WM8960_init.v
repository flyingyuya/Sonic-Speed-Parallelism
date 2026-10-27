//////////////////////////////////////////////////////////////////////////////////
// Company:
// Engineer:       Binyu Fei
//
// Create Date:    2026-10-26
// Design Name:    WM8960_init
// Module Name:    WM8960_init
// Project Name:   音速并行（Sonic-Speed-Parallelism）
// Target Devices: Xilinx Artix-7 XC7A100T-2FGG484I
// Tool versions:  Vivado 2020.2 / iverilog 12 / Verilator 5.052 / Verible
// Description:    WM8960_init.v - WM8960 上电初始化（通过 I2C 顺序写寄存器表）
// Dependencies:   见文件内 `include
//
// Revision:
// Revision 0.01 - File Created
//
//////////////////////////////////////////////////////////////////////////////////
`timescale 1ns / 1ps


module WM8960_init #(
    parameter integer CLK_FREQ_HZ = 48_000_000,   // 本模块工作时钟频率
    parameter integer DLY_MS      = 1              // 每条寄存器之间插入的延时(ms)
) (
    input           Clk,
    input           Rst_n,

    input           Go,
    input [7:0]     device_id,     // I2C 7 位地址 + R/W 位（WM8960 = 0x34）

    //--------------------- 输入源选择 ---------------------
    //   0 = 话筒（LINPUT1）   1 = 线路输入（LINPUT3/RINPUT3）
    //   只影响 R32/R33/R0/R1 四条，其余完全一样 ⟹ ROM 读出后覆盖这 4 条
    //   话筒 0x118 = LMN1 + boost 01(+13dB) + LMIC2B
    //   线路 0x088 = LMP3 + boost 00( 0dB) + LMIC2B（线路电平高，boost/PGA 回 0dB）
    //   ⚠️ 数据字段只有 9 位：0x088 装得下，写 0x808 会被截断
    input           src_sel,
    output reg      Init_Done,

    output          i2c_sclk,
    inout           i2c_sdat
);

    //=========================================================================
    // 寄存器表（内容由 scripts/golden/gen_wm8960_table.py 生成）
    //=========================================================================
    //   条数来自生成的头文件，不再自己硬编码
    //   （曾经硬编码 20 而表是 24 ⟹ 只发前 20 条 ⟹ 报错却是"最后一条不是 R4"）
    `include "wm8960_nreg.vh"

    localparam integer LUT_SIZE = WM8960_NREG;     // 本表实际条数
    localparam integer TBL_AW   = $clog2(LUT_SIZE);// 恰好装得下 LUT_SIZE 的位宽
    localparam integer DLY_CNT  = CLK_FREQ_HZ / 1000 * DLY_MS;
    localparam        ADDR_MODE = 1'b0;

    wire [TBL_AW-1:0] tbl_addr;

    // ⚠️ 必须【先声明】：下面 ROM 例化的 .q(lut_raw) 就要用它。
    //   Verilog-2001 里 wire 是"声明在前"，赋值在后面没关系，声明不行。
    //   （这个坑本轮踩了第二次 —— 上一次在 disp_top 的 ui_active。）
    wire [15:0] lut_raw;                            // ROM 原始输出

    WM8960_init_table #(
        .ADDR_WIDTH (TBL_AW)
    ) WM8960_init_table (
        .addr (tbl_addr),
        .clk  (Clk),
        .q    (lut_raw)
    );

    //-------------------------------------------------------------------------
    // 输入源覆盖：4 条与"话筒/线路"有关的寄存器在这里被改写
    //   表项格式 {7 位寄存器地址, 9 位数据}，所以字面量也要是这个拼接宽度
    //   （写成 {8'h20, 9'h...} 会变成 17 位 -> 高字节错位 -> 静默写错寄存器）。
    //-------------------------------------------------------------------------
    //   ⚠️ 寄存器地址在 lut[15:9]（7 位），【不是】lut[15:8] ——
    //      lut[8] 是数据的最高位（9 位数据的 bit8）。
    //      第一版写成 lut[15:8] 并拿 8'h20 去比，条件永远不成立、覆盖等于没写。
    //      拿本表举例：R32 存的是 {7'h20, 1'b1}，lut[15:8] = 8'h41 而不是 8'h20。
    wire [6:0] lut_reg = lut_raw[15:9];
    wire [15:0] lut =
          // ⚠️ 话筒模式【原样输出】—— 一个比特都不改。
          //    这一条是被 TB 逼出来的：表里 R21(0x21)=0x000 是【故意】的
          //    （单声道话筒，ADCR 关掉，靠 DATSEL=01 把左路复制到右路）。
          //    我第一版无条件把 R33 覆盖成 0x118，等于把右路打开 —— 真实的行为改变，
          //    TB 立刻报了"事务条数与逐条比对不符"。改成"只在线路模式覆盖"就干净了。
          !src_sel ? lut_raw
        : (lut_reg == 7'h20) ? {7'h20, 9'h088}   // R32 输入信号路径 L：LINPUT3 + 0dB + LMIC2B
        // R33：线路模式下把【右路】接到 RINPUT1（bit8 = RMN1）
        //   为什么用 RINPUT1 而不是 RINPUT3：
        //     · RINPUT3 在板上经 R2 = 0Ω 直连【直流耦合】，配套的是麦克风偏置
        //     · RINPUT1 在板上经 C4 = 1µF 【交流耦合】⟹ 信号会自己偏到芯片中点
        //     · 线路信号（电脑/手机输出）是以 0V 为中心的交流信号，
        //       走交流耦合才不会被偏置顶出 PGA 的线性区
        //   【关键实验】用户观察："声音是从 RP/RN（右喇叭）出来的"
        //     ⟹ 信号的模拟通路是 RINPUT1 → ROUT1
        //     ⟹ 所以座子 RING2 实际接的应该是 RINPUT1，而不是 RINPUT3
        //   之前试过 0x108 但那时【旁路还开着】✗ 测不出 ADC 能不能收到
        //   现在是"RINPUT1 + 旁路已关"这个组合，第一次测 ✓
        //   0x108 = RMN1(bit8) + boost=00(0dB) + RMIC2B(bit3)
        : (lut_reg == 7'h21) ? {7'h21, 9'h108}
        // R0/R1：线路模式的 PGA 音量
        //   【为什么从 0 dB 提到 +12 dB】
        //     话筒模式有 boost = +13 dB（R32 的 bit[5:4]）✗ 线路模式 boost = 0 dB
        //     ⟹ 线路模式下送进 FFT 的信号比话筒小 13 dB（约 4.5 倍）
        //     ⟹ 表现为"电脑音量要开到 50% 以上频谱才有反应"（用户实测）
        //   ⚠️ PGA 的换算公式（这句一定要按公式算，不能拍脑袋）：
        //        gain(dB) = -17.25 + 0.75 × code
        //        0x17 = 23  ⟹ -17.25 + 17.25 = 0 dB   （验证：和原注释一致 ✓）
        //        +12 dB  ⟹ code = (12 + 17.25) / 0.75 = 39 = 0x27
        //   ❌ 我第一版写成 0x40（= 64）⟹ +30.75 dB，超出 0..0x3F 的合法范围
        //      ⟹ 芯片认为非法值 ⟹ 实测直接静音（"又没反应了"就是这个）
        //   ⚠️ 用户实测：+12 dB 高频失真、+6 dB 仍有噪声 ⟹ 回到 0 dB
        //        code = 0x17 (23) ⟹ -17.25 + 0.75×23 = 0 dB
        : (lut_reg == 7'h00) ? {7'h00, 9'h117}   // R0  PGA 音量 L：0dB
        : (lut_reg == 7'h01) ? {7'h01, 9'h117}   // R1  PGA 音量 R：0dB
        // R23（0x17）：DATSEL 改成 11 = 【单声道混合 (L+R)/2 → 两路 DAC】
        //   为什么用 11 而不是 10（右路复制）：
        //     线路信号只接到右路（RINPUT1）✗ 左路（LINPUT3）是空的
        //     DATSEL=10 理论上会把右路复制到两路，但实测只有一边响
        //     ⟹ 说明这条路径没按预期工作（可能是寄存器写入时序/位域理解）
        //     改用 11（mono mix）更稳：不管信号在哪一路，两路 DAC 都拿到混合结果 ✓
        //   代价：音量减半（可以调 PGA 补回来）
        //   ⚠️ R23 的其它位保持不变：TSDEN=1，低 2 位是 DATSEL
        : (lut_reg == 7'h17) ? {7'h17, 9'b1_1100_0111}
        // R45/R46：模拟旁路【只在线路模式下打开】
        //   【为什么需要这个】
        //     用户用"手指注入 50Hz"定位到：
        //       摸 R1 的 INPUT_R1 侧 ⟹ 有反应 ⟹ RINPUT1→ADC 是通的 ✓
        //       从座子插线进来   ⟹ 没反应 ⟹ 断在【座子 → C4 → INPUT_R1】
        //     ⟹ C4(1µF) 开路/虚焊 ✗ 数字路永远收不到线路信号（需要焊才能修）
        //     而模拟旁路那条能通（实测"旁路开着时线路从右喇叭出声"✓）
        //   ⟹ 折中：只在【线路模式】打开旁路
        //         · 话筒模式：旁路关 ⟹ 双声道 + SPK 静音 + EQ 全有效 ✓
        //         · 线路模式：旁路开 ⟹ 线路信号能听到（单声道，走后喇叭）
        //     代价：线路模式下 EQ / SPK 静音对它无效（旁路绕过 DAC）
        //     0x080 = 0 dB 旁路增益
        : (lut_reg == 7'h2D) ? {7'h2D, 9'b0_1000_0000}   // L bypass ON（仅线路）
        : (lut_reg == 7'h2E) ? {7'h2E, 9'b0_1000_0000}   // R bypass ON（仅线路）
        : lut_raw;

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
        //=========================================================================
        // 重入修复（上板暴露的真 bug）
        //=========================================================================
        //   原写法：Go 只清 cnt、不清 state，而且整个 case 被
        //   `cnt < LUT_SIZE` 门控 —— Go 只在 case 的 state==0 分支里被检查。
        //   重配时（切换音频输入源）会这样坏掉：
        //     Go 到达那一拍：cnt 还是旧值 LUT_SIZE ⟹ 整块不进入 ⟹ Go 被吞
        //     下一拍：cnt 已被清零、块进入了，但 Go（单拍脉冲）已经消失
        //             ⟹ state 停在 0，永不发起写 ⟹ cnt 卡在 0
        //     ⟹ Init_Done 恒 0（LED1 灭）
        //     ⟹ top.v 的 aud_rst_n = rst_sys_n & init_done 把音频通路按住复位
        //     ⟹ 上板现象：切 I01 后静音、频谱冻住、LED1 灭；断电重启才恢复
        //   修法：新增 `Go` 分支，【直接置 state=1】绕过门控。
        //   为什么是 1 而不是 0：Go 是单拍脉冲，置 0 之后没有任何东西
        //   能再把它推到 1 了，会永久卡在 IDLE。
        //=========================================================================
        end else if (Go) begin
            state     <= 2'd1;              // 直接发起第一条写
            wrreg_req <= 1'b0;
        end else if (cnt < LUT_SIZE) begin
            case (state)
                2'd0: begin
                    state <= 2'd0;          // Go 已在上面分支处理，这里只保持
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
