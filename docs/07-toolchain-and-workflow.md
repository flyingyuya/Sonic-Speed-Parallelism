# 07 工具链与工作流程

> 这份文档解释**为什么这个仓库可以完全不开 Vivado GUI 就能仿真和构建**，
> 以及**如果你要用 GUI 建工程，怎么和现有流程共存**。

---

## 1. 工程结构：三层职责分离

```
rtl/                    ← 【源码】唯一的真相来源，只有 .v 文件
  common/                 cdc_sync / rst_sync
  audio/                  i2s_* / eq_cascade / eq_coeff_rom / audio_top
  video/                  （空，阶段二）

sim/tb/                 ← 【验证】testbench + 行为模型
  codec_model.v           I2S codec 行为模型（ADC + DAC）
  tb_*.v                  三条 testbench

scripts/golden/         ← 【验证】Python 定点黄金模型 + 向量生成
  dsp.py                  numpy 位级复刻 RTL 的定点行为
  gen_all.py              生成 sim/vectors/*.hex 和 rtl/audio/eq_coeff_rom.v
  ※ eq_coeff_rom.v 是自动生成的，不要手改

scripts/sim/            ← 【流程】iverilog 快速仿真
scripts/vivado/         ← 【流程】Vivado 批处理（综合/实现/仿真）
constrs/                ← 【流程】约束文件
build/                  ← 【产物】全部构建输出，已被 gitignore
docs/                   ← 设计文档
```

### 核心设计原则

**`rtl/` 里没有任何工具相关的元数据。** 没有 `.xpr`、没有工程文件、没有 IP 缓存。
同一份 RTL 可以：
- 用 iverilog 仿真（3 秒）
- 用 Vivado 综合（2 分钟）
- 以后换 Zynq 平台直接搬过去

对比**工程模式**的仓库长什么样：

```
myproj.xpr                          二进制/XML，diff 全是噪声
myproj.cache/                       几百 MB 中间产物
myproj.runs/                        综合/实现报告
myproj.srcs/sources_1/imports/      ← 源码副本！改这里等于没改 rtl/
myproj.sim/  myproj.hw/  ...
```

`.xpr` 无法有效做版本控制，两个人改同一个工程基本必冲突。
所以本项目的工程文件**不进 git**，`build/` 整个被忽略。

---

## 2. 工具链

### 2.1 本机实际安装情况（2026-09 实测）

| 工具 | 路径 | 版本 | 是否在默认 PATH |
| --- | --- | --- | --- |
| iverilog | `~/.local/bin/iverilog`（包装脚本）→ `~/.local/opt/iverilog/usr/bin/iverilog` | 13.0 | ❌ **不在** |
| vvp | `~/.local/bin/vvp`（包装脚本） | 13.0 | ❌ **不在** |
| Vivado | `~/Xilinx/Vivado/2020.2/bin/vivado` | 2020.2 | ❌ **不在** |
| Python | `/usr/bin/python3` | 3.14.7 | ✅ |
| numpy | pip 安装 | 2.5.3 | ✅ |
| GTKWave | 未安装 | — | — |

### 2.2 ⚠️ 重要：你的终端里 `iverilog` 和 `vivado` 都敲不出来

实测（清空环境模拟全新终端）：

```
$ env -i HOME=$HOME bash -lc 'which iverilog vivado'
which: no iverilog in (...)
which: no vivado in (...)
```

**原因**：
- iverilog 是**绿色解包安装**——把 Arch 的 `.pkg.tar.zst` 解到 `~/.local/opt/iverilog/usr/`，
  然后在 `~/.local/bin/` 放了两个转发脚本。但 `~/.local/bin` **没有被任何配置文件加进 PATH**
  （`/etc/profile`、`~/.bashrc`、`~/.bash_profile` 里都没有）。
- Vivado 的 bin 目录也没有被加进 PATH。
- 你之所以能用，只是因为我的工具会话继承了一个恰好包含这两个目录的环境变量。

**所以：`run_iv.sh` 已改成自带工具定位**，不依赖你的 PATH。
但为了你自己敲命令方便，建议二选一：

#### 方案 ①（推荐）：用 pacman 正式安装 iverilog

Arch 官方 `extra` 源里就有，版本完全一致：

```bash
sudo pacman -S iverilog
```

装完后 `iverilog` 在 `/usr/bin/iverilog`，永远在 PATH 里，还能跟随系统更新。
装完记得删掉旧的包装脚本（否则 `~/.local/bin` 优先级可能更高）：

```bash
rm ~/.local/bin/iverilog ~/.local/bin/vvp
# 旧的真身也可以删了（可选，省 6.6 MB）
# rm -r ~/.local/opt/iverilog
```

#### 方案 ②：把现有安装加进 PATH

编辑 `~/.bashrc`，在末尾加：

```bash
# --- EDA 工具 ---
export PATH="$HOME/.local/bin:$PATH"                       # iverilog / vvp
export PATH="$HOME/Xilinx/Vivado/2020.2/bin:$PATH"         # vivado / xsim
```

然后 `source ~/.bashrc` 或重开终端。

> 顺带：GTKWave 也在官方源里，看波形建议装：
> ```bash
> sudo pacman -S gtkwave
> ```

### 2.3 自检命令

```bash
bash scripts/sim/run_iv.sh tools
```

输出示例：

```
=========================================================
 仿真工具链
=========================================================
 iverilog : /home/flyingyu/.local/bin/iverilog
            Icarus Verilog version 13.0 (stable) (v13_0-dirty)
 vvp      : /home/flyingyu/.local/bin/vvp
 库路径   : （使用默认路径）

 当前 shell 的 PATH 是否含 iverilog 所在目录：
   是
=========================================================
```

---

## 3. 为什么不用打开 Vivado

### 3.1 核心认知：GUI 只是个 Tcl 外壳

Vivado 有三种模式：

| 启动方式 | 本质 |
| --- | --- |
| `vivado -mode gui` | 图形界面 |
| `vivado -mode tcl` | 图形界面 + Tcl 控制台 |
| **`vivado -mode batch -source xxx.tcl`** | **纯 Tcl 引擎，无窗口** |

**GUI 里你点的每个按钮，底层就是一条 Tcl 命令。**
点 "Run Synthesis" = 执行 `synth_design -top xxx -part xxx`；
点 "Generate Bitstream" = 执行 `launch_runs impl_1 -to_step write_bitstream`。

所以 GUI 能做的事 Tcl 全能做，反过来不成立。

### 3.2 工程模式 vs 非工程模式

| | 工程模式 | **非工程模式（本项目用）** |
| --- | --- | --- |
| 入口 | `create_project` → `.xpr` | 直接 `read_verilog` |
| 磁盘占用 | 几百 MB（cache/runs/srcs…） | 只有指定路径的产物 |
| 文件依赖跟踪 | Vivado 自动 | 你自己控制 |
| 复现方式 | 提交整个工程 | **提交一个 `.tcl`** |
| IP 核支持 | 自动生成 + OOC 综合 | 需手写 `read_ip`/`generate_target` |
| 适合场景 | 大型工程 / 重度用 IP | **脚本化、CI、学习、小工程** |

### 3.3 `build.tcl` 的全部核心就 6 行

```tcl
read_verilog [glob rtl/common/*.v rtl/audio/*.v]   # 读源码
read_xdc     constrs/audio_top.xdc                 # 读约束
synth_design -top audio_top -part xc7a100tfgg484-2 # 综合（≈ GUI 的 Run Synthesis）
place_design                                        # 布局
route_design                                        # 布线
write_bitstream -force build/vivado/audio_top.bit   # 出比特流
```

GUI 左侧 "Flow Navigator" 那一列按钮，等价于这 6 行。
脚本里剩下的 90 行都是 `report_*`（出报告）和错误处理。

`-tclargs` 后面的参数会被脚本里的 `$argv` 接住，所以同一个脚本能构建任意顶层：

```bash
vivado -mode batch -nojournal -log my.log \
       -source scripts/vivado/build.tcl \
       -tclargs xc7a100tfgg484-2 audio_top constrs/audio_top.xdc
#                ↑PART          ↑TOP     ↑XDC
```

---

## 4. 两条腿走路：为什么仿真用 iverilog 而不是 xsim

| | iverilog | xsim（Vivado 自带） |
| --- | --- | --- |
| 编译+运行 | **~3 秒** | ~40 秒 |
| 启动开销 | 无 | 加载 Vivado 库 + license 检查 |
| 语法覆盖 | Verilog-2005（本项目够用） | 完整 SystemVerilog |
| 能抓的错 | 只有 RTL 语法/功能 | **时序、DSP 推断、DRC、组合环** |

所以流程是：

```
改 RTL ──▶ bash scripts/sim/run_iv.sh        （3 秒，验功能对不对）
             │ PASS
             ▼
          里程碑 ──▶ vivado -mode batch ... build.tcl   （2 分钟，验能不能上板）
```

**两者都不可省。** 真实案例（本项目踩过）：

> `audio_fifo` 里 `wptr_nxt → full → do_wr → wptr_nxt` 构成组合环。
> iverilog 仿真时这个环恰好能收敛，**三条 testbench 全部 PASS**。
> 但 Vivado 综合时 DRC 报 `LUTLP-1 Combinatorial Loop Alert` ——
> 真实硬件里这是个竞争条件。

**结论：仿真通过 ≠ 设计正确。** 每次改完 RTL 都要跑一遍 Vivado。

---

## 5. 用 GUI 建工程会不会和现有流程冲突？

**不会冲突，但有 4 个坑，第 2 个最危险。**

### 坑 1：产物目录被 `git add -A` 扫进去

新建工程时 Vivado 会生成 `.cache/`（几百 MB）、`.runs/`、`.srcs/`、`.sim/`、`.hw/`、
`.ip_user_files/`。

✅ 这些模式**已经写进 `.gitignore`** 兜底。
✅ 更推荐：**工程目录放 `build/vivado_prj/`**（`build/` 整个被忽略）。

### 坑 2（最危险）：源码被拷贝成两份

- 用**新建工程向导**里的 "Add Files" → Vivado 会把 `rtl/*.v` **物理拷贝**到
  `<proj>.srcs/sources_1/imports/`
- 之后你在 `rtl/` 改代码，GUI 工程用的是**旧副本**
- 结果：对着一个假象调试，修改怎么都不生效

**正确做法**：

```
1. File → Project → New，建一个【空工程】（向导里一步 source 都不要加）
2. Sources 窗口右键 → Add Sources → Add Existing Files
3. 选 rtl/ 下的文件 → 默认是"引用"（工程里记相对路径），不拷贝
```

**验证方法**：改一行 `rtl/audio/eq_cascade.v`（加个注释），
看 Vivado 是否弹 "file has changed / reload"。

### 坑 3：用了 IP 核，非工程模式流程就失效

IP（HDMI IP / Clocking Wizard / FFT IP）需要 **OOC（out-of-context）综合**，
非工程模式的 `read_verilog` 处理不了，必须改写成：

```tcl
read_ip  .../xxx.xci
generate_target all [get_ips xxx]
synth_ip [get_ips xxx]
```

→ 要么改写 `build.tcl` 支持 IP，要么以后统一走工程模式。

> 这也是建议 **FFT 手搓而不是调 IP** 的隐性理由之一：少一个 IP 依赖，
> 流程就少一处会崩的地方。

### 坑 4：两个流程抢同一个输出文件

`build.tcl` 输出 `build/vivado/audio_top.bit`。
GUI 工程的输出目录如果也设成这里会互相覆盖。换个名就行。

### 三种共存方案

| 方案 | 做法 | 适合 |
| --- | --- | --- |
| **A（当前采用）** | 日常构建走非工程模式；GUI 工程只用来"看时序 / 配 ILA / 生成 IP"，放 `build/vivado_prj/` | 现在 |
| **B** | 完全走工程模式，但**用 Tcl 脚本生成工程**（`create_project` + `add_files` + `launch_runs`），仓库只提交 `.tcl` + `.xdc` | 后面想以 GUI 为主 |
| **C** | 继续非工程模式，ILA 也手写 Tcl（`create_debug_core`） | 最纯粹，但配 ILA 略麻烦 |

A 和 B 不冲突，可以先用 A，需要时再补一个 `scripts/vivado/project.tcl`（约 30 行）。

---

## 6. 命令速查

### 6.1 生成黄金向量 + 系数 ROM

```bash
python3 scripts/golden/gen_all.py
```
产出：`sim/vectors/*.hex`、`sim/vectors/*_meta.txt`、`rtl/audio/eq_coeff_rom.v`
（`eq_coeff_rom.v` 是自动生成的，**不要手改**）

### 6.2 快速仿真（3 秒）

```bash
bash scripts/sim/run_iv.sh                     # 跑全部三条 testbench
bash scripts/sim/run_iv.sh eq_cascade          # 只跑一个
WAVE=1 bash scripts/sim/run_iv.sh eq_cascade   # 顺便出波形到 sim/build/
bash scripts/sim/run_iv.sh tools               # 只打印工具版本，不跑仿真
```

可选的 testbench 名字：`eq_cascade` / `i2s_loopback` / `audio_top`

### 6.3 Vivado 综合 + 实现 + 比特流（2 分钟）

```bash
vivado -mode batch -nojournal -log my.log \
       -source scripts/vivado/build.tcl \
       -tclargs xc7a100tfgg484-2 audio_top constrs/audio_top.xdc
```

产物全在 `build/vivado/`：

| 文件 | 内容 |
| --- | --- |
| `post_synth_util.rpt` | 综合后资源 |
| `post_synth_timing.rpt` | 综合后时序 |
| `post_route_util.rpt` | **布线后资源（看这个）** |
| `post_route_timing.rpt` | **布线后时序（看这个）** |
| `post_route_drc.rpt` | **DRC 检查（组合环等）** |
| `post_route.dcp` | 布线后检查点（可 reopen 做 ILA） |
| `audio_top.bit` | 比特流 |

### 6.4 挖报告（构建完必看的三条）

```bash
# 资源
grep -E "^\| (Slice LUTs|Slice Registers|DSPs|Block RAM Tile) " \
     build/vivado/post_route_util.rpt

# 时序：WNS / WHS
sed -n '/WNS(ns)/,+2p' build/vivado/post_route_timing.rpt | tail -1

# 组合环数量 —— 必须是 0
grep -c LUTLP build/vivado/post_route_drc.rpt
```

### 6.5 看波形

```bash
WAVE=1 bash scripts/sim/run_iv.sh audio_top
gtkwave sim/build/tb_audio_top.vcd &
```

> 本机还没装 GTKWave。可选：`sudo pacman -S gtkwave`（官方源有）。
> 也可以把 VCD 拖进 Vivado 的 Waveform Viewer。
>
> ⚠️ 波形可能很大：`tb_eq_cascade` 有 6000 样本，全 dump 是几百 MB。
> 所以默认关波形（脚本自动加 `+novcd`）。

### 6.6 从检查点重新跑（省时间）

综合/实现要 2 分钟，如果只想改约束或挖时序，可以复用 `post_route.dcp`：

```bash
vivado -mode batch -source /dev/stdin <<'EOF'
open_checkpoint build/vivado/post_route.dcp
report_timing_summary -delay_type max -max_paths 50
report_utilization
EOF
```

---

## 7. 故障排查

| 现象 | 原因 | 解决 |
| --- | --- | --- |
| `iverilog: command not found` | 不在 PATH | 见 §2.2；或直接用 `run_iv.sh`（它自己找） |
| `vivado: command not found` | 不在 PATH | `export PATH="$HOME/Xilinx/Vivado/2020.2/bin:$PATH"` |
| `run_iv.sh` 报 `[编译失败]` | RTL 语法错 | 看 `sim/build/<tb>.log` |
| 仿真 PASS 但综合报 `LUTLP-1` | 组合环 | **必须修**，见 §4 的案例 |
| Vivado 提示 `Cannot find xxx.v` | GUI 工程里加的是拷贝 | 删掉重新 Add Existing Files（引用模式） |
| `git status` 里出现一堆 `.cache/` `*.rpt` | GUI 工程产物 | 已在 `.gitignore`；顺手 `git check-ignore -v <文件>` 确认 |
| 改了 `rtl/` 但 GUI 工程不更新 | 拷贝模式 | 见坑 2 |
| 波形文件几百 MB | 没加 `+novcd` | `run_iv.sh` 默认已加，手动跑 `vvp` 时记得带 |

---

## 8. 一句话总结

> **`rtl/` 是唯一真相来源；`scripts/` 下是可复现的流程；
> `build/` 是可随时删除的产物；`docs/` 是决策记录。**
>
> 只要 `rtl/` + `constrs/` + `scripts/` 在，换台电脑三条命令就能重建整个项目。

---

## 附：「零警告」到底该怎么做到

本工程要求构建过程**零警告**。但这件事有个陷阱：**"看不见警告"和"没有警告"是两回事**。

正确的做法分三类，**先分类，再逐个处理**：

| 类别 | 判断标准 | 处理方式 | 本工程实例 |
| --- | --- | --- | --- |
| **① 真实缺陷** | 警告描述的现象会**实际发生** | **改设计** —— 这是唯一正确的选择 | 异步复位（账本 45/46）、`DRIVE` 写在输入端口（44） |
| **② 前提不成立的建议** | 警告的**推理前提**在你这个设计里为假 | **写清判据后豁免**（waive） | `DPIP-1`/`DPOP-1`/`DPOP-2`（账本 47） |
| **③ 环境/流程信息** | 与设计本身无关 | 忽略，或修流程 | `NSTD-1`/`UCIO-1`（管脚未填时自动降级） |

### 怎么区分 ① 和 ② —— 问三个问题

1. **警告描述的坏事会发生吗？**
   `REQP-1839` 说"复位期间 RAM 内容可能损坏"，而我们的复位是**域内同步**的，
   且 RAM 内容本来就不需要复位 → 不会发生 ✅ 但注意：
   这条最后我们**改设计了**（不再复位 RAM 内容），因为改写更简单也更正确。

2. **消掉警告的代价是什么？**
   `DPIP-1` 建议给 DSP 打拍。但我们所有 DSP 通路都有**逐位对拍的黄金模型**，
   插寄存器会改变数值行为，需要全量重验，而**功能收益为零** → 代价不合理 ✗

3. **有量化证据吗？**
   "时序已经够了"不能靠感觉说。本工程的证据是 post-route 报告：
   `clk_sys` WNS = **+1.548 ns**，`clk_pix` WNS = **+41.573 ns**，
   且最差路径（FFT 工作存储器回写，逻辑级数 32）**根本不是 DSP**。

### 豁免怎么落地（可审计，不隐藏）

```tcl
# scripts/vivado/drc_waivers.tcl —— 由 build.tcl 在 report_drc 之前 source
create_waiver -type DRC -id DPIP-1 -description "……量化理由……"
```

`build.tcl` 里的调用：

```tcl
set _waiver_tcl [file join [file dirname [info script]] drc_waivers.tcl]
if {[file exists $_waiver_tcl]} { source $_waiver_tcl }
report_drc -file [file join $OUT post_route_drc.rpt]
```

**关键：豁免项不会从报告里消失**，而是单独计数：

```
             Violations found: 0
             Violations waived: 50
```

任何人拿到 `post_route_drc.rpt` 都能看到"有 50 条被豁免了"，
然后去 `drc_waivers.tcl` 里读理由 —— **这是可审计的**，
和"把警告过滤掉"有本质区别。

### 配套脚本

| 脚本 | 用途 |
| --- | --- |
| `scripts/vivado/build.tcl` | 综合 → 实现 → 比特流（整机） |
| `scripts/vivado/synth_check.tcl` | 单模块 OOC 综合 + DRC + CDC |
| `scripts/vivado/program.tcl` | 烧板（`-tclargs detect` 只探测） |
| `scripts/vivado/drc_waivers.tcl` | DRC 豁免判据（被上面两个 tcl source） |
| `scripts/sim/run_iv.sh` | iverilog 全量回归（21 个 TB + **Verilator 静态检查**） |
| `scripts/uart_term.py` | UART 命令通道终端 / 协议自检 |

### 三层检查，各管一段

| 层 | 工具 | 能抓什么 | 抓不到什么 |
| --- | --- | --- | --- |
| 1 | **iverilog** TB | 功能对不对（逐位对拍）| **多重驱动**（连 `-Wall` 都沉默）✗ |
| 2 | **Verible** lint | 编码风格 | 同上 ✗ |
| 3 | **Verilator** `-Wall` | **多重驱动**（`MULTIDRIVENPROC`）、组合环（`UNOPTFLAT`）、意外锁存器（`LATCH`）| 时序、资源 |
| 4 | **Vivado** 综合 | 上面全部 + 时序 + DRC | 慢（分钟级）|

> **账本第 52 条就是被第 1、2 层漏掉、靠第 4 层才抓到的。**
> 加第 3 层的目的就是把这类错误**提前到秒级**。
>
> ⚠️ Verilator 只有在 **`-Wall`** 下才启用 `MULTIDRIVENPROC` ——
> 不加 `-Wall` 时它同样沉默。这一条是实测确认的。

Verilator 那一步关掉了一批**风格类**警告（位宽隐式扩展、未用信号、
空端口连接、`rst_sync` 的同步+异步混用等），判据写在
`scripts/sim/run_iv.sh` 的注释里 —— 和下面「零警告」那一节是同一套方法。

### ⚠️ 什么时候必须回来重看豁免

**如果以后出现时序违例，第一件事就是把 `drc_waivers.tcl` 的豁免去掉，
重新看这 50 条** —— 因为那时的前提（"时序够了"）已经不成立了。

> **一句话**：零警告不是"让工具闭嘴"，而是"每一条警告都被读过、理解过、
> 并且做出了有据可依的处置"。真正该改的一定要改（①），
> 确实不适用的要写清为什么（②），而且**留下的记录要能让别人复核**。
