#=============================================================================
# build.tcl - Vivado 非工程模式批处理流程（纯 CLI，不依赖 GUI）
#-----------------------------------------------------------------------------
# 用法：
#   vivado -mode batch -source scripts/vivado/build.tcl -tclargs <PART> [TOP] [XDC]
#
# 例：
#   vivado -mode batch -source scripts/vivado/build.tcl \
#          -tclargs xc7a100tfgg484-2 audio_top constrs/audio_top.xdc
#
# 产物（build/vivado/ 下）：
#   post_synth_util.rpt    综合资源占用
#   post_route_timing.rpt  布线后时序
#   post_route_util.rpt    实现后资源占用
#   post_route_drc.rpt     设计规则检查
#   <TOP>.bit              比特流
#   <TOP>.dcp              布线后设计检查点（可 reopen 做 ILA 调试）
#
# 说明：使用 -flatten_hierarchy none 保留层次名，方便用 ILA 抓内部信号、
#       也方便 read_checkpoint 后做增量实现。
#=============================================================================

set PART  [expr {$argc > 0 ? [lindex $argv 0] : "xc7a100tfgg484-2"}]
set TOP   [expr {$argc > 1 ? [lindex $argv 1] : "audio_top"}]
set XDC   [expr {$argc > 2 ? [lindex $argv 2] : ""}]

#=============================================================================
# BUILD_MODE —— 构建到哪一步就停（用环境变量选，默认 full）
#-----------------------------------------------------------------------------
#   【为什么要这个开关】
#     完整 synth+impl+route+bitstream 要 9~10 分钟。但日常改 RTL 时：
#       · 只想确认"语法/综合有没有问题"      ⟹ synth 就够（约 2~3 分钟）
#       · 想知道"资源涨了没、时序过不过"      ⟹ impl 就够（约 7~8 分钟）
#       · 要上板                              ⟹ 必须 full
#     ⟹ 用 SYNTH_ONLY=1 / IMPL_ONLY=1 环境变量选择，不用改脚本。
#
#   用法：
#     SYNTH_ONLY=1 vivado -mode batch -source scripts/vivado/build.tcl ...
#     IMPL_ONLY=1  vivado -mode batch -source scripts/vivado/build.tcl ...
#     （什么都不设 = full，出比特流）
#=============================================================================
if {[info exists ::env(SYNTH_ONLY)]} {
    set BUILD_MODE "synth"
} elseif {[info exists ::env(IMPL_ONLY)]} {
    set BUILD_MODE "impl"
} else {
    set BUILD_MODE "full"
}
puts "\n========== BUILD_MODE = $BUILD_MODE ==========\n" 

set ROOT  [file normalize [file join [file dirname [info script]] ../..]]
set OUT   [file join $ROOT build vivado]
file mkdir $OUT

puts "============================================================="
puts " Sonic-Speed-Parallelism  Vivado 批处理构建"
puts "   器件 : $PART"
puts "   顶层 : $TOP"
puts "   约束 : [expr {$XDC eq "" ? "(无)" : $XDC}]"
puts "   输出 : $OUT"
puts "============================================================="

# ---------------------------------------------------------------------------
# 读入源文件
# ---------------------------------------------------------------------------
# 顶层文件（rtl/*.v，如 top.v）
set rootfiles [glob -nocomplain [file join $ROOT rtl *.v]]
if {[llength $rootfiles] > 0} {
    puts "  读入 rtl/       : [llength $rootfiles] 个文件"
    read_verilog $rootfiles
}
# 各子目录（自动扫描，新增模块目录不用再改脚本）
foreach d [lsort [glob -nocomplain -type d [file join $ROOT rtl *]]] {
    set files [lsort [glob -nocomplain [file join $d *.v]]]
    if {[llength $files] > 0} {
        puts "  读入 rtl/[file tail $d]: [llength $files] 个文件"
        read_verilog $files
    }
}

# 约束文件：支持三种形式
#   <空>        不读约束（只做逻辑综合验证）
#   目录        读入目录下所有 .xdc（本工程用这个：-tclargs ... constrs）
#   文件        只读这一个
if {$XDC ne ""} {
    set _xdcpath [file join $ROOT $XDC]
    if {[file isdirectory $_xdcpath]} {
        set _files [lsort [glob -nocomplain [file join $_xdcpath *.xdc]]]
        foreach f $_files {
            puts "  读入约束: [file tail $f]"
            read_xdc $f
        }
    } elseif {[file exists $_xdcpath]} {
        puts "  读入约束: [file tail $_xdcpath]"
        read_xdc $_xdcpath
    } else {
        puts "  警告：找不到约束 '$XDC'"
    }
} else {
    puts "  警告：未提供约束文件，只做逻辑综合验证（时序不完整）"
}

# ---------------------------------------------------------------------------
# 综合
# ---------------------------------------------------------------------------
# 头文件搜索路径（rtl/video/disp_cfg.vh 等）
set_property include_dirs [list [file join $ROOT rtl video] [file join $ROOT rtl common] [file join $ROOT rtl wm8960]] [current_fileset]

#-----------------------------------------------------------------------------
# 综合警告抑制：Synth 8-7129（Port ... has no load）
#
# 【为什么可以抑制 —— 逐条判据】
#   8-7129 的含义是"这个端口/它的某些位没有负载"。本工程触发它的情形全部是：
#
#   ① 参数化模块的【高位地址】超出实际使用范围
#        bg_src.x[9:5]  —— 网格只需 x[4:0]（GRID=32），渐变只用 y
#        bg_src.y[9]    —— 360 行只需 y[8:0]
#        text_buf.waddr[9:8]、wave_buf.x[9] —— 地址空间开得比用的大
#      ⟹ 端口位宽是按"最大分辨率"预留的，小分辨率下高位天然无负载。
#        **这是参数化的正常副产品，不是缺陷。**
#
#   ② 配置信号的未使用位
#        cmd_proc.cfg_auto[0] —— 该功能位当前未接
#      ⟹ 预留位，功能和寄存器定义其它位一致。
#
#   ⚠️ 前提若变化（例如以后让 bg_src 用上 x[9:5] 做归一化），
#      这条抑制会【同时掩盖】真正的"接了线但没人用"的 bug。
#      ⟹ 届时请删除本抑制，重新检查。
#
#   对比：REQP-1839（BRAM 控制脚带异步复位）是【真缺陷】，
#        已在 sd_img_load 里改设计修掉（wr2_en/wr2_addr 移出异步复位块），
#        没有豁免。
#-----------------------------------------------------------------------------
#   ⚠️ -suppress 和 -limit 互斥，不能同时给
set_msg_config -id {Synth 8-7129} -suppress

#-----------------------------------------------------------------------------
# Route 35-328 "Router estimated timing not met" —— 保守估计的假报警
#
# 【判据】这条是布线器的【估计】值。本工程 route_design 完成后，
#   post_route_timing.rpt 里所有时钟组的 WNS 全部为正：
#       clk_sys   +1.779 ns
#       clk_hdmi  +4.028 ns
#       clk_pix   （远大于 0）
#   ⟹ 实际时序满足 ⟹ 该估计未命中不影响正确性。
#
# 【怎么自动复核】不要只看这条警告，直接看报告：
#       grep -A5 "^Clock.*WNS" build/vivado/post_route_timing.rpt
#   若出现负 WNS ⟹ 删掉这条抑制，那条才是真问题。
#-----------------------------------------------------------------------------
set_msg_config -id {Route 35-328} -suppress

synth_design -top $TOP -part $PART -flatten_hierarchy none
write_checkpoint -force [file join $OUT post_synth.dcp]
report_utilization    -file [file join $OUT post_synth_util.rpt]
report_timing_summary -file [file join $OUT post_synth_timing.rpt] \
                      -delay_type max -max_paths 10

# ---------------------------------------------------------------------------
# 实现
# ---------------------------------------------------------------------------
# --- synth 模式在这里收工 ---
if {$BUILD_MODE eq "synth"} {
    puts "\n========== BUILD_MODE=synth：只做到综合，跳过实现 ==========\n"
    report_utilization -file [file join $OUT "post_synth_util.rpt"]
    close_project
    exit 0
}

opt_design
place_design
phys_opt_design
# 【暂不加 -timing_summary】
#   它能让 route_design 做完整签核、消除 "Router estimated timing not met" 警告，
#   但同时会把 spec_sync/wave_buf 那些【设计上异步】的跨域路径判成 CRITICAL
#   （因为缺一条 set_clock_groups 约束 —— 见 constrs/clocks.xdc 的待办段）。
#   等把那条约束补对了再打开。现在用默认流程：它对这个设计给出的最终
#   post_route_timing 报告里，所有时钟的 WNS 都是正的。
route_design

write_checkpoint -force [file join $OUT post_route.dcp]
report_utilization    -file [file join $OUT post_route_util.rpt]
report_timing_summary -file [file join $OUT post_route_timing.rpt] \
                      -delay_type max -max_paths 20 -report_unconstrained

# ---------------------------------------------------------------------------
# DRC 豁免（有据可依，不是藏警告）
# ---------------------------------------------------------------------------
# 豁免项以 "Waived" 形式出现在报告里，不是消失。理由写在文件头部。
set _waiver_tcl [file join [file dirname [info script]] drc_waivers.tcl]
if {[file exists $_waiver_tcl]} {
    puts "-- 应用 DRC 豁免：$_waiver_tcl"
    source $_waiver_tcl
} else {
    puts "-- 未找到 drc_waivers.tcl，跳过"
}

report_drc            -file [file join $OUT post_route_drc.rpt]
report_clock_utilization -file [file join $OUT clock_util.rpt]

# ---------------------------------------------------------------------------
# 比特流
# ---------------------------------------------------------------------------
# 若还没填管脚 LOC 约束，把"未约束 IO"的 DRC 降为 Warning，
# 让流程能跑完（用于评估时序与资源）。补齐管脚后这两行自动不生效。
set _has_loc 0
foreach _p [get_ports] {
    if {[get_property -quiet LOC $_p] ne ""} { set _has_loc 1; break }
}
if {!$_has_loc} {
    puts "  警告：未检测到管脚 LOC 约束 -> NSTD-1/UCIO-1 降为 Warning"
    puts "        此比特流仅用于时序/资源评估，**不能上板**"
    set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
    set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
}

# --- impl 模式在这里收工（不做比特流）---
if {$BUILD_MODE eq "impl"} {
    puts "\n========== BUILD_MODE=impl：只到实现+布线，跳过比特流 ==========\n"
    close_project
    exit 0
}

# ---------------------------------------------------------------------------
# QSPI Flash 自启动所需的比特流配置
#   板上 Flash 是 W25Q128JVSQ，按【4 线 QSPI】连接。
#   不加这两行的话，比特流里默认按 x1 配置 ⟹ 烧进 Flash 后上电起不来。
#   （write_bitstream 之前设置才会写进比特流头部）
# ---------------------------------------------------------------------------
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH  4        [current_design]
set_property BITSTREAM.CONFIG.SPI_FALL_EDGE YES      [current_design]
set_property BITSTREAM.CONFIG.CONFIGRATE    33       [current_design]
set_property BITSTREAM.CONFIG.SPI_32BIT_ADDR NO      [current_design]

write_bitstream -force [file join $OUT "${TOP}.bit"]

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
set wns  [get_property SLACK [get_timing_paths -delay_type max]]
set whs  [get_property SLACK [get_timing_paths -delay_type min]]
puts "============================================================="
puts " 构建完成"
puts "   WNS (建立时间裕量) = $wns ns"
puts "   WHS (保持时间裕量) = $whs ns"
puts "   比特流 : [file join $OUT ${TOP}.bit]"
puts "============================================================="
