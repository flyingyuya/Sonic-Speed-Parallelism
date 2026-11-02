#=============================================================================
# hdmi.xdc —— HDMI 输出（DVI 兼容，只用到 TMDS 四对差分 + 使能 + HPD）
#=============================================================================
# 【管脚来源】
#   docs/06-board-resources.md §6「HDMI 输出」—— 那张表是把原理图第 14 页
#   「PA-StarLite – HDMI OUT」渲染成图后逐条读出来的，不是 PDF 文本提取。
#
# 【硬件事实】
#   · 板上【没有 HDMI 发送芯片】—— FPGA 的 4 对差分直接经 51Ω 串阻到连接器 J5
#     ⟹ TMDS 编码、串行化、差分全部由 FPGA 做（本工程的 tmds_enc / tmds_out）
#   · Bank 14 的 Vcco 是 3.3V（原理图 VCCO_14 x6 全接 VDD_3V3）
#     ⟹ IOSTANDARD 用 TMDS_33 的前提成立
#   · HDMI_OUT_EN 接 NC7SZ125 缓冲器的 OE，【低有效】（原理图 U14 的 0E 有上划线）
#   · HDMI_CEC 在手册里有笔误（W22 是 LED1），实际应为 U17 —— 本工程【不用 CEC】
#   · DDC（I2C：U20/T21）本工程不用 —— 不读显示器 EDID
#     代价：显示器只会按 800x600 的默认时序试锁；多数显示器能锁上
#     以后要兼容更多显示器再加 EDID 读取
#
# 【为什么现在就能加约束】
#   top.v 里 hdmi_top 还是【孤儿模块】（没例化），所以这些端口还不存在。
#   本文件先写好，等 top.v 接好端口后 include 进来即可。
#   ⚠️ 在端口还不存在的时候 include 它，Vivado 会报 get_ports 找不到 ——
#      所以 build.tcl / top.v 的接好必须和本文件【同一批】落地。
#=============================================================================

#-----------------------------------------------------------------------------
# TMDS 时钟通道（1 对差分）
#   TMDS 时钟就是像素时钟本身（800x600@60 是 40 MHz），不编码不串行化
#-----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN Y18 IOSTANDARD TMDS_33} [get_ports hdmi_clk_p]
set_property -dict {PACKAGE_PIN Y19 IOSTANDARD TMDS_33} [get_ports hdmi_clk_n]

#-----------------------------------------------------------------------------
# TMDS 数据通道 0 = 蓝（消隐期还要传 hsync/vsync）
#-----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN V18  IOSTANDARD TMDS_33} [get_ports hdmi_d0_p]
set_property -dict {PACKAGE_PIN V19  IOSTANDARD TMDS_33} [get_ports hdmi_d0_n]

#-----------------------------------------------------------------------------
# TMDS 数据通道 1 = 绿
#-----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN AA19 IOSTANDARD TMDS_33} [get_ports hdmi_d1_p]
set_property -dict {PACKAGE_PIN AB20 IOSTANDARD TMDS_33} [get_ports hdmi_d1_n]

#-----------------------------------------------------------------------------
# TMDS 数据通道 2 = 红
#-----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN V17  IOSTANDARD TMDS_33} [get_ports hdmi_d2_p]
set_property -dict {PACKAGE_PIN W17  IOSTANDARD TMDS_33} [get_ports hdmi_d2_n]

#-----------------------------------------------------------------------------
# 板级控制
#   HDMI_OUT_EN：接 NC7SZ125 的 OE，低有效 -> 本设计在 RTL 里恒驱动 0
#   HDMI_HPD  ：热插拔检测（显示器接上时被拉高）。本工程暂不参与逻辑，
#               但必须约束成输入，否则 Vivado 会当成悬空
#-----------------------------------------------------------------------------
set_property -dict {PACKAGE_PIN V22 IOSTANDARD LVCMOS33} [get_ports hdmi_out_en]
set_property -dict {PACKAGE_PIN V20 IOSTANDARD LVCMOS33} [get_ports hdmi_hpd]

#=============================================================================
# 时序约束
#=============================================================================
# 【像素时钟（40 MHz）和串行时钟（200 MHz）都是 MMCM 产生的】
#   它们同源同 VCO（VCO = 1000 MHz），Xilinx 会自动推导它们之间的关系，
#   所以这里【不需要】再写 create_clock / set_clock_groups。
#
# 【强烈建议第一版【不要】给 TMDS 输出加 set_output_delay】
#   TMDS 的"输出时序"是相对于它自己转发出去的时钟（hdmi_clk）来定义的，
#   要写就得先 create_generated_clock 在 hdmi_clk_p 上，
#   再按 TMDS 的眼图要求给数据线写 set_output_delay ——
#   没上过板、没量过眼图之前，这些数字都是猜的。
#   ⟹ 第一版靠 Vivado 默认的 I/O 时序分析即可，出图之后再按实测补约束。
#   （"先让它出来，再让它稳" —— 和本项目一贯的"分步验收"一致。）
