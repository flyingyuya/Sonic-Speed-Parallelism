# 09 WM8960 音频模块

> 数据来源：`docs/WM8960模块/` 下的原理图 + 用户手册 + WM8960 v4.2 datasheet。
> **原理图 PDF 用文本提取会串列，本文结论是把 PDF 渲染成 PNG 后直接读图得到的。**

---

## 1. 模块接口（P2，16 pin 排针）

| 模块引脚 | 方向 | 说明 |
| --- | --- | --- |
| `VCC` / `GND` | 电源 | **3.3V** |
| `SDA` / `SCL` | 双向 | I2C 控制总线 |
| `CLK` | **输入** | I2S 位时钟（BCLK） |
| `WS` | **输入** | I2S 帧时钟（LRCLK） |
| `TXSDA` | 输入 | I2S 串行数据（FPGA → 模块，即 SDIN/DACDAT） |
| `RXSDA` | 输出 | I2S 串行数据（模块 → FPGA，即 ADCDAT） |
| `TXMCLK` | **输入** | I2S 系统时钟（发送侧） |
| `RXMCLK` | **输入** | I2S 系统时钟（接收侧） |

**关键结论：`CLK` / `WS` / `MCLK` 手册全部标注为「输入」→ 模块设计为 I2S 从机，FPGA 当主。**

这正是我们想要的：**FPGA 用 MMCM 精确生成 12.288 MHz，做全主模式。**

其余外设：3.5mm 四段带麦耳机口、双通道喇叭接口（可直驱 8Ω 喇叭）、板载麦克风。

---

## 2. ✅ 板载 24 MHz 晶振不用拆 —— 用官方 PLL 配置

### 2.1 问题回顾

原理图上，板载 24 MHz 有源晶振（EN 直接接 3V3，常使能）与 P1 跳线
**共用 `I2S_MCLK` 网络**，插跳线会把 FPGA 输出和晶振输出对打。
而且 MCLK 若与 BCLK/LRCLK 不同源，会导致周期性爆音。

### 2.2 数据手册给出的官方解法

**Table 45（PLL Frequency Examples）里有一行正好是我们要的：**

```
MCLK = 24 MHz  →  SYSCLK = 12.288 MHz
  PLLPRESCALE      = 2          (24 MHz / 2 = 12 MHz 进 PLL)
  PLLN             = 8h
  PLLK             = 3126E8h    (R = 8.192；手册注明 N=8 时 PLL 最稳定)
  SYSCLKDIV        = 2
  固定后分频       = 4
  f2               = 98.304 MHz (手册建议落在 90~100 MHz)
```

**Table 40/41 给出对应的音频参数：**

| 参数 | 值 | 出处 |
| --- | --- | --- |
| SYSCLK | 12.288 MHz | Table 40，fs=48kHz 要求 ADCDIV/DACDIV = 000 |
| ADCDIV / DACDIV | 000 (=1) | → fs = SYSCLK / (1.0×256) = **48.000 kHz** |
| BCLKDIV | 0100 (=4) | → BCLK = 12.288/4 = **3.072 MHz** |
| 最大字长 | **32 bit** | Table 41 |

**和我们现在的 `SLOT=32` / `BCLK=3.072MHz` 完全一致。**

### 2.3 但必须让 WM8960 当 I2S 主

手册 P56 明确写着：

> Clocks for the ADCs and DACs, the DSP core functions, **the digital audio interface**
> and the class D outputs are **all derived from SYSCLK**.

**数字音频接口也从 SYSCLK 派生** → MCLK 必须与 BCLK/LRCLK 同源，
否则接口逻辑用 SYSCLK 去采异步的 BCLK，会周期性错采边沿。

**解法（零硬件改动）：**

```
模块 24MHz 晶振 ──▶ MCLK ──▶ WM8960 内部 PLL ──▶ SYSCLK = 12.288 MHz
                                                      │
                              ┌───────────────────────┼──────────────────┐
                              ▼                       ▼                  ▼
                        BCLK = 3.072 MHz       LRCLK = 48.000 kHz   内部 ADC/DAC
                              │                       │
                              └───────────┬───────────┘
                                          ▼
                                   FPGA 做 I2S 从机
                          （用 clk_sys 过采样 BCLK/LRCLK 恢复时序）
```

**收益：**
- ✅ 不用拆晶振、不用热风枪、不用飞线
- ✅ codec 内部全部同源，无爆音风险
- ✅ 采样率精确 48.000 kHz（由模块晶振决定）
- ✅ 只需 4 根信号线 + 2 根 I2C

**代价：**
- FPGA 侧要把 `i2s_clkgen`（主模式）换成 `i2s_slave_clk`（从模式）
- **输出接口完全不变** → `i2s_rx` / `i2s_tx` / `eq_cascade` / `audio_fifo` **一个字都不用改**

### 2.4 P1 跳线怎么插

**不插跳线**（保持 MCLK 来自板载晶振）。
若出厂已插，拔掉即可 —— 插着会把 FPGA 那边（可能悬空）接到 MCLK 上。

### 2.5 I2C 要写的时钟相关寄存器

| 寄存器 | 值 | 作用 |
| --- | --- | --- |
| R4 (04h) | `00_00_0_000` | ADCDIV=000, DACDIV=000, SYSCLKDIV=00(÷1), CLKSEL=1(**用 PLL**) |
| R8 (08h) | `xxx0_0100` | BCLKDIV=0100 (=SYSCLK/4) |
| R26 (1Ah) | bit0 = 1 | PLLEN = 1 |
| R52 (34h) | PLLPRESCALE=1, PLLN=8 | |
| R53/54/55 | PLLK = 0x3126E8 | |
| R7 (07h) | bit 0 = 1 | **MS = 1（主模式）** |

> ⚠️ 具体位域和寄存器编号以 datasheet 表格为准，上面是索引，**写 `wm8960_init` 时必须逐个核对**。

---

## 3. 管脚分配建议（接 JM2）

板上 **JM1 已被 LCD 占满**（见 [06-board-resources.md](06-board-resources.md) §8），
**音频模块必须接 JM2**（bank 15，32 个空闲 IO）。

| 模块引脚 | FPGA 网络名 | 建议 | 理由 |
| --- | --- | --- | --- |
| `VCC` | 3.3V | JM2 pin 2 | 板上 3.3V |
| `GND` | GND | JM2 pin 4 | |
| `TXMCLK` | `aud_mclk` | JM2 pin 25 `IO_L12P_MRCC_15` (J19) | **时钟输出走 MRCC 脚，抖动更小** |
| `RXMCLK` | 与 `aud_mclk` 并接 | — | 模块的 P1 用来选，两个都接同一个时钟最省事 |
| `CLK` | `aud_bclk` | JM2 pin 21 `IO_L11P_SRCC_15` (J20) | |
| `WS` | `aud_lrclk` | JM2 pin 29 `IO_L13P_MRCC_15` (K18) | |
| `TXSDA` | `aud_sdin` | 任意普通 IO | FPGA → 模块 |
| `RXSDA` | `aud_sdout` | 任意普通 IO | 模块 → FPGA |
| `SCL` | `aud_scl` | 任意普通 IO + 4.7k 上拉 | |
| `SDA` | `aud_sda` | 任意普通 IO + 4.7k 上拉 | |

> **I2C 必须独立于板载 EEPROM 那组总线**（N13/N14），避免地址冲突和设备互相干扰。

---

## 4. WM8960 配置要点（I2C）

| 项 | 值 | 来源 |
| --- | --- | --- |
| I2C 从机地址（7bit） | **0x34** | WM8960 固定，无地址选择脚 |
| 写地址 / 读地址（8bit） | 0x68 / 0x69 | 7bit 左移 |
| 寄存器宽度 | 7 bit 寄存器地址 + 9 bit 数据，打包成 **2 字节** | WM8960 特有格式（非标准 I2C 寄存器写） |
| 上电必须配置 | 时钟/PLL、ADC 使能、DAC 使能、输入通道、输出音量、耳机/喇叭使能 | 不配置则完全不出声 |

> ⚠️ **WM8960 的 I2C 写格式与常见的"寄存器地址 + 数据"两字节格式不同**，
> 是两个字节组成一个 16bit 字：高 7 位寄存器地址 + 后 9 位数据。
> **写 i2c_master 之前必须先看 datasheet 的 Page 15/63**（用户手册第 99 行也提到了）。

---

## 5. 待实物确认清单

| # | 项 | 怎么确认 | 影响 |
| --- | --- | --- | --- |
| 1 | **24 MHz 晶振是否焊了** | 目视 / 万用表 | 决定是否需要拆件（见 §2.4） |
| 2 | 晶振 EN 是否真的接 3V3 | 万用表 | 确认晶振是否常使能 |
| 3 | P1 跳线当前位置 | 目视 | 决定 MCLK 来源 |
| 4 | ADCLRC 是否与 DACLRC 并接 | 万用表 | 决定 ADC 帧时钟从哪来 |
| 5 | 喇叭 / 耳机接口实测 | 上板后 | 出声验证 |
