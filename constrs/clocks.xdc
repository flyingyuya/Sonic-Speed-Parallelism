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
