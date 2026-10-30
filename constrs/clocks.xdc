#=============================================================================
# clocks.xdc - 时钟命名与跨时钟域声明
#-----------------------------------------------------------------------------
# 【本文件的三个作用】
#   1. 用 MMCM 输出引脚显式命名时钟，不再依赖自动推导的网名
#   2. 声明 clk_sys 与 clk_pix 互为异步（本工程所有跨域都走格雷码异步 FIFO）
#   3. 把 LCD 输出时钟建模成 clk_pix 的【转发时钟】，而不是另一个独立时钟
#
#=============================================================================

#-----------------------------------------------------------------------------
# 显式命名 MMCM 输出的两个时钟（以 BUFG 输出为基准点）
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
# 跨时钟域声明
#-----------------------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks clk_sys] \
    -group [get_clocks clk_pix]

#-----------------------------------------------------------------------------
# LCD 像素时钟：clk_pix 的转发时钟
#-----------------------------------------------------------------------------
create_generated_clock -name clk_pix_fwd \
    -source  [get_pins u_clkgen/u_bufg_pix/O] \
    -divide_by 1 \
    [get_ports lcd_clk]

set_output_delay -clock clk_pix_fwd -max  2.000 \
    [get_ports {lcd_rgb[*] lcd_hs lcd_vs}]
set_output_delay -clock clk_pix_fwd -min -1.000 \
    [get_ports {lcd_rgb[*] lcd_hs lcd_vs}]

#-----------------------------------------------------------------------------
# BCLK 异步时钟
#-----------------------------------------------------------------------------
create_clock -name clk_bclk -period 325.520 [get_ports aud_bclk]

set_clock_groups -asynchronous \
    -group [get_clocks clk_bclk] \
    -group [get_clocks clk_sys] \
    -group [get_clocks clk_pix]

#=============================================================================
# HDMI 域的跨时钟域声明（2026-10-26 补）
#=============================================================================
#   背景：clk_hdmi 由【MMCM2】产生，与 clk_sys/clk_pix（MMCM1）完全无关。
#         但如果不声明，Vivado 会按"同步关系"去算两个域之间的路径 ——
#         实测报 clk_sys→clk_hdmi_raw WNS = -2.364 ns / 767 个失败端点
#         （clk_hdmi_raw→clk_sys 另有 4 个）。
#         这些"违例"全是假的：跨域全部由 async_fifo / cdc_sync 承担。
#
#   ⚠️ clk_hdmi 与 clk_5x 由【同一个 MMCM2】产生（VCO = 1000 MHz）：
#      clk_hdmi = 1000 / 40 = 25 MHz
#      clk_5x   = 1000 /  8 = 125 MHz
#      ⟹ 二者必须留在【同一组】，不能分开声明。
#      （Vivado 会自动推导它们之间的同步关系，不需要额外 create_clock）
#
#   跨域方式核对（全部真异步）：
#     · 柱高 spec_din  ⟹ spec_sync 内部 async_fifo（格雷码）
#     · 波形 wave_din  ⟹ wave_buf 内部 toggle 握手
#     · 配置 ui_*      ⟹ cdc_sync 双打
#     · 帧缓冲读口     ⟹ BRAM 双时钟（写 clk_sys / 读 clk_hdmi）
#=============================================================================
#   先给 HDMI 域两个时钟显式命名（MMCM2 输出 → BUFG 输出点）
#   ⚠️ 不显式命名时 Vivado 自动推导出来的名字是 clk_hdmi_raw / clk_5x_raw，
#      在 set_clock_groups 里写 clk_hdmi 会报
#      "No clocks matched 'clk_hdmi'" ⟹ 约束静默失效！
create_generated_clock -name clk_hdmi_pix \
    -source [get_pins u_clkgen/u_mmcm_hdmi/CLKOUT0] \
    -divide_by 1 \
    [get_pins u_clkgen/u_bufg_hdmi/O]

create_generated_clock -name clk_hdmi_5x \
    -source [get_pins u_clkgen/u_mmcm_hdmi/CLKOUT1] \
    -divide_by 1 \
    [get_pins u_clkgen/u_bufg_5x/O]

set_clock_groups -asynchronous \
    -group [get_clocks clk_sys] \
    -group [get_clocks clk_pix] \
    -group [get_clocks clk_hdmi_pix] \
    -group [get_clocks clk_bclk]

#=============================================================================
# 【历史记录】上面这条约束在 2026-10 之前一直缺失
#=============================================================================
#   症状：GUI 里打开 timing summary 能看到 clk_sys→clk_hdmi_raw 一片红，
#         但默认的 report_timing_summary 只在"每时钟域内部"那几行显示正 WNS，
#         很容易误判成"时序收敛"。
#
#   ⚠️ 教训：核对时序不能只看按时钟分组的 WNS 表，
#      必须看【时钟对（inter-clock）】那一段：
#         grep -A30 "Inter Clock Table" build/vivado/post_route_timing.rpt
#      或者直接看 "Timing Summary" 里 TNS Failing Endpoints 的【总和】。
#=============================================================================
