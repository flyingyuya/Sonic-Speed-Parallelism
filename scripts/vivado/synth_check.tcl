#=============================================================================
# synth_check.tcl - 单模块 OOC 综合检查（不布局布线，秒级）
#-----------------------------------------------------------------------------
# 用途：写完一个模块后快速确认三件事
#   ① 能不能综合过、有没有 DRC / 推断警告
#   ② 资源数字对不对得上设计意图
#      （例：FIFO 该用分布式 RAM 却推成了 4000 个触发器，仿真发现不了）
#   ③ 双时钟模块的跨时钟域路径有没有被正确识别（report_cdc）
#
# 用法：
#   vivado -mode batch -source scripts/vivado/synth_check.tcl -tclargs <top> [wclk_ns] [rclk_ns]
#
# 例：
#   ... -tclargs async_fifo 325.5 20.833     # 3.072MHz 写 / 48MHz 读
#   ... -tclargs fft_core                    # 单时钟模块，不传时钟周期即可
#=============================================================================
# 用法：
#   synth_check.tcl <top>                              只综合，不建时钟
#   synth_check.tcl <top> <port>=<period_ns> [...]     给指定端口建时钟
#
# 例：
#   ... -tclargs fft_core clk=20.833
#   ... -tclargs async_fifo wclk=325.5 rclk=20.833
#   ... -tclargs disp_top clk_sys=20.833 clk_pix=80.0
#
# 为什么不再用"第 2 个参数就是周期"的写法：
#   不同模块的时钟端口名五花八门（clk / Clk / clk_sys / wclk ...），
#   写死端口名会导致 create_clock 静默失败 —— 时钟没建上，
#   于是 report_cdc 一片空白，看上去"没有跨时钟域问题"，实际是根本没检查。
set TOP [lindex $argv 0]

set CLKS {}
foreach a [lrange $argv 1 end] {
    if {[regexp {^([^=]+)=(.+)$} $a -> _pn _pd]} {
        lappend CLKS [list $_pn $_pd]
    } else {
        puts "  警告：忽略无法解析的时钟参数 '$a'（应写成 端口名=周期ns）"
    }
}
set NCLK [llength $CLKS]

set PART "xc7a100tfgg484-2"

set ROOT [file normalize [file join [file dirname [info script]] ../..]]
set OUT  [file join $ROOT build vivado]
file mkdir $OUT

puts "============================================================="
puts " OOC 综合检查"
puts "   top  : $TOP"
puts "   part : $PART"
puts "============================================================="

#---------------------------------------------------------------------------
# 读源文件：rtl 下所有子目录 + rtl 根目录
#---------------------------------------------------------------------------
foreach d [glob -nocomplain -type d [file join $ROOT rtl *]] {
    set fs [glob -nocomplain [file join $d *.v]]
    if {[llength $fs]} { read_verilog $fs }
}
set fs [glob -nocomplain [file join $ROOT rtl *.v]]
if {[llength $fs]} { read_verilog $fs }

#---------------------------------------------------------------------------
# 头文件搜索路径
#   ui_ctrl.v 会 `include "disp_cfg.vh"`（rtl/video 下）。
#   不设这个，synth_design 会报 [Synth 8-1766] cannot open include file，
#   而且报出来的位置是 include 的那一行 —— 看上去像文件缺失，
#   实际只是搜索路径没配。
#---------------------------------------------------------------------------
set_property include_dirs [list [file join $ROOT rtl video] \
                                [file join $ROOT rtl common]] [current_fileset]

#---------------------------------------------------------------------------
# 双时钟模块：先写一个临时 XDC 建两个时钟，report_cdc 才有的可分析
#   注意：create_clock 必须在 synth_design【之前】通过 read_xdc 读进来，
#         直接在设计未打开时执行 create_clock 会报 "No open design"。
#---------------------------------------------------------------------------
set XDC [file join $OUT "${TOP}_check.xdc"]
set fx [open $XDC w]
puts $fx "# 由 synth_check.tcl 自动生成"
foreach c $CLKS {
    lassign $c _pn _pd
    puts $fx "create_clock -period $_pd -name $_pn \[get_ports $_pn\]"
}
if {$NCLK > 1} {
    set _grp ""
    foreach c $CLKS {
        lassign $c _pn _pd
        append _grp " -group \[get_clocks $_pn\]"
    }
    puts $fx "set_clock_groups -asynchronous$_grp"
}
close $fx
read_xdc $XDC
foreach c $CLKS {
    lassign $c _pn _pd
    puts "   已建时钟 $_pn = $_pd ns"
}
if {$NCLK > 1} { puts "   （已声明为互为异步时钟组）" }

#---------------------------------------------------------------------------
# 综合
#---------------------------------------------------------------------------
synth_design -top $TOP -part $PART -flatten_hierarchy none

report_utilization    -file [file join $OUT "${TOP}_util.rpt"]

# DRC 豁免：单模块 OOC 检查同样会命中 DSP 流水建议，理由与整机一致。
# （豁免项在报告里显示为 "Violations waived"，不静默消失）
set _waiver_tcl [file join [file dirname [info script]] drc_waivers.tcl]
if {[file exists $_waiver_tcl]} { source $_waiver_tcl }

# 单模块 OOC 检查【天然】拿不到管脚约束：
#   - 模块的端口是内部接口，不对应任何物理管脚；
#   - CFGBVS / CONFIG_VOLTAGE 是比特流阶段的配置属性，与模块无关；
#   - IOCNT-1 会把【内部宽总线】当成顶层 IO 算：disp_top 只有 16 个端口，
#     但 spec_din 是 60 根柱 x HW 位的扁平总线（600 位），
#     于是总端口数达到 612，超过器件可用的 285 个引脚。
#     整机里这条总线是模块间连线，根本不占引脚。
# 所以这四条在这里【前提不成立】（属于「环境/流程信息」类）。
# 整机 build.tcl 里 NSTD-1/UCIO-1 被真实 LOC 约束消掉，
# CFGBVS-1 被 constrs 里的配置属性消掉，IOCNT-1 根本不会出现，
# 因此【只在 OOC 流程里豁免】。
foreach _r {NSTD-1 UCIO-1 CFGBVS-1 IOCNT-1} {
    if {[llength [get_drc_checks -quiet $_r]]} {
        create_waiver -type DRC -id $_r \
            -description "单模块 OOC 检查无管脚/配置约束，该规则前提不成立"
    }
}

report_drc            -file [file join $OUT "${TOP}_drc.rpt"]
if {$NCLK > 1} {
    report_cdc        -file [file join $OUT "${TOP}_cdc.rpt"]
}

#---------------------------------------------------------------------------
# 控制台摘要：只打印我们关心的几行
#---------------------------------------------------------------------------
puts ""
puts "----------------- 资源摘要 -----------------"
set rpt [file join $OUT "${TOP}_util.rpt"]
if {[file exists $rpt]} {
    set want {Slice LUTs} 
    set fh [open $rpt r]
    while {[gets $fh line] >= 0} {
        # 报告里每条形如：  | Slice LUTs*  |  54 |  0 | 63400 | 0.09 |
        if {[regexp {\|\s*(Slice LUTs\*?|LUT as Logic|LUT as Memory|LUT as Distributed RAM|Slice Registers|Register as Flip Flop|Register as Latch|RAMB36E1|RAMB18E1|DSP48E1|Bonded IOB)\s*\|\s*([0-9]+)} $line -> nm val]} {
            puts [format "  %-26s %s" [string trim $nm] $val]
        }
    }
    close $fh
}

puts ""
puts "----------------- DRC -----------------"
set drc [file join $OUT "${TOP}_drc.rpt"]
if {[file exists $drc]} {
    set fh [open $drc r]
    set txt [read $fh]
    close $fh
    if {[regexp {Violations found: (\d+)} $txt -> nv]} {
        puts "  违规数：$nv"
    } else {
        puts "  违规数：0"
    }
}

if {$NCLK > 1 && [file exists [file join $OUT "${TOP}_cdc.rpt"]]} {
    puts ""
    puts "----------------- CDC 跨时钟域 -----------------"
    puts "  详见 build/vivado/${TOP}_cdc.rpt"
}

puts ""
puts "============================================================="
puts " 报告目录：build/vivado/"
puts "============================================================="
