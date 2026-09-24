# 音速并行 Sonic-Speed-Parallelism

基于 Artix-7 (XC7A100T) 的实时音视频协同处理系统 —— **纯 RTL 实现，不依赖 HLS / PYNQ**。

## 一句话架构

> 12.288 MHz 音频域跑完整音频链路（I2S → 低延迟均衡 → I2S），74.25 MHz 视频域跑 1080p 视频链路与频谱 Overlay，
> 两个域通过双口 BRAM 交换频谱数据，控制域用 UART 实时调参。

## 目录结构

```
rtl/common/     通用逻辑（CDC 同步器、复位同步器、饱和/舍入工具）
rtl/audio/      音频链路（I2S 收发、时钟生成、双二阶均衡器、FFT 频谱）
rtl/video/      视频链路（HDMI 收发、Overlay 绘制）—— 阶段二
sim/tb/         仿真测试平台（iverilog / xsim 双流程）
sim/vectors/    仿真向量（由 Python 黄金模型生成）
scripts/golden/ Python 定点黄金模型（numpy，无 scipy 依赖）
scripts/vivado/ Vivado 命令行流程（非工程模式 Tcl）
scripts/sim/    仿真脚本
constrs/        约束文件（管脚 / 时序）
docs/           设计文档
```

## 快速开始

> 完整工具链说明、命令速查、故障排查见
> [docs/07-toolchain-and-workflow.md](docs/07-toolchain-and-workflow.md)。
> 仿真脚本自带工具定位，**不依赖你的 PATH**；自检用 `bash scripts/sim/run_iv.sh tools`。

```bash
# 1. 生成黄金向量 + 系数 ROM
python3 scripts/golden/gen_all.py

# 2. 跑仿真（iverilog，秒级）
bash scripts/sim/run_iv.sh

# 3. Vivado 综合实现（需要先确认 PART）
vivado -mode batch -source scripts/vivado/build.tcl -tclargs <PART>
```

## 文档索引

| 文档 | 内容 |
| --- | --- |
| [docs/01-architecture.md](docs/01-architecture.md) | 系统架构、时钟域规划、定点格式、延迟预算 |
| [docs/02-roadmap.md](docs/02-roadmap.md) | 六周三阶段任务分解与验收标准 |
| [docs/03-verification.md](docs/03-verification.md) | 验证策略、黄金模型对拍流程、板级测试方法 |
| [docs/04-design-notes.md](docs/04-design-notes.md) | 关键设计决策与踩坑记录 |
| [docs/05-synthesis-report.md](docs/05-synthesis-report.md) | 综合实现实测数据（时钟方案 / 时序 / 资源 / DRC） |
| [docs/06-board-resources.md](docs/06-board-resources.md) | PA-Starlite 板级资源清单与管脚规划 |
| [docs/07-toolchain-and-workflow.md](docs/07-toolchain-and-workflow.md) | 工具链、命令速查、GUI 工程共存方案 |
| [docs/08-skills-index.md](docs/08-skills-index.md) | **开发经验沉淀 Skills 索引 + 问题账本** |
| [docs/09-wm8960-module.md](docs/09-wm8960-module.md) | WM8960 音频模块分析（接口 / MCLK 冲突 / 管脚规划） |
| [docs/10-top-design.md](docs/10-top-design.md) | **顶层设计与接口契约（模块划分 / 端口表 / 开发顺序）** |

## 开发经验 Skills

本项目的踩坑经验、流程规范、验证方法已封装为 3 个可按需加载的 Skills（`.pi/skills/`）：

| Skill | 职责 |
| --- | --- |
| `fpga-rtl-flow` | 纯 RTL 无 GUI 开发流程（iverilog + Vivado batch + 报告解读 + MMCM 时钟规划） |
| `fixed-point-dsp` | 定点 DSP 位宽预算与结构选择（Q 格式、舍入饱和、条件数分析） |
| `rtl-verification` | 与 Python 定点黄金模型逐位对拍、协议行为模型、TB 时序陷阱 |

详见 [docs/08-skills-index.md](docs/08-skills-index.md)（含 13 条问题的完整账本：
现象 / 根因 / 修复 / 量化改善）。

## 当前进度

- [x] 仓库骨架 / 文档 / 工具链脚本
- [x] `i2s_clkgen` / `i2s_rx` / `i2s_tx`（I2S 主模式，32bit 槽，48 kHz）
- [x] `eq_cascade` 5 段双二阶均衡器（时分复用 MAC，6 周期/样本）
- [x] 定点黄金模型 + 仿真对拍通过
- [x] Vivado 综合 + 布局布线 + 比特流全流程跑通：LUT 3.97% / DSP 10个 / Fmax≈50MHz（需求 12.288MHz，4 倍余量）
- [ ] FFT 频谱分析（1024 点，存储式时分复用蝶形）
- [ ] 频谱 → 视频 Overlay
- [ ] HDMI 输入 / 输出链路
- [ ] 板级联调与性能实测
- [x] 确认器件：`xc7a100tfgg484-2`（XC7A100T-2FGG484I）
- [x] 确认时钟方案：200 MHz 差分 → MMCM 精确出 12.288 / 74.25 / 371.25 MHz（Vivado 已验证）
- [x] 板级约束 `constrs/pa_starlite.xdc`（52 条管脚已用 Vivado 器件数据库核对）
- [x] bring-up 顶层 `rtl/top.v`：MMCM + 复位同步 + LED，**已上板验证通过**
      WNS +17.1ns / DRC 0 违例 / 比特流 382KB
