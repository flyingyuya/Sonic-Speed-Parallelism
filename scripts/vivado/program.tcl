#=============================================================================
# program.tcl - 把比特流下载到 FPGA
#-----------------------------------------------------------------------------
# 用法：
#   # ① 只探测（先确认认到了器件，不烧）
#   vivado -mode batch -source scripts/vivado/program.tcl -tclargs detect
#
#   # ② 烧板（默认用 build/vivado/top.bit）
#   vivado -mode batch -source scripts/vivado/program.tcl
#
#   # ③ 烧指定文件
#   vivado -mode batch -source scripts/vivado/program.tcl -tclargs program path/to/x.bit
#
# 说明：
#   - 这是【易失】下载（写进 FPGA 的 SRAM 配置），掉电即失。
#     要掉电保持得烧 QSPI Flash（write_cfgmem + program_hw_cfgmem），
#     本脚本不做 —— bring-up 阶段反复改设计，烧 Flash 反而慢。
#   - 板载 USB 转 JTAG，一根 TypeC 线同时供电和调试。
#   - 若报 "no targets"，先查：板子供电了吗？线插的是 JTAG 口吗？
#     Linux 下还需要 udev 规则让普通用户能访问（否则要 sudo）。
#=============================================================================

set ROOT [file normalize [file join [file dirname [info script]] ../..]]
set OUT  [file join $ROOT build vivado]

set MODE "program"
set BIT  [file join $OUT top.bit]

if {$argc > 0} {
    set a0 [lindex $argv 0]
    if {$a0 eq "detect"} {
        set MODE "detect"
    } elseif {$a0 eq "program"} {
        set MODE "program"
        if {$argc > 1} { set BIT [lindex $argv 1] }
    } else {
        set BIT $a0
    }
}

puts "============================================================="
puts " 模式   : $MODE"
if {$MODE eq "program"} { puts " 比特流 : $BIT" }
puts "============================================================="

# ---------------------------------------------------------------------------
# 1. 连接硬件服务器
# ---------------------------------------------------------------------------
open_hw_manager
if {[catch {connect_hw_server} err]} {
    puts "❌ 连接 hw_server 失败：$err"
    puts "   Vivado 正常会自动拉起 hw_server；若不行，手动跑："
    puts "     ~/Xilinx/Vivado/2020.2/bin/hw_server"
    exit 1
}

set _targets [get_hw_targets -quiet]
if {[llength $_targets] == 0} {
    puts ""
    puts "❌ 没有发现 JTAG 目标。逐项排查："
    puts "   1) 板子上电了吗？（TypeC 线插对了吗）"
    puts "   2) 线是插在【JTAG】口而不是 UART 口吗？"
    puts "   3) Linux 权限：普通用户访问 USB 需要 udev 规则。临时验证可以："
    puts "        sudo $(file join $::env(HOME) Xilinx Vivado 2020.2 bin hw_server) &"
    puts "      或直接 sudo 跑本脚本。"
    puts ""
    puts "   当前 lsusb 里应能看到 Xilinx/Digilent/FTDI 设备："
    catch {exec lsusb | grep -iE "xilinx|digilent|ftdi|0403|03fd"} _ls
    if {[info exists _ls] && $_ls ne ""} { puts "     $_ls" } \
    else { puts "     （未发现 —— 说明线没插好或板子没上电）" }
    close_hw_manager
    exit 1
}

puts "  发现 JTAG 目标：$_targets"
open_hw_target

# ---------------------------------------------------------------------------
# 2. 认器件
# ---------------------------------------------------------------------------
set _devs [get_hw_devices -quiet]
if {[llength $_devs] == 0} {
    puts "❌ 打开了目标但没认到器件。检查 JTAG 链路（可能还有别的器件在链上）。"
    close_hw_manager
    exit 1
}

set DEV [lindex $_devs 0]
current_hw_device $DEV
refresh_hw_device $DEV

set idcode [get_property IDCODE $DEV]
set part   [get_property PART $DEV]
puts ""
puts "  JTAG 链上器件："
foreach d $_devs {
    puts [format "    %-24s IDCODE=0x%08X  PART=%s" $d \
              [get_property IDCODE $d] [get_property PART $d]]
}

# 目标器件：本工程用 xc7a100t
if {[string match -nocase "*xc7a100t*" $part]} {
    puts ""
    puts "  ✅ 认到目标器件 xc7a100t ✓"
} else {
    puts ""
    puts "  ⚠️  链上第一个器件是 $part，不是 xc7a100t。"
    puts "     如果链上有多个器件，请确认要烧哪个再手动指定。"
}

# ---------------------------------------------------------------------------
# 3. 探测模式到此为止
# ---------------------------------------------------------------------------
if {$MODE eq "detect"} {
    puts ""
    puts "============================================================="
    puts " 探测完成（未烧写）。"
    puts " 确认无误后执行："
    puts "   vivado -mode batch -source scripts/vivado/program.tcl"
    puts "============================================================="
    close_hw_manager
    exit 0
}

# ---------------------------------------------------------------------------
# 4. 烧写
# ---------------------------------------------------------------------------
if {![file exists $BIT]} {
    puts "❌ 比特流不存在：$BIT"
    puts "   先构建： vivado -mode batch -source scripts/vivado/build.tcl \\"
    puts "              -tclargs xc7a100tfgg484-2 top $ROOT/constrs"
    close_hw_manager
    exit 1
}

puts ""
puts "  正在下载 [file tail $BIT]（[expr {[file size $BIT]/1024}] KB）..."

set_property PROGRAM.FILE $BIT $DEV
if {[catch {program_hw_devices $DEV} err]} {
    puts "❌ 下载失败：$err"
    close_hw_manager
    exit 1
}
puts "  ✅ 下载完成"

# ---------------------------------------------------------------------------
# 5. 烧完的即时读数：DONE 脚、是否进过复位
# ---------------------------------------------------------------------------
after 1000
refresh_hw_device $DEV
puts ""
puts "  器件状态："
foreach p {DONE INITIALISED} {
    if {[llength [get_property -quiet $p $DEV]] || 1} {
        catch {puts [format "    %-14s = %s" $p [get_property $p $DEV]]}
    }
}

puts ""
puts "============================================================="
puts " 烧写完成。现在看板子："
puts "   led[1] 闪烁 (~2.9 Hz)  → FPGA 活着，时钟/复位正常  ✅ 必须看到"
puts "   led[0] 常亮            → WM8960 I2C 配置完成"
puts "                            【没插音频模块时不亮是正常的】"
puts "   LCD                    → 网格背景（不依赖音频）"
puts "   UART 115200            → 上电 50 ms 后打横幅"
puts "============================================================="
close_hw_manager
