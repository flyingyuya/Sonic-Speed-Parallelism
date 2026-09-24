# Vivado batch 模式命令速查

## 一、启动方式

| 命令 | 说明 |
| --- | --- |
| `vivado -mode gui` | 图形界面 |
| `vivado -mode tcl` | 图形界面 + Tcl 控制台 |
| `vivado -mode batch -source x.tcl` | **纯 Tcl 引擎，无窗口** |

**GUI 里点的每个按钮，底层就是一条 Tcl 命令。** 反之不成立。

```bash
# 脚本化调用（-tclargs 后的参数由脚本里的 $argv 接住）
vivado -mode batch -nojournal -log my.log \
       -source scripts/vivado/build.tcl \
       -tclargs <PART> <TOP> <XDC>

# 内联脚本（临时分析用）
vivado -mode batch -source /dev/stdin <<'EOF'
open_checkpoint build/vivado/post_route.dcp
report_timing_summary
EOF
```

## 二、非工程模式构建流程

```tcl
# ---- 1. 读入源文件 ----
foreach d {common audio video} {
    set files [glob -nocomplain rtl/$d/*.v]
    if {[llength $files] > 0} { read_verilog $files }
}
read_xdc constrs/top.xdc
# IP 的话还需要：
# read_ip  ip/xxx.xci
# generate_target all [get_ips xxx]

# ---- 2. 综合 ----
synth_design -top TOP -part PART -flatten_hierarchy none
write_checkpoint -force build/post_synth.dcp

# ---- 3. 实现 ----
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force build/post_route.dcp

# ---- 4. 比特流 ----
write_bitstream -force build/TOP.bit
```

### 为什么加 `-flatten_hierarchy none`

保留层次名 → 可以 `read_checkpoint` 后用 ILA 抓**内部信号**、
可以做增量实现、报告里的 `Source`/`Destination` 也是可读的层次路径。
默认的 `rebuilt` 会把层次压掉，调试时找不到信号。

### 为什么用 `write_checkpoint`

`.dcp` 是二进制快照，重新打开只需几秒，
而重跑综合要几分钟。**改约束、挖时序、配 ILA 都应该从 dcp 开始。**

## 三、报告命令

```tcl
report_utilization         -file util.rpt
report_timing_summary      -file timing.rpt -delay_type max -max_paths 20 \
                           -report_unconstrained
report_drc                 -file drc.rpt
report_clock_utilization   -file clock_util.rpt
report_cdc                 -file cdc.rpt          # 跨时钟域检查
report_high_fanout_nets    -file fanout.rpt
```

### 常用信息抽取

```tcl
# 关键时刻（Tcl 直接取值，比翻报告快）
set wns [get_property SLACK [get_timing_paths -delay_type max]]
set whs [get_property SLACK [get_timing_paths -delay_type min]]
puts "WNS=$wns  WHS=$whs"
```

```bash
# shell 里挖报告
grep -E "^\| (Slice LUTs|Slice Registers|DSPs|Block RAM Tile) " util.rpt
sed -n '/WNS(ns)/,+2p' timing.rpt | tail -1
grep -c LUTLP drc.rpt          # 组合环数量，必须 0
```

## 四、报告解读

### `post_route_util.rpt`

| 行 | 含义 | 怎么用 |
| --- | --- | --- |
| `Slice LUTs` | 组合逻辑 | 与手算规模量级对比 |
| `Slice Registers` | 触发器 | 突然暴涨多半是复位策略或变量索引问题 |
| `DSPs` | DSP48E1 | **必须能用手算解释**（乘法器个数） |
| `Block RAM Tile` | BRAM36 当量 | 0 说明全用了分布式 RAM/寄存器 |

**"数字对得上设计意图"是重要的正确性信号。**
例：时分复用的 5 段双二阶 × 2 声道 = 10 个 DSP，报告出 10 → 结构成立。
如果出了 50，说明综合器把时分复用展开成了并行。

### `post_route_timing.rpt`

看 `Slack (VIOLATED)` 段的四个字段：

```
Source      : 起点（哪个寄存器）
Destination : 终点
Data Path   : x ns (logic a%  route b%)
Logic Levels: 23 (CARRY4=15 DSP48E1=2 LUT6=2 ...)
```

- **route 占比 > 50%** → 布局拥挤，考虑时序约束放松、加流水、或调整位置约束
- **CARRY4 很多** → 宽加法器链（如定点舍入/饱和），是流水线的候选点
- **DSP48E1 串联** → 两级乘法首尾相接，是常见的关键路径来源

### `post_route_drc.rpt`

| 检查 | 含义 | 处理 |
| --- | --- | --- |
| `LUTLP-1` | **组合环** | **必须修**，是真实竞争条件 |
| `NSTD-1` / `UCIO-1` | 未约束 IO | 补管脚约束，或开发期临时降级 |
| `DPOR-1` | DSP 相邻寄存器异步复位 | 只影响 QoR（DSP 内部寄存器无法吸收） |
| `DPIP-1` | DSP 输入未流水 | 只影响 Fmax |
| `CFGBVS-1` | 未设配置 bank 电压 | 补 `set_property CFGBVS/CONFIG_VOLTAGE` |

**组合环为什么会逃过仿真：** 组合环在事件驱动仿真里会迭代求值直到稳定。
如果环路恰好能收敛，iverilog 不报错、testbench 也全过，
但硬件上是个 race。**这就是必须跑综合 DRC 的原因。**

典型组合环（真实案例）：

```verilog
// ✗ 有环：wptr_nxt → full → do_wr → wptr_nxt
wire do_wr    = wr_en && !full;
wire [AW:0] wptr_nxt = do_wr ? wptr + 1 : wptr;
assign full = (wptr_nxt[AW] != rptr[AW]) && (wptr_nxt[AW-1:0] == rptr[AW-1:0]);

// ✓ 无环：full 只由已寄存的指针译码
assign full  = (wptr[AW] != rptr[AW]) && (wptr[AW-1:0] == rptr[AW-1:0]);
wire do_wr = wr_en && !full;
// ...
if (do_wr) wptr <= wptr + 1'b1;
```

## 五、约束文件模板

```tcl
# ---- 器件配置（不写会导致 write_bitstream 失败）----
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]

# ---- 时钟 ----
create_clock -period 5.000 -name clk_200m [get_ports clk_200m_p]   # 差分只约束 P 端
# MMCM 输出的自动派生时钟不用手写

# ---- IO 时序（相对外部器件）----
set_input_delay  -clock <clk> -max 5.0 [get_ports <in>]
set_output_delay -clock <clk> -max 5.0 [get_ports <out>]

# ---- 慢速静态控制信号 ----
set_false_path -from [get_ports {cfg_* mode[*]}]

# ---- 时钟不确定性 ----
set_clock_uncertainty -setup 0.200 [get_clocks <clk>]
set_clock_uncertainty -hold  0.100 [get_clocks <clk>]

# ---- 管脚 ----
# set_property -dict {PACKAGE_PIN R4 IOSTANDARD LVDS} [get_ports clk_200m_p]
```

### 过约束技巧

**真实频率太低时（如 12 MHz），时序报告全是正裕量，看不出优化空间也定位不到关键路径。**

做法：**按目标频率的若干倍约束**。例：真实 12.288 MHz（周期 81.4 ns），
按 100 MHz（周期 10 ns）约束，WNS = −6.2 ns 直接告诉你路径有 16.2 ns，
即 Fmax ≈ 61.6 MHz，对 12.288 MHz 有 5 倍余量。

### 开发期临时降级未约束 IO

```tcl
# 仅在有管脚约束后自动失效的写法
set _has_loc 0
foreach _p [get_ports] {
    if {[get_property -quiet LOC $_p] ne ""} { set _has_loc 1; break }
}
if {!$_has_loc} {
    puts "警告：无管脚 LOC 约束 -> NSTD-1/UCIO-1 降为 Warning，此比特流不可上板"
    set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
    set_property SEVERITY {Warning} [get_drc_checks UCIO-1]
}
```

> 注意：`set_property SEVERITY ...[get_drc_checks ...]` 写在 **XDC 里不生效**
> （XDC 在综合阶段读入），必须写在 Tcl 脚本里、`write_bitstream` 之前。

## 六、xsim 仿真（签核级）

```bash
vivado -mode batch -source scripts/vivado/sim.tcl -tclargs <TB_TOP> <runtime_ns>
```

日常迭代**不要用 xsim**（启动 40 秒 vs iverilog 3 秒）。
只在需要"与综合器语义完全一致"时用。

## 七、常见报错

| 报错 | 原因 | 解决 |
| --- | --- | --- |
| `[Common 17-39] 'write_bitstream' failed due to earlier errors` | 前面有 ERROR | 往日志上面翻，找第一条 ERROR |
| `[Vivado 12-1345] Error(s) found during DRC` | DRC 有 Error 级检查 | 看 `post_route_drc.rpt` |
| `[DRC LUTLP-1] Combinatorial Loop Alert` | 组合环 | 必须修 RTL |
| `[Common 17-55] 'set_property' expects at least one object` | 对象不存在（如 `get_ports` 名字写错） | 先 `get_ports` 单独试一下 |
| `Cannot find part 'xxx'` | 器件名格式或速度等级不对 | `get_parts xc7a100t*` 列出可用值 |
| `[Synth 8-xxxx] xxx is not declared` | 声明顺序 / 少了 include | Verilog 要求**先声明后使用** |
