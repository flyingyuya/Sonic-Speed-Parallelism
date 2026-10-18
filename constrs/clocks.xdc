#=============================================================================
# clocks.xdc - 时钟命名与跨时钟域声明
#-----------------------------------------------------------------------------
# 【为什么需要这个文件】
#   clk_gen 里 MMCM 的输出网名是 clk_sys_raw / clk_pix_raw，过 BUFG 后
#   Vivado 会把时钟自动传播下去，于是时钟对象就叫 *_raw。
#   而 lcd.xdc 里又在输出端口 lcd_clk 上 create_clock 建了一个 clk_pix ——
#   结果同一个物理时钟变成两个对象，跨域关系一片混乱。
#
#   更严重的是：**没有任何异步时钟组声明**，Vivado 于是把 clk_sys 和 clk_pix
#   之间的路径当同步关系硬算。整机第一次实现就因此报
#     WNS = -1.497 ns / TNS = -249 ns
#   而"关键路径"的 Requirement 只有 0.833 ns —— 纯属工具在算一条
#   本来就不需要算的路径。
#
#   这个现象和第 26 条踩坑是**同一类**：工具报出来的数字要看清它到底在算什么。
#
# 【本文件的三个作用】
#   1. 用 MMCM 输出引脚显式命名时钟，不再依赖自动推导的网名
#   2. 声明 clk_sys 与 clk_pix 互为异步（本工程所有跨域都走格雷码异步 FIFO）
#   3. 把 LCD 输出时钟建模成 clk_pix 的【转发时钟】，而不是另一个独立时钟
#
# ⚠️ 依赖实例路径 —— 本工程综合时用 `-flatten_hierarchy none`，层次保留，
#    所以 u_clkgen/u_mmcm、u_clkgen/u_bufg_sys 这些名字是稳定的。
#=============================================================================

#-----------------------------------------------------------------------------
# 1. 显式命名 MMCM 输出的两个时钟（以 BUFG 输出为基准点）
#-----------------------------------------------------------------------------
create_generated_clock -name clk_sys \
    -source  [get_pins u_clkgen/u_mmcm/CLKOUT0] \
    -divide_by 1 \
    [get_pins u_clkgen/u_bufg_sys/O]

create_generated_clock -name clk_pix \
    -source  [get_pins u_clkgen/u_mmcm/CLKOUT1] \
    -divide_by 1 \
    [get_pins u_clkgen/u_bufg_pix/O]

#-----------------------------------------------------------------------------
# 2. 跨时钟域声明
#-----------------------------------------------------------------------------
# clk_sys（音频/控制）与 clk_pix（显示扫描）完全异步：
# 它们由同一个 MMCM 产生、有固定相位关系，但**不能按同步路径分析** ——
# 两者的频率比是 48:12.5（非整数），任何跨域信号都必须经过同步器，
# 而不是靠"恰好满足建立/保持"。
#
# 本工程的所有跨域都收敛在一处：rtl/common/async_fifo.v 的格雷码指针
#   clk_sys 写侧 ──wgray──▶ 2 级同步 ──▶ clk_pix 读侧
#   clk_pix 读侧 ──rgray──▶ 2 级同步 ──▶ clk_sys 写侧
# 格雷码保证相邻值只差 1 位，所以多比特总线不需要额外的偏斜约束。
# （report_cdc 已确认：两端 Unsafe = 0、缺 ASYNC_REG = 0）
set_clock_groups -asynchronous \
    -group [get_clocks clk_sys] \
    -group [get_clocks clk_pix]

#-----------------------------------------------------------------------------
# 3. LCD 像素时钟：clk_pix 的转发时钟
#-----------------------------------------------------------------------------
# lcd_clk 是把 clk_pix 直接送到输出脚（见 rtl/video/disp_top.v）。
# 正确建模方式是"从 clk_pix 派生的转发时钟"，而不是再 create_clock 一个
# 独立的 80 ns 时钟 —— 后者会让 lcd_rgb/lcd_hs/lcd_vs 的相对时序失去参照系。
create_generated_clock -name clk_pix_fwd \
    -source  [get_pins u_clkgen/u_bufg_pix/O] \
    -divide_by 1 \
    [get_ports lcd_clk]

# 面板手册没有给出 setup/hold 要求，这里用保守占位值：
#   数据在时钟沿后 2 ns 内稳定（给面板留 2 ns setup），至少保持到沿前 1 ns。
# 12.5 MHz（80 ns 周期）下这个约束很宽松。拿到面板手册后再收紧。
set_output_delay -clock clk_pix_fwd -max  2.000 \
    [get_ports {lcd_rgb[*] lcd_hs lcd_vs}]
set_output_delay -clock clk_pix_fwd -min -1.000 \
    [get_ports {lcd_rgb[*] lcd_hs lcd_vs}]


#-----------------------------------------------------------------------------
# ★ BCLK：现在【真的被当时钟用了】
#-----------------------------------------------------------------------------
#   i2s_bclk_if 用 posedge aud_bclk 直接采样 ADCDAT（教科书 I2S 做法）。
#   Vivado 会自动把它识别成时钟，但不写约束的话这条路径上的时序
#   不受分析保护 —— 必须显式声明。
#   BCLK = 3.072 MHz -> 325.52 ns
#   （WM8960 主模式、SYSCLK=12.288MHz、BCLKDIV=0100 -> /4）
#
#   注意：i2s_slave_clk 仍然存在（发送侧还在用它恢复时序），
#   所以这里【不要】把 bclk/lrclk 从它那边摘掉；两者是并存的。
#-----------------------------------------------------------------------------
create_clock -name clk_bclk -period 325.520 [get_ports aud_bclk]

# BCLK 与 clk_sys / clk_pix 异步（同源于模块 24MHz 晶振，但分频不同、
# 相位关系不做保证）。跨域靠"翻转标志 + 数据保持"。
set_clock_groups -asynchronous \
    -group [get_clocks clk_bclk] \
    -group [get_clocks clk_sys] \
    -group [get_clocks clk_pix]

#=============================================================================
# 【待办】HDMI 域与 clk_sys 的异步约束
#=============================================================================
#   现状：spec_sync 的 async_fifo、wave_buf 的 done_tog/rd_tog 是【设计上异步】
#         的跨域路径。默认流程能容忍（26 条 Slack VIOLATED 不报错），
#         但加了 route_design -timing_summary 就会报 CRITICAL。
#
#   为什么没写约束：clk_hdmi_raw / clk_5x_raw 是 MMCM 生成时钟，
#         在 set_clock_groups 生效的时刻名字对不上（试过，报 11 条 CRITICAL）。
#         正确做法是用 create_generated_clock 给它们显式命名，
#         或者用 -include_generated_clocks 按源时钟分组 —— 需要先 report_clocks
#         确认实际名字。
#
#   当前补偿措施：所有【非】异步 FIFO 的跨域信号（ui_sel / panel_tog / key_act）
#         都已在 top.v 里各加了 cdc_sync 两级同步器，不依赖这条约束。
#   ⟹ 所以现在不加这条约束是安全的，但欠一笔"约束债"，上更高分辨率前要还。
#=============================================================================
