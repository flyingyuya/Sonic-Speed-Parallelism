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

### 2.5 I2C 寄存器表（已逐位对 datasheet 核实 ✅）

> 2025-09 核对来源：`docs/WM8960模块/WM8960_v4.2.pdf`
> Table 39 / 40 / 41 / 44 / 45 + 寄存器位域表（P57~61）。
> **每个 9 位数据都按位展开验算过，不是抄的。**

#### 关键位域（原表纠正）

```
R4  (04h) Clocking (1)   [8:6] ADCDIV[2:0]  [5:3] DACDIV[2:0]
                         [2:1] SYSCLKDIV[1:0]  (00=÷1, 10=÷2)
                         [0]   CLKSEL  (0=SYSCLK 来自 MCLK, 1=来自 PLL)

R7  (07h) Audio Interface [8]ALRSWAP [7]BCLKINV [6]MS [5]DLRSWAP [4]LRP
                          [3:2]WL[1:0]  (10=24bit)
                          [1:0]FORMAT[1:0]  (10=I2S)

R8  (08h) Clocking (2)   [8:6] DCLKDIV[2:0]  [5:4] 保留
                         [3:0] BCLKDIV[3:0]  ← 注意是 4 位，不是 3 位
                         0000=÷1  0100=÷4  0111=÷8  1101~1111=÷32
                         复位默认 1_1100_0000 (DCLKDIV=111, BCLKDIV=0000)

R26 (1Ah) PWRMGMT2       [0] PLLEN

R52 (34h) PLL N          [8:6]OPCLKDIV [5]SDM [4]PLLPRESCALE(1=÷2) [3:0]PLLN
R53 (35h) PLL K1         [5:0] PLLK[23:16]
R54 (36h) PLL K2         [8:0] PLLK[15:8]
R55 (37h) PLL K3         [8:0] PLLK[7:0]
```

#### PLL 公式与官方例表（Table 45）

```
R  = f2 / f1              其中 f1 = MCLK/PLLPRESCALE
PLLN = int(R)             f2 = 4 x SYSCLKDIV_div x SYSCLK
PLLK = int(2^24 x (R-PLLN))    要求 5 < PLLN < 13，f2 落在 90~100 MHz
```

**Table 45 原文有一行正好是 24 MHz：**

```
MCLK=24  SYSCLK=12.288  f2=98.304  PRESCALE=2  POSTSCALE=2  FIXED÷4
   R = 8.192   N = 8h   K = 3126E8h
```

> ⚠️ 手册自相矛盾：正文算例写 `k = 3221225 = 3126E9h`，
> 而 Table 45 和寄存器复位默认值都写 `3126E8h`。
> **两者只差 2^-24 × 8.192 ≈ 5e-7，对应 SYSCLK 偏差 0.006 Hz，随便用哪个都行。**
> 我们用 **3126E9h**（既等于正文算例，又等于复位默认值，写入是幂等的）。

#### 我们要写的完整寄存器表（fs = 48.000 kHz）

> ⚠️ 本表由 `scripts/golden/gen_wm8960_table.py` 生成，**与 `rtl/wm8960/WM8960_init_table.v` 同源**。
> 手算太容易错 —— 初版这里就把 `reg<<9` 写成了 `reg<<8`（I2C 字节列全错），
> 还把 R52 的 SDM 位写反了（写成整数模式，容不下小数分频 K）。

| # | 寄存器 | 9 位数据 | 16 位字 | I2C 字节 | 说明 |
| --- | --- | --- | --- | --- | --- |
| 0 | R15 (0Fh) | `0_0000_0000` | 0x1E00 | `1E 00` | software reset (must be 1st) |
| 1 | R25 (19h) | `1_1111_1100` | 0x33FC | `33 FC` | PWRMGMT1: VMIDSEL=11 VREF AINL AINR |
| 2 | R47 (2Fh) | `0_0000_1100` | 0x5E0C | `5E 0C` | PWRMGMT3: LOMIX ROMIX |
| 3 | R26 (1Ah) | `1_1110_0000` | 0x35E0 | `35 E0` | PWRMGMT2: DACL DACR LOUT1 ROUT1 |
| 4 | R8 (08h) | `1_1100_0100` | 0x11C4 | `11 C4` | CLOCKING2: BCLKDIV=0100 (/4) |
| 5 | R7 (07h) | `0_0100_1010` | 0x0E4A | `0E 4A` | IFACE1: MS=1 I2S 24bit |
| 6 | R52 (34h) | `0_0011_1000` | 0x6838 | `68 38` | PLL N: PRESCALE=1 SDM=1 N=8 |
| 7 | R53 (35h) | `0_0011_0001` | 0x6A31 | `6A 31` | PLL K[23:16] |
| 8 | R54 (36h) | `0_0010_0110` | 0x6C26 | `6C 26` | PLL K[15:8] |
| 9 | R55 (37h) | `0_1110_1001` | 0x6EE9 | `6E E9` | PLL K[7:0] -> K=0x3126E9 |
| 10 | R26 (1Ah) | `1_1110_0001` | 0x35E1 | `35 E1` | PWRMGMT2 + PLLEN=1 -> PLL ON |
| 11 | R2 (02h) | `1_1111_1001` | 0x05F9 | `05 F9` | LOUT1 vol +0dB |
| 12 | R3 (03h) | `1_1111_1001` | 0x07F9 | `07 F9` | ROUT1 vol +0dB |
| 13 | R21 (15h) | `1_1100_0011` | 0x2BC3 | `2B C3` | L ADC vol 0dB |
| 14 | R22 (16h) | `1_1100_0011` | 0x2DC3 | `2D C3` | R ADC vol 0dB |
| 15 | R45 (2Dh) | `0_1000_0000` | 0x5A80 | `5A 80` | L mixer bypass 0dB |
| 16 | R46 (2Eh) | `0_1000_0000` | 0x5C80 | `5C 80` | R mixer bypass 0dB |
| 17 | R43 (2Bh) | `1_0101_0000` | 0x5750 | `57 50` | L input boost LIN3 = 0dB |
| 18 | R44 (2Ch) | `0_0000_1010` | 0x580A | `58 0A` | R input boost RIN2 = 0dB |
| 19 | R4 (04h) | `0_0000_0101` | 0x0805 | `08 05` | CLOCKING1: SYSCLKDIV=/2 CLKSEL=PLL |

**加粗的是与 Music-Spectrum 参考工程的差异** —— 它那版完全不用 PLL，
直接吃外部 MCLK，而且没开 DAC（它只做频谱分析，不播放）。

#### 写入顺序为什么不能随便改

| 约束 | 原因 |
| --- | --- |
| 软复位必须第一条 | 否则后面的配置会被复位冲掉 |
| PLL 配置（K/N/PRESCALE）在 PLLEN 之前 | PLL 使能的瞬间就会按当前配置起振 |
| **CLKSEL=1 必须最后一条** | 切过去之前 PLL 必须已经锁定，否则 SYSCLK 短暂无时钟，BCLK/LRCLK 全乱 |
| 每条之间留 1 ms | 由 `WM8960_init.v` 的 `DLY_MS` 参数控制。从 PLLEN=1 到 CLKSEL=1 之间共 9 条 = **9.649 ms**，远大于典型锁定时间 |

> **实测证据**：`sim/tb/tb_wm8960_init.v` 用 I2C 从机行为模型把发出的字节解回来，
> 逐条比对寄存器值，并断言 `PLLEN -> CLKSEL` 的间隔 ≥ 5 ms。实测 **9.649 ms** ✓

#### PLL 关键参数（datasheet Table 45 有现成一行）

```
MCLK = 24 MHz  ->  SYSCLK = 12.288 MHz
  PLLPRESCALE = 1   (24 MHz / 2 = 12 MHz 进 PLL)
  SDM         = 1   (必须！分数模式，容得下非整数比率 R=8.192)
  PLLN        = 8
  PLLK        = 0x3126E9
  f2          = 98.304 MHz（手册建议落在 90~100 MHz）
  SYSCLKDIV   = 10  (R4[2:1]，÷2)
  -> SYSCLK   = 98.304 / (4 x 2) = 12.288 MHz
  ADCDIV=DACDIV=000  ->  fs = 12.288M / 256 = 48.000 kHz
  BCLKDIV     = 0100 (÷4)  ->  BCLK = 3.072 MHz
```

> ⚠️ **SDM 位最容易漏**：R52 的复位默认值是 `0_0000_1000`（SDM=0，整数模式），
> 而手册 Table 45 给出的所有例值都带非零 K —— 也就是说那些例子**必须配 SDM=1**。
> 只抄 K 不设 SDM，PLL 会按整数模式跑，SYSCLK 差一大截。

#### 为什么 `16 位字` 能拆成两个 I2C 字节

WM8960 的 2-wire 协议是 **16 位字**：`[15:9] = 7 位寄存器地址`，`[8:0] = 9 位数据`。

参考工程的 `i2c_control.v` 恰好把高字节放 `addr`、低字节放 `wrdata`：

```verilog
assign addr   = lut[15:8];   // = {reg[6:0], data[8]}  高字节
assign wrdata = lut[7:0];    // = data[7:0]            低字节
```

**9 位数据的高位 `data[8]` 藏在 `addr` 的 bit0 里** —— 一开始我以为 8 位的 `wrdata`
把第 9 位截断了，逐位展开核对后确认**没有截断，设计是对的**。
（这也是为什么 `addr_mode = 1'b0` 时状态机会跳过 `cnt == 2`：只发 3 个字节。）

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
| I2C 从机地址（7 bit） | **0x1A** | WM8960 固定，无地址选择脚 |
| 写地址 / 读地址（8 bit） | **0x34** / 0x35 | 7 bit 左移一位 + R/W |
| 代码里 `device_id` 传什么 | **8'h34** | 就是"7bit<<1 \| W"，directly 发给总线 |
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
