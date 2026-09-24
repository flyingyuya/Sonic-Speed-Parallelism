---
name: fpga-rtl-flow
description: 纯 RTL FPGA 工程的无 GUI 开发流程。覆盖工具链定位与自检、iverilog 秒级快速仿真、Vivado batch 模式综合/实现/比特流、构建报告挖掘（资源/时序/DRC）、GUI 工程与非工程模式共存、波形查看、MMCM 时钟规划。当需要仿真、综合、构建或上板一个纯 RTL FPGA 工程，要写/改 Tcl 流程脚本，或排查 "command not found"、组合环 DRC、时序违例、比特流无法生成等构建问题时使用。
---

# FPGA 纯 RTL 无 GUI 开发流程

## 核心原则

**`rtl/` 是唯一真相来源，工具产物全部扔进 `build/`。**

- `rtl/` 里不放任何工具元数据（无 `.xpr`、无 IP 缓存、无工程文件）——
  同一份 RTL 要能同时被 iverilog、Vivado、未来的 Zynq 平台复用
- `scripts/` 下是**可复现的流程**（纯文本，可 diff、可版本控制）
- `build/` 是**可随时删除的产物**（必须进 `.gitignore`）

## 两条腿走路：为什么需要两个工具

| | iverilog | Vivado (xsim / 综合) |
| --- | --- | --- |
| 编译+运行 | **~3 秒** | ~40 秒（加载库 + license 检查） |
| 能抓的错 | 只有 RTL 语法/功能 | **时序、DSP 推断、DRC、组合环** |

```
改 RTL ──▶ iverilog 快速仿真（秒级，验功能对不对）
             │ PASS
             ▼
          里程碑 ──▶ Vivado batch 构建（分钟级，验能不能上板）
```

**两者都不可省。** 真实反例：iffo 的 `wptr_nxt → full → do_wr → wptr_nxt`
组合环在 iverilog 里恰好能收敛，**三条 testbench 全部 PASS**，
但 Vivado 报 `DRC LUTLP-1 Combinatorial Loop Alert` —— 硬件上是真实竞争条件。

> **仿真通过 ≠ 设计正确。**

## 流程

### 步骤 0：环境自检（必做，一次）

很多机器上 `iverilog` / `vivado` **不在默认 PATH 里**（绿色解包安装、
用户目录安装、module 加载等）。先确认：

```bash
bash scripts/sim/run_iv.sh tools     # 打印工具真实路径 + 版本 + PATH 命中情况
env -i HOME=$HOME bash -lc 'which iverilog vivado'   # 模拟全新终端
```

**流程脚本必须自带工具定位，不能依赖调用者的 PATH。**
`run_iv.sh` 里的 `locate_tool()` 就是干这个的：先查 PATH，
再按常见位置兜底（`~/.local/bin`、`~/.local/opt/iverilog/usr/bin`、`/usr/bin` …），
并为绿色解包安装自动补 `-B`/`-M` 运行库路径。

### 步骤 1：快速仿真（3 秒）

```bash
bash scripts/sim/run_iv.sh                     # 跑全部 testbench
bash scripts/sim/run_iv.sh <tb_name>           # 只跑一个
WAVE=1 bash scripts/sim/run_iv.sh <tb_name>    # 出波形（默认关，波形很大）
bash scripts/sim/run_iv.sh tools               # 只自检环境
```

关键设计：**默认注入 `+novcd` 关波形**。一个大向量的 VCD 能有几百 MB，
写盘时间远超仿真本身。testbench 里用 `$test$plusargs("novcd")` 判断。

### 步骤 2：Vivado batch 构建（分钟级）

```bash
vivado -mode batch -nojournal -log my.log \
       -source scripts/vivado/build.tcl \
       -tclargs <PART> <TOP> <XDC>
#                ↑器件   ↑顶层  ↑约束（可省略）
```

**非工程模式的全部核心就 6 行**：

```tcl
read_verilog [glob rtl/*/*.v]
read_xdc     constrs/<top>.xdc
synth_design -top <TOP> -part <PART> -flatten_hierarchy none
place_design
route_design
write_bitstream -force build/vivado/<TOP>.bit
```

GUI 左侧 "Flow Navigator" 那一列按钮，等价于这 6 行。
`-tclargs` 后面的参数由脚本里的 `$argv` 接住，所以同一个脚本能构建任意顶层。

`-flatten_hierarchy none` 的作用：保留层次名，方便 `read_checkpoint` 后
用 ILA 抓内部信号、做增量实现。

### 步骤 3：挖报告（构建完必看三条）

```bash
# 资源
grep -E "^\| (Slice LUTs|Slice Registers|DSPs|Block RAM Tile) " \
     build/vivado/post_route_util.rpt

# 时序：WNS（建立）/ WHS（保持）
sed -n '/WNS(ns)/,+2p' build/vivado/post_route_timing.rpt | tail -1

# 组合环数量 —— 必须是 0
grep -c LUTLP build/vivado/post_route_drc.rpt
```

**报告解读要点：**

| 报告 | 看什么 | 危险信号 |
| --- | --- | --- |
| `post_route_util.rpt` | DSP / BRAM 占用是否符合设计预期 | DSP 数量远超手算值（可能是推断失败） |
| `post_route_timing.rpt` | WNS、关键路径的 Source/Destination | WNS < 0 |
| `post_route_drc.rpt` | `LUTLP-1` 组合环、`NSTD-1`/`UCIO-1` 未约束 IO | **LUTLP 必须为 0** |
| 综合日志 | `DPOR-1`（异步复位影响 DSP 吸收）、`DPIP-1`（DSP 输入未流水） | 只影响 QoR，不影响正确性 |

**资源数字要能对上设计意图。** 例：5 段双二阶时分复用 + 2 声道 = 10 个 DSP，
报告出来正好 10 —— 这说明"时分复用 section"结构成立（DSP 占用与段数无关）。
对不上就说明综合器做了别的事。

### 步骤 4：从检查点重新跑（省时间）

只改约束或想挖时序时，不必重跑综合：

```bash
vivado -mode batch -source /dev/stdin <<'EOF'
open_checkpoint build/vivado/post_route.dcp
report_timing_summary -delay_type max -max_paths 50
report_utilization
EOF
```

## 决策：用工程模式还是非工程模式

| | 工程模式 | **非工程模式（推荐给纯 RTL 小工程）** |
| --- | --- | --- |
| 入口 | `create_project` → `.xpr` | 直接 `read_verilog` |
| 磁盘 | 几百 MB（cache/runs/srcs…） | 只有指定路径的产物 |
| 复现 | 提交整个工程（`.xpr` diff 全是噪声） | **提交一个 `.tcl`** |
| IP 核 | 自动生成 + OOC 综合 | 需手写 `read_ip`/`generate_target` |
| 版本控制 | 差 | 好 |

**要 GUI 又要干净：** GUI 工程只用来"看时序 / 配 ILA / 生成 IP"，
放在 `build/<proj>_prj/`（已被 `.gitignore` 忽略）；日常构建仍走 batch。

### GUI 工程的 4 个坑

1. **产物被 `git add -A` 扫进去** —— `.cache/` 有几百 MB。
   `.gitignore` 必须覆盖 `*.xpr` `*.cache/` `*.runs/` `*.srcs/` `*.hw/` `*.ip_user_files/`。
2. **源码被拷贝成两份（最危险）** —— 用**新建向导**的 "Add Files" 会物理拷贝到
   `<proj>.srcs/sources_1/imports/`，之后改 `rtl/` 不生效。
   **正确做法：建空工程 → 再 Add Sources → Add Existing Files（引用模式）。**
   验证：`find build -path "*imports*" -name "*.v"`，输出为空即正确。
3. **用了 IP，非工程模式流程失效** —— IP 需要 OOC 综合，
   必须补 `read_ip` + `generate_target all` + `synth_ip`。
4. **两个流程抢同一个输出文件** —— 约定好各自的输出目录。

## 时钟规划

**板载时钟源和 MMCM 参数是整个工程最容易翻车的前置条件。**
详见 [references/mmcm-clocking.md](references/mmcm-clocking.md)，要点：

- MMCM 可达频率集 = `Fin × M / (D × O)`，VCO 必须落在 **600~1200 MHz**
- **`CLKOUT0_DIVIDE_F` 支持 1/8 步进** —— 这是能否凑出"奇怪频率"的关键。
  例：200 MHz 输入要 12.288 MHz → `D=5, M=24.000, O=78.125`
  （`960/78.125 = 12.288` 正好整除）
- **一个 MMCM 无法同时产出互不成简单倍数的两个时钟**（VCO 得是公倍数），
  该用几个 CMT 就用几个
- **必须用 Vivado 实跑验证**，不要只靠手算 —— `report_clocks` 会打印实际周期

## 约束文件要点

```tcl
# 时钟：优先按"目标频率"约束，而不是真实频率
#   真实频率太低（如 12 MHz）时报告全是正裕量，看不出优化空间也定位不到关键路径
create_clock -period 10.000 -name clk [get_ports clk]   # 过约束到 100 MHz 反推 Fmax

# 慢速静态控制信号不加时序约束
set_false_path -from [get_ports {cfg_* [*]}]

# 板级配置（不写会导致 bitstream 生成失败）
set_property CFGBVS VCCO [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
```

管脚没分配时，DRC 会报 `NSTD-1` / `UCIO-1` 导致 `write_bitstream` 失败。
**开发早期**可以在 Tcl 里按"是否存在 LOC 约束"自动降级为 Warning，
但要**打印醒目警告说明此比特流不可上板**，避免误下载。

## 完整命令速查

见 [references/vivado-batch-cheatsheet.md](references/vivado-batch-cheatsheet.md)。

## 验收标准

一个可复现的纯 RTL 工程应该满足：

- [ ] `bash scripts/sim/run_iv.sh` 在**干净环境**（清空 PATH）下也能通过
- [ ] `bash scripts/sim/run_iv.sh tools` 能打印工具真实路径与版本
- [ ] Vivado batch 一条命令能从零跑到比特流，无需打开 GUI
- [ ] `grep -c LUTLP build/vivado/post_route_drc.rpt` 输出 **0**
- [ ] 资源占用能用手算值解释（DSP/BRAM 数量对得上设计意图）
- [ ] `git status` 在构建后保持干净（产物全被忽略）
- [ ] 删掉 `build/` 后，三条命令能完整重建
