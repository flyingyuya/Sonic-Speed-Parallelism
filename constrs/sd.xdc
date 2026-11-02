#=============================================================================
# sd.xdc  ——  SD 卡（SPI 模式）引脚约束
#=============================================================================
#     SD_CLK   IO_L8P_14   AA20
#     SD_CMD   IO_L10P_14  AB21
#     SD_DATA0 IO_L17N_14  AB18
#     SD_DATA1 IO_L17P_14  AA18
#     SD_DATA2 IO_L10N_14  AB22
#     SD_DATA3 IO_L8N_14   AA21
#
#   【本工程用 SPI 模式（1 位），四根线】
#     SD_CLK   -> SD_CLK    （时钟，主机输出）
#     SD_CMD   -> SD_MOSI   （主机输出，卡片输入）
#     SD_DATA0 -> SD_MISO   （卡片输出，主机输入）
#     SD_DATA3 -> SD_CS     （片选，低有效）
#
#   电平：Bank 14 的 Vcco = 3.3V（板上 6 个 VCCO_14 全接 VDD_3V3），
#=============================================================================

#----------------------------- 引脚分配 --------------------------------------
set_property -dict { PACKAGE_PIN AA20  IOSTANDARD LVCMOS33 } [get_ports sd_clk]
set_property -dict { PACKAGE_PIN AB21  IOSTANDARD LVCMOS33 } [get_ports sd_mosi]
set_property -dict { PACKAGE_PIN AB18  IOSTANDARD LVCMOS33 } [get_ports sd_miso]
set_property -dict { PACKAGE_PIN AA21  IOSTANDARD LVCMOS33 } [get_ports sd_cs]

#----------------------------- 时序 ------------------------------------------
#     sd_ctrl_top 里的两个 SPI 时钟都是【由 clk_sys 分频得到的派生时钟】：
#       · 初始化阶段：sd_init 内部 div_clk (clk/240 = 200 kHz)
#       · 工作阶段  ：sd_ctrl_top 的 sd_clk_fast (clk/4 = 12 MHz)
#     它们都来自 clk_sys，Vivado 会自动按分频关系分析。

#
#----------------------------- 电气 ------------------------------------------
#   SD 卡座的 CMD/DATA 线板上已有上拉（SD 规范要求），这里不再加 PULLUP。
#     set_property PULLUP true [get_ports sd_miso]
