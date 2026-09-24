# 02 六周开发路线

> 原则：**每一阶段结束都必须有可复现的硬数据**（仿真日志 / 时序报告 / 板上实测），
> 不允许出现"功能做完了但测不出来"的阶段。

---

## 阶段一：音频核心闭环（第 1–2 周）✅ 已完成

| 任务 | 交付物 | 验收标准 | 状态 |
| --- | --- | --- | --- |
| I2S 时钟生成 | `rtl/audio/i2s_clkgen.v` | LRCLK 精确 48 kHz，每帧 64 个 BCLK | ✅ |
| I2S 收发 | `rtl/audio/i2s_rx.v` `i2s_tx.v` | 双向闭环 0 误码 | ✅ |
| 双二阶均衡器 | `rtl/audio/eq_cascade.v` | 与 Python 定点模型 6000 样本逐位一致 | ✅ |
| 系数表 | `rtl/audio/eq_coeff_rom.v` | 5 段 × 21 档，全频段误差 < 0.09 dB | ✅ |
| 链路整合 | `rtl/audio/audio_top.v` | 端到端冲激响应逐位一致 | ✅ |
| 定点黄金模型 | `scripts/golden/` | numpy 实现，无 scipy 依赖 | ✅ |

**阶段一实测数据（仿真）**

| 指标 | 数值 | 来源 |
| --- | --- | --- |
| 均衡器处理延迟 | 6 clk @12.288 MHz = **0.49 µs** | `eq_cascade` FSM |
| 端到端链路延迟 | 9 clk = **0.73 µs** | `tb_audio_top` 实测 |
| 单样本处理周期 | 6 / 256（占用率 2.3%） | — |
| 频响最大定点误差 | **0.089 dB**（20 Hz–20 kHz 全频段扫描） | `gen_all.py` |
| 冲激响应逐位一致性 | 左右声道各 **256/256** | `tb_audio_top` |

> **关键结论（写进报告）**：均衡器算法固有延迟为 **0**（IIR 逐样本处理，无分帧），
> 端到端 0.73 µs 全部是硬件流水延迟。这是本项目"< 1 ms"指标的真实来源。

---

## 阶段二：视频与音视频协同（第 3–4 周）

### 2.1 FFT 频谱分析（第 3 周前半）
- [ ] `rtl/audio/fft_core.v`：1024 点实数 FFT，单蝶形时分复用（存储式）
  - 基 2 顺序输入 / 倒位序输出，定点 Q1.15
  - 旋转因子 ROM（由 Python 生成，避免片上三角函数）
  - 资源目标：≤ 4 个 DSP48，≤ 2 个 BRAM36
- [ ] `rtl/audio/spectrum.v`：1024 点 → 32 根柱状条（对数频率 + dB 压缩）
- [ ] `rtl/common/dc_fifo.v`：双时钟 BRAM，音频域 → 视频域传频谱数据
- [ ] 验证：`tb_fft_core`，与 numpy `np.fft.rfft` 对比，误差 < 1%

### 2.2 视频链路（第 3 周后半 – 第 4 周）
- [ ] 视频输入对接（**取决于板上器件，见待确认清单**）
  - 方案 A：HDMI 输入芯片（ADV7611 / IT6802 / TMDS 均衡器）→ 并行 RGB
  - 方案 B：摄像头（OV5640 DVP / MIPI CSI）→ 需注意 MIPI 需专用 IP，DVP 可纯 RTL
- [ ] `rtl/video/vid_timing.v`：1080p30 时序发生器（2200 × 1125 @74.25 MHz）
- [ ] `rtl/video/overlay.v`：频谱柱状图叠加（1px 边框 + 32 柱 + 峰值保持线）
- [ ] `rtl/video/tmds_encoder.v` + `oserdes_tx.v`：HDMI 输出
- [ ] 验证：`tb_overlay`（叠色规则）、板上接显示器目视

### 2.3 音视频同步
- [ ] 频谱柱更新率与音频帧对齐（每 1024 样本一帧 ≈ 21.3 ms ≈ 46.9 fps，
      视频端做 2 帧保持 → 视觉上 23.4 Hz 更新，无撕裂）
- [ ] 验收：示波器/逻辑分析仪测音频输入到 DAC 输出的模拟延迟

---

## 阶段三：优化与收尾（第 5–6 周）

### 3.1 时序与 CDC
- [ ] 全部跨时钟域路径加 `set_max_delay -datapath_only` + `set_false_path`
- [ ] CDC 检查：`report_cdc` 无未约束路径
- [ ] 目标：WNS > 0.5 ns @ 视频域 74.25 MHz / 音频域 12.288 MHz / 系统域 100 MHz

### 3.2 资源优化
- [ ] 均衡器双声道共享 MAC（当前是两个独立实例，可复用为一个 + 时分复用）
- [ ] FFT 旋转因子用对称性压缩 ROM
- [ ] 目标：LUT < 30%、DSP < 25%、BRAM < 30%

### 3.3 材料
- [ ] `docs/05-measurements.md`：所有实测数据 + 测量方法 + 复现步骤
- [ ] ILA 抓取的时序波形截图（系数装载、跨时钟域握手、Overlay 逐行）
- [ ] 演示视频脚本：串口实时调 5 段增益 + 频谱动画 + 音画同步
- [ ] 工程文件打包（`build.tcl` 一键复现）

---

## 硬件决策记录

| # | 问题 | 结论 | 依据 |
| --- | --- | --- | --- |
| 1 | 开发板型号 | **璞致 PA-Starlite，XC7A100T-2FGG484I** | 用户手册 |
| 2 | Vivado PART | **`xc7a100tfgg484-2`** | — |
| 3 | 音频时钟 | **200 MHz 差分 → MMCM 精确出 12.288 MHz** | [05](05-synthesis-report.md) §2，Vivado 实跑验证 |
| 4 | I2S 主从 | **FPGA 当主**（时钟可控且精确），模块只需引出 MCLK 输入 | 同上 |
| 5 | 音频接口 | 板上无 I2S 座，**外部模块 + 杜邦线接 JM1/JM2** | [06](06-board-resources.md) §8 |
| 6 | 视频输入 | 优先走 **DVP**（子卡 CON40 → 主板 JM1），MIPI 作为备选 | [06](06-board-resources.md) §7 |
| 7 | 视频输出 | **先 LCD（并行 RGB，简单），后 HDMI（TMDS，加分）** | [06](06-board-resources.md) §9 |
| 8 | DDR3 | **本项目不使用**，无 MIG，Overlay 走流式 + 行缓存 | [01](01-architecture.md) |

## 待实物核实（写 XDC 前必须做）

详见 [06-board-resources.md](06-board-resources.md) 末尾清单，最关键的三项：

1. **Bank 14 Vcco 电压 + HDMI 官方例程的 IOSTANDARD** → 决定 TMDS 能否直接驱动
2. **W22 是 LED1 还是 HDMI_CEC** → 手册自相矛盾
3. **摄像头子卡插 JM1 时 DVP 是否真的通到 FPGA** → 决定视频输入的工作量是"一天"还是"几个月"
