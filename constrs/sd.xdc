#=============================================================================
# sd.xdc  ——  SD 卡（SPI 模式）引脚约束
#=============================================================================
#   引脚来源：docs/06-board-resources.md 第 10 节（SD 卡座）
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
#   ⚠️ 为什么 CS 用 DATA3 而不是 DATA1：
#     SD 规范规定"SPI 模式下的片选是 DATA3"（进入 SPI 模式后 CS 有效）。
#     用 DATA3 也和绝大多数 SD 卡 SPI 驱动/参考设计一致。
#
#   ⚠️ 电平：Bank 14 的 Vcco = 3.3V（板上 6 个 VCCO_14 全接 VDD_3V3），
#     所以用 LVCMOS33。千万不要写 LVCMOS18/25 —— 那样会直接把 SD 卡打坏。
#=============================================================================

#----------------------------- 引脚分配 --------------------------------------
set_property -dict { PACKAGE_PIN AA20  IOSTANDARD LVCMOS33 } [get_ports sd_clk]
set_property -dict { PACKAGE_PIN AB21  IOSTANDARD LVCMOS33 } [get_ports sd_mosi]
set_property -dict { PACKAGE_PIN AB18  IOSTANDARD LVCMOS33 } [get_ports sd_miso]
set_property -dict { PACKAGE_PIN AA21  IOSTANDARD LVCMOS33 } [get_ports sd_cs]

#----------------------------- 时序 ------------------------------------------
#   【为什么这里没有 create_clock】
#     sd_ctrl_top 里的两个 SPI 时钟都是【由 clk_sys 分频得到的派生时钟】：
#       · 初始化阶段：sd_init 内部 div_clk (clk/240 = 200 kHz)
#       · 工作阶段  ：sd_ctrl_top 的 sd_clk_fast (clk/4 = 12 MHz)
#     它们都来自 clk_sys，Vivado 会自动按分频关系分析。
#     显式写 create_generated_clock 反而容易和自动推导冲突。
#
#     ⚠️ 但 sd_clk 是【输出】到卡上的，时序要求很低（≤25 MHz，且是 SPI），
#        所以这里也不加 set_output_delay —— 板级走线短、没有外部器件。
#
#   【如果以后时钟结构改成"独立 MMCM 出 SPI 时钟"】
#     那就必须在这里补 create_generated_clock + set_clock_groups，
#     否则会报跨域违例。
#
#----------------------------- 电气 ------------------------------------------
#   SD 卡座的 CMD/DATA 线板上已有上拉（SD 规范要求），这里不再加 PULLUP。
#   如果实测发现 MISO 在空闲时电平不稳，可以临时加：
#     set_property PULLUP true [get_ports sd_miso]
