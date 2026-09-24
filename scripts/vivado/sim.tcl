#=============================================================================
# sim.tcl - Vivado xsim 仿真流程（CI / 无 GUI 环境用）
#-----------------------------------------------------------------------------
# 用法：
#   vivado -mode batch -source scripts/vivado/sim.tcl -tclargs <TB_TOP> [runtime_ns]
#
# 例：
#   vivado -mode batch -source scripts/vivado/sim.tcl -tclargs tb_audio_top
#
# 注意：日常迭代请优先用 scripts/sim/run_iv.sh（iverilog，秒级），
#       xsim 只用来做"签核级"复现（工具链与综合器一致）。
#=============================================================================

set TBTOP [expr {$argc > 0 ? [lindex $argv 0] : "tb_audio_top"}]
set RUNTIME [expr {$argc > 1 ? [lindex $argv 1] : "5000000"}]

set ROOT [file normalize [file join [file dirname [info script]] ../..]]
set OUT  [file join $ROOT build xsim]
file mkdir $OUT

puts "xsim 仿真: $TBTOP (run ${RUNTIME} ns)"

foreach d {common audio video} {
    set files [glob -nocomplain [file join $ROOT rtl $d *.v]]
    if {[llength $files] > 0} { read_verilog $files }
}

read_verilog [file join $ROOT sim tb codec_model.v]
read_verilog [file join $ROOT sim tb "${TBTOP}.v"]

set_property file_type {Verilog} [get_files *.v] -quiet

synth_design -top $TBTOP -part xc7a100tfgg484-2 -mode out_of_context

launch_simulation
run $RUNTIME ns
quit
