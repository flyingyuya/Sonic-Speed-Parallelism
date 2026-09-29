#=============================================================================
# audio.xdc - WM8960 音频模块管脚约束（接 JM2）
#-----------------------------------------------------------------------------
# 管脚来源：docs/璞致FPGA核心开发版/04.硬件相关/02.连接器管脚与等长/
#           "Puzhi PA-Starlite Connectors Pins Signal and Equal Length.xlsx"
#           的 JM2 工作表（已程序化提取，见 docs/09 §3）。
#
# ⚠️ 板上没有 I2S 座，音频模块要用杜邦线接 JM2，所以这里给的是【规划值】，
#    接线时按这个来，不要把线插到别的脚上。
#
# 为什么 BCLK 和 LRCLK 挑时钟脚：
#   J20 是 IO_L11P_SRCC_15、K18 是 IO_L13P_MRCC_15，
#   走全局时钟资源，输入路径的抖动和偏斜更小。
#   不过本工程 **不把 BCLK 当全局时钟用** —— 它是异步输入，
#   由 i2s_slave_clk 在 clk_sys 域过采样出边沿选通。
#   所以这里也【不需要】对 BCLK 建时钟约束。
#
# ⚠️ I2C 必须独立于板载 EEPROM 那组总线（N13/N14），避免地址冲突。
#    这里用 JM2 上的 K21/K22，与 EEPROM 完全无关。
#=============================================================================

#-----------------------------------------------------------------------------
# I2S 接口
#-----------------------------------------------------------------------------
# BCLK：WM8960 输出（3.072 MHz）
set_property -dict {PACKAGE_PIN J20 IOSTANDARD LVCMOS33} [get_ports aud_bclk]

# LRCLK：WM8960 输出（48 kHz）
set_property -dict {PACKAGE_PIN K18 IOSTANDARD LVCMOS33} [get_ports aud_lrclk]

# ADCDAT：WM8960 -> FPGA
set_property -dict {PACKAGE_PIN H20 IOSTANDARD LVCMOS33} [get_ports aud_adcdat]

# DACDAT：FPGA -> WM8960
set_property -dict {PACKAGE_PIN G20 IOSTANDARD LVCMOS33} [get_ports aud_dacdat]

#-----------------------------------------------------------------------------
# I2C 控制
#-----------------------------------------------------------------------------
# 400 kHz 的 I2C 是开漏总线，模块侧通常已有上拉；
# 若没有，需在 SCL/SDA 上各加 4.7k 到 3.3V。
set_property -dict {PACKAGE_PIN K21 IOSTANDARD LVCMOS33} [get_ports aud_scl]
set_property -dict {PACKAGE_PIN K22 IOSTANDARD LVCMOS33} [get_ports aud_sda]

#-----------------------------------------------------------------------------
# 输出驱动强度
#-----------------------------------------------------------------------------
# ⚠️ DRIVE 只能作用于【输出】端口（含 inout 的输出驱动部分）。
#    对纯输入端口设 DRIVE 会触发 [Vivado 12-4702] 警告，且本来就没有意义
#    —— 输入端的信号质量由对方驱动，不关我们的事。
#
# 本设计里 FPGA 是 I2S 【从机】：aud_bclk / aud_lrclk / aud_adcdat 都是输入，
# 只有 aud_dacdat 是输出。所以这里只列输出端口。
#
# 另：LVCMOS33 的默认 DRIVE 本来就是 12 mA，写出来只为意图明确。
#     长线（杜邦线 + 飞线）抗振铃靠 SLEW slow，而不是靠加大驱动电流
#     —— 驱动电流越大，过冲越厉害。
set_property DRIVE 12  [get_ports {aud_dacdat aud_scl aud_sda}]
set_property SLEW  SLOW [get_ports {aud_dacdat aud_scl aud_sda}]
