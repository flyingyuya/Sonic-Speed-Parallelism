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
# 【待办】HDMI 域与 clk_sys 的异步约束
#=============================================================================
#   现状：spec_sync 的 async_fifo、wave_buf 的 done_tog/rd_tog 是【设计上异步】
#         的跨域路径。默认流程能容忍（26 条 Slack VIOLATED 不报错），
#         但加了 route_design -timing_summary 就会报 CRITICAL。
#=============================================================================
