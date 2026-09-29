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
set_property include_dirs [list [file join $ROOT rtl video] [file join $ROOT rtl common]] [current_fileset]

synth_design -top $TOP -part $PART -flatten_hierarchy none
write_checkpoint -force [file join $OUT post_synth.dcp]
report_utilization    -file [file join $OUT post_synth_util.rpt]
report_timing_summary -file [file join $OUT post_synth_timing.rpt] \
                      -delay_type max -max_paths 10

# ---------------------------------------------------------------------------
# 实现
# ---------------------------------------------------------------------------
opt_design
place_design
phys_opt_design
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
