#=============================================================================
# touch.xdc - XPT2046 电阻触摸屏管脚约束
#-----------------------------------------------------------------------------
# 触摸 SPI（XPT2046）
#   DCLK : FPGA -> XPT2046，最大 2 MHz（手册上限，取低一点更稳）
#   nCS  : FPGA -> XPT2046，低有效
#   DIN  : FPGA -> XPT2046（发给控制器的命令字节是 MSB 先出）
#   DOUT : XPT2046 -> FPGA（读回 12 位坐标，MSB 先出）
#-----------------------------------------------------------------------------
#   40P 脚 37 = nCS  ->  JM1 37 = E19
set_property -dict {PACKAGE_PIN E19 IOSTANDARD LVCMOS33} [get_ports tp_cs_n]
#
#   40P 脚 38 = DOUT ->  JM1 38 = B20
set_property -dict {PACKAGE_PIN B20 IOSTANDARD LVCMOS33} [get_ports tp_dout]
#
#   40P 脚 39 = DCLK ->  JM1 39 = D19
set_property -dict {PACKAGE_PIN D19 IOSTANDARD LVCMOS33} [get_ports tp_dclk]
#
#   40P 脚 40 = DIN  ->  JM1 40 = A20
set_property -dict {PACKAGE_PIN A20 IOSTANDARD LVCMOS33} [get_ports tp_din]

# 驱动电流
# set_property DRIVE 12  [get_ports {tp_dclk tp_cs_n tp_din}]
# set_property SLEW  SLOW [get_ports {tp_dclk tp_cs_n tp_din}]
