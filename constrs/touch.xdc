#=============================================================================
# touch.xdc - XPT2046 电阻触摸屏管脚约束
#-----------------------------------------------------------------------------
# 【这份管脚是怎么定出来的 —— 证据链】
#
#   璞致没有给触摸屏例程，子卡原理图里的网络名也没有标 FPGA 管脚，
#   板子丝印上也没有。所以是三方交叉推出来的：
#
#   ① 子卡原理图（Puzhi 4.3 Inch LCD Schematic.pdf）
#      上面有两个 40 脚连接器：
#        · LCD1 = 屏的 FPC 座（TIANMA-TM043NDH02-40），对 FPGA 不可见
#        · CON40 / J1 = 与主板对接的 40 脚排针，这里才有 FPGA 信号
#      CON40 是【2x20 排针，左列全是奇数脚、右列全是偶数脚】：
#        37 = TP_SPI_nCS    38 = TP_SPI_DOUT
#        39 = TP_SPI_DCLK   40 = TP_SPI_DIN
#
#      ⚠️ 这里返过工：第一版按"标签的上下位置"去对，把 nCS/DCLK 和
#         DOUT/DIN 全写反了。**正确做法是先看左右的奇偶规律** ——
#         左列只可能是 37/39，右列只可能是 38/40，再去对上下顺序，
#         就不可能搞混。
#      控制器是 U2 = XPT2046（就在子卡上，四线 SPI），
#      XP/XN/YP/YN 接触摸面板，对 FPGA 不可见。
#
#   ② 主板连接器表（璞致PA-Starlite 连接器引脚信号和等长.xlsx，JM1 工作表）
#      给出 JM1 每一脚的 FPGA 管脚名与引脚号。
#
#   ③ 【关键交叉验证】我们已有的 LCD 映射，实测已经点亮：
#        lcd_clk = F18 = JM1 pin 30，而子卡 pin 30 丝印是 LCD_DCLK  ✅
#        lcd_hs  = C18 = JM1 pin 29，而子卡 pin 29 丝印是 LCD_HS    ✅
#        lcd_vs  = E18 = JM1 pin 32，而子卡 pin 32 丝印是 LCD_VS    ✅
#      三条全部对上 -> 【CON40 的脚号与 JM1 的脚号是一一对应的】(1:1)。
#
#   ④ 【反证】JM1 的 33/34/35/36 四脚是 GND，而子卡的 35/36 是空接
#      （原理图上画的是 no-connect 标记）。所以触摸信号【不可能】落在
#      35/36 —— 那样会被直接接地。只能是 37~40。
#
#   ⑤ 37~40 在 JM1 上是 E19 / B20 / D19 / A20，全是 bank 16 的真实 IO，
#      和 LCD 同一个 bank（Vcco = 3.3V，已被 LCD 实测证明）。
#
#   ⚠️ 注意：这【不是】lcdwiki 那个通用 40pin RGB 标准。
#      lcdwiki 的 P2 接口是 30=PCLK / 31=HSYNC / 32=VSYNC，
#      触摸在 35~39。璞致这块子卡是 29=HS / 30=DCLK / 32=VS，
#      触摸在 37~40 —— 是另一套排法。**以子卡原理图为准。**
#
# -----------------------------------------------------------------------------
# ⚠️ 上板第一次跑触摸时，如果四个信号全无反应，第一件事是拿示波器/
#    逻辑分析仪量 DCLK（E19）有没有波形。没有的话说明脚号推错了，
#    回来看这段注释，把候选换到 35/36 那一组试。
# -----------------------------------------------------------------------------

#-----------------------------------------------------------------------------
# 触摸 SPI（XPT2046）
#   DCLK : FPGA -> XPT2046，最大 2 MHz（手册上限，取低一点更稳）
#   nCS  : FPGA -> XPT2046，低有效
#   DIN  : FPGA -> XPT2046（发给控制器的命令字节是 MSB 先出）
#   DOUT : XPT2046 -> FPGA（读回 12 位坐标，MSB 先出）
#-----------------------------------------------------------------------------
# ⚠️ 注释必须【单独占一行】。
#   Tcl 只把"命令起始处"的 # 当注释；跟在命令参数后面的 # 会被当成
#   普通参数解析 —— 第一版写成 `... [get_ports tp_cs_n]  # 37 -> 37`，
#   结果 `->` 被当成 set_property 的选项，报了
#   [Common 17-170] Unknown option '->'。
#
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

# 排线比较长（子卡通过 40 脚排线接过来），驱动电流调大一点、压摆率放缓。
#   ⚠️ 只能对【输出】端口设 —— 对纯输入设 DRIVE 会触发 [Vivado 12-4702]
#      （见问题账本第 44 条）。
set_property DRIVE 12  [get_ports {tp_dclk tp_cs_n tp_din}]
set_property SLEW  SLOW [get_ports {tp_dclk tp_cs_n tp_din}]
