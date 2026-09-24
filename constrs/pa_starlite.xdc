#=============================================================================
# pa_starlite.xdc - 璞致 PA-Starlite（XC7A100T-2FGG484I）板级约束
#-----------------------------------------------------------------------------
# 用于 bring-up 顶层（rtl/top.v）：时钟 + 复位 + 2 个 LED
#
# 【铁律】这个文件里的端口名必须和 rtl/top.v 的端口名完全一致，
#         改任何一边都要同步改另一边。
#
# 管脚来源：官方例程 XDC（已验证）+ Vivado 器件数据库核对（docs/06 §13）
#   时钟  R4/T4   IO_L13P/N_MRCC_34   200MHz 差分，bank34 Vcco=1.5V
#   复位  R14     IO_L19N_14          按键，低有效
#   LED0  W22     IO_L7N_T1_D10_14    高有效
#   LED1  Y22     IO_L9N_T1_DQS_D13_14
#=============================================================================

#-----------------------------------------------------------------------------
# 1. 器件配置属性（不写会导致比特流生成失败或配置异常）
#    来自官方例程，照抄
#-----------------------------------------------------------------------------
set_property CFGBVS VCCO                      [current_design]
set_property CONFIG_VOLTAGE 3.3               [current_design]
set_property BITSTREAM.GENERAL.COMPRESS true  [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE 50   [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4  [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE Yes [current_design]

#-----------------------------------------------------------------------------
# 2. 时钟约束
#-----------------------------------------------------------------------------
# 差分时钟只约束 P 端（N 端 Vivado 自动推导）
# 周期 5.000 ns = 200 MHz
create_clock -period 5.000 -name clk_200m [get_ports clk_200m_p]

# MMCM 的输出时钟（clk_sys / clk_pix / clkfb）由 Vivado 自动派生，
# 不需要手写 create_generated_clock。
#
# 注意：这里**故意不做过约束**。因为 clk_gen 里没有任何同步逻辑
# （LUT/FF 都是 0），时序本来就没有可优化的路径。
# 等后面加了真正的逻辑模块，再考虑按目标频率过约束来反推 Fmax。

# 输入时钟的抖动（板载晶振典型值）
set_input_jitter [get_clocks clk_200m] 0.010

#-----------------------------------------------------------------------------
# 3. 管脚约束
#-----------------------------------------------------------------------------
# 200 MHz 差分时钟
set_property -dict {PACKAGE_PIN R4  IOSTANDARD DIFF_SSTL15} [get_ports clk_200m_p]
set_property -dict {PACKAGE_PIN T4  IOSTANDARD DIFF_SSTL15} [get_ports clk_200m_n]

# 复位按键
set_property -dict {PACKAGE_PIN R14 IOSTANDARD LVCMOS33}   [get_ports rst_btn_n]

# LED
set_property -dict {PACKAGE_PIN W22 IOSTANDARD LVCMOS33}   [get_ports {led[0]}]
set_property -dict {PACKAGE_PIN Y22 IOSTANDARD LVCMOS33}   [get_ports {led[1]}]

#-----------------------------------------------------------------------------
# 4. 说明
#-----------------------------------------------------------------------------
# 未使用的板载资源（HDMI / MIPI / SD / UART / I2C / 40P 扩展口）暂不约束，
# 等对应模块做出来再往这里加。
#
# 如果之后要接 LCD，直接把官方例程 PZ_LCD.srcs/constrs_1/new/LCD.xdc 里
# 那 27 条 set_property 追加到本文件末尾即可（已核对，见 docs/06 §9.4）。
