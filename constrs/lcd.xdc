#=============================================================================
# lcd.xdc - 480x272 液晶屏管脚与时序约束
#-----------------------------------------------------------------------------
# ⚠️ 本文件只有在 top 里【已经存在 lcd_* 端口】之后才能 read_xdc，
#    否则 Vivado 会因为找不到端口直接报错。
#
# 管脚来源：璞致官方例程 docs/璞致FPGA核心开发版/05.FPGA源码教程/
#           3_16_PZ_LCD/PZ_LCD.srcs/constrs_1/new/LCD.xdc
#           已用 27 条逐一核对（24 位色 + clk/hs/vs）。
#
# 该屏【没有 DE 脚】—— 子卡上用 0 欧姆电阻把 LCD_DE 直接拉高，
# 面板控制器靠 HS/VS + 固定时序自己推算有效区，所以本工程不驱动 DE。
#
# 电平：全部 LVCMOS33（Bank 34/35 的 Vcco = 3.3V）
#=============================================================================

#-----------------------------------------------------------------------------
# 1. 数据与同步（24 位 RGB888 + HS + VS）
#-----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN F13 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[0]}]
set_property -dict {PACKAGE_PIN E16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[1]}]
set_property -dict {PACKAGE_PIN F14 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[2]}]
set_property -dict {PACKAGE_PIN D16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[3]}]
set_property -dict {PACKAGE_PIN D14 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[4]}]
set_property -dict {PACKAGE_PIN C13 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[5]}]
set_property -dict {PACKAGE_PIN D15 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[6]}]
set_property -dict {PACKAGE_PIN B13 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[7]}]
set_property -dict {PACKAGE_PIN C14 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[8]}]
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[9]}]
set_property -dict {PACKAGE_PIN C15 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[10]}]
set_property -dict {PACKAGE_PIN A14 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[11]}]
set_property -dict {PACKAGE_PIN E13 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[12]}]
set_property -dict {PACKAGE_PIN A15 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[13]}]
set_property -dict {PACKAGE_PIN E14 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[14]}]
set_property -dict {PACKAGE_PIN A16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[15]}]
set_property -dict {PACKAGE_PIN B15 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[16]}]
set_property -dict {PACKAGE_PIN B17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[17]}]
set_property -dict {PACKAGE_PIN B16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[18]}]
set_property -dict {PACKAGE_PIN B18 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[19]}]
set_property -dict {PACKAGE_PIN F16 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[20]}]
set_property -dict {PACKAGE_PIN D17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[21]}]
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[22]}]
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS33} [get_ports {lcd_rgb[23]}]

set_property -dict {PACKAGE_PIN C18 IOSTANDARD LVCMOS33} [get_ports lcd_hs]
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS33} [get_ports lcd_vs]

#-----------------------------------------------------------------------------
# 2. 像素时钟输出
#-----------------------------------------------------------------------------
# F18 作为普通 IO 直接把 MMCM 的 clk_pix 送出去（官方例程同样写法，已实测可用）。
set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS33} [get_ports lcd_clk]

# 注意：lcd_clk 的时钟建模（转发时钟 clk_pix_fwd）和三个同步信号的
# set_output_delay 都放在 clocks.xdc 里，因为那里才拿得到 MMCM 的引脚路径。

#-----------------------------------------------------------------------------
# 4. 引脚所在 Bank 的配置电压（器件级属性，写一次即可）
#-----------------------------------------------------------------------------
# set_property CFGBVS VCCO        [current_design]
# set_property CONFIG_VOLTAGE 3.3 [current_design]
