# 10 顶层设计与接口契约

> **这份文档的作用**：冻结模块划分与端口定义。
> 接口一旦冻结，各模块就可以**并行开发**，不用等别人写完。
>
> 状态标记：✅ 已实现并验证 ｜ 🚧 接口已定，待实现 ｜ ❓ 待讨论
>
> **修改流程**：任何端口改动都要先改本文档并说明理由，再改 RTL —— 否则并行开发会互相踩。

---

## 1. 模块层次

```
top（板级顶层：管脚、IBUFDS、MMCM）
│
├── clk_gen                      🚧  200MHz 差分 → 全部时钟 + locked
├── rst_gen                      🚧  各时钟域复位同步
│
├── 【主域 clk_sys = 48 MHz】  ← 音频 + 控制全部跑这里，无跨域
│   ├── uart_rx / uart_tx        🚧  CH340E，调参 + 数据回传
│   ├── cmd_proc                 🚧  命令解析 → 配置寄存器
│   ├── i2c_master               🚧  通用 I2C 主机
│   ├── wm8960_init              ✅  上电配置序列（I2C，20 条寄存器）
│   ├── audio_top                ✅  I2S 收发 + 5 段均衡（阶段一完成）
│   │   ├── i2s_slave_clk        ✅  **替代 i2s_clkgen**（从模式恢复时序）
│   │   ├── i2s_rx / i2s_tx      ✅  接口不变，直接复用
│   │   ├── eq_cascade ×2        ✅
│   │   ├── eq_coeff_rom         ✅
│   │   └── audio_fifo ×2        ✅
│   ├── fft_core                 ✅  1024 点实数 FFT（1004 LUT + 2 BRAM）
│   ├── spectrum                 ✅  512 bin -> 32 柱高（473 LUT）
│   └── spectrum_map             ✅  频率分组表（脚本生成）
│
├── 【显示域 clk_pix = 12.5 MHz】
│   ├── lcd_timing               ✅  480x272 时序（56 LUT / 47 FF）
│   ├── spec_sync                ✅  跨域快照（复用 async_fifo）
│   ├── bg_src                   ✅  背景生成（扩展点①）
│   ├── disp_mix                 ✅  背景 + 频谱柱合成
│   ├── rainbow_rom              ✅  128 级彩虹表（脚本生成）
│   ├── polar_map                ✅  极坐标变换（64 扇区）
│   └── wave_buf                 ✅  波形缓冲（双时钟 BRAM）
│
└── 跨时钟域
    └── spec_dpram               🚧  双口 BRAM：音频域写 / 显示域读
```

**音频通路与显示通路并行**：两者在不同时钟域、用不同硬件资源，
处理上互不阻塞；数据上显示通路单向依赖音频通路（`spectrum` → `overlay`）。

---

## 2. 时钟域规划

**音频链路和控制逻辑合并到一个 48 MHz 域**，理由见下。

| 域 | 频率 | 来源 | 承载 |
| --- | --- | --- | --- |
| `clk_sys` | **48 MHz** | CMT#1 `D=5, M=24.000, O=20`（VCO=960 MHz） | **全部**：I2S、EQ、FFT、频谱、UART、I2C、命令 |
| `clk_pix` | **12.5 MHz** | CMT#2 `D=4, M=15.125, O=60.500`（复用官方例程，已验证） | LCD 时序、Overlay |

### 为什么不是 96 MHz

阶段一综合实测：均衡器关键路径约 **16.2 ns → Fmax ≈ 61.6 MHz**
（-2 速度等级，`docs/05` §3）。

- 96 MHz（周期 10.4 ns）→ **时序不收敛** ❌
- **48 MHz**（周期 20.8 ns）→ 正裕量 **+4.6 ns**，约 22% 余量 ✅

若将来需要更快，把 `yn` 在进 `a1/a2` 乘法前打一拍即可（延迟 +1 clk，Fmax → 约 90 MHz）。

### 为什么合并成一个域

WM8960 做主时，BCLK/LRCLK 与 FPGA 本来就异步，**音频链路跑哪个频率都不能省掉
I2S 边沿恢复**。既然如此，就用一个域跑完，UART/I2C 配置到音频之间**零 CDC**。

### 采样率精度的责任转移

| | FPGA 当主（旧方案） | **WM8960 当主（现方案）** |
| --- | --- | --- |
| 采样率由谁决定 | FPGA 的 200 MHz 晶振 | **模块的 24 MHz 晶振** |
| 精度 | MMCM 精确 48.000 kHz | PLL 精确 48.000 kHz（手册 Table 45） |
| 硬件改动 | 需拆晶振 | **无** |

### 为什么 LCD 不能和 clk_sys 共用一个 MMCM

`48` 与 `12.5` 的公倍数要求 `48a = 12.5b`，即 VCO 必须是 1200 MHz 的公倍数，
正好卡在 MMCM VCO 上限。**不值得冒险，独占 CMT#2 即可**（共 6 个 CMT）。

详见 [06](06-board-resources.md) §9.3、[05](05-synthesis-report.md) §2。

---

## 3. 复位策略

```
rst_async_n = sys_rst_n（R14 按键，低有效） & mmcm_locked

每个时钟域各一个 rst_sync：
    rst_n_sys    ← rst_async_n, clk_sys   (48 MHz)
    rst_n_pix    ← rst_async_n, clk_pix   (12.5 MHz)
```

**规则**：
1. 所有 `always @(posedge clk)` 用**本域**的 `rst_n`
2. 异步复位、同步释放（`rst_sync` 已实现）
3. **等 `locked` 之后再释放复位** —— MMCM 输出在锁定前不稳定
4. 不用复位的地方（如 FIFO 数据路径）就不加，省资源

---

## 4. 接口契约

### 4.1 `clk_gen` 🚧

```verilog
module clk_gen (
    input  wire clk_200m_p,      // R4  IO_L13P_MRCC_34
    input  wire clk_200m_n,      // T4  IO_L13N_MRCC_34
    output wire clk_sys,         // 48 MHz
    output wire clk_pix,         // 12.5 MHz
    output wire mmcm_locked
);
```

| 端口 | 方向 | 位宽 | 说明 |
| --- | --- | --- | --- |
| `clk_200m_p/n` | in | 1 | `IBUFDS`，**`IOSTANDARD DIFF_SSTL15`** |
| `clk_sys` | out | 1 | CMT#1 CLKOUT0，`BUFG` 输出 |
| `clk_pix` | out | 1 | CMT#2 CLKOUT0，`BUFG` 输出 |
| `mmcm_locked` | out | 1 | 两个 MMCM `LOCKED` 相与 |

**不用引出 `clk_200m`**（只有 MMCM 用），省一个 BUFG。

**MMCM 参数**（**一个 MMCM 同时出两路**，已用 Vivado 综合+布局布线验证）：

```verilog
MMCME2_BASE #(
    .CLKIN1_PERIOD      (5.000),    // 200 MHz
    .DIVCLK_DIVIDE      (4),        // PFD = 50 MHz
    .CLKFBOUT_MULT_F    (18.000),   // VCO = 900 MHz   ← 居中，远离 600/1200 边界
    .CLKOUT0_DIVIDE_F   (18.750),   // 900/18.75 = 48   MHz
    .CLKOUT1_DIVIDE     (72)        // 900/72    = 12.5 MHz
) u_mmcm (...);
```

Vivado `report_clocks` 实测：

```
CLK clk_200m       period =  5.000 ns  → 200    MHz
CLK clkfb          period = 20.000 ns  →  50    MHz (PFD)
CLK clk_sys_raw    period = 20.833 ns  →  48.0  MHz  ✅
CLK clk_pix_raw    period = 80.000 ns  →  12.50 MHz  ✅
```

### 怎么算「一个 VCO 能不能同时出两个频率」

MMCM 的 7 个输出计数器**共用同一个 VCO**，所以两个频率必须都是它的分频：

```
VCO = 48 × O_sys = 12.5 × O_pix   →   O_pix = 3.84 × O_sys
```

`3.84 = 96/25`，所以 `O_sys` 必须是 `6.25` 的倍数。VCO 落在 `[600, 1200]` 内只有三个解：

| `O_sys` | VCO | `O_pix` | 评价 |
| --- | --- | --- | --- |
| 12.5 | 600 MHz | 48 | 卡 VCO 下边界 ❌ |
| **18.75** | **900 MHz** | **72** | ✅ **居中，jitter 余量最好** |
| 25 | 1200 MHz | 96 | 卡 VCO 上边界 ❌ |

`18.75` 是小数 → 只能放 `CLKOUT0_DIVIDE_F`（唯一支持 1/8 步进的输出）；
`72` 是整数 → 放 `CLKOUT1_DIVIDE`。

再从 200 MHz 反推 VCO：`200 × M/D = 900` → `M/D = 4.5`，取 `D=4, M=18`（PFD = 50 MHz 合法）。

> **这比用两个 MMCM 更好**：省一个 CMT，VCO 居中，两路时钟同源、相位确定。

**实现要点（已实现并验证，见 `rtl/common/clk_gen.v`）：**

1. `IBUFDS` 把差分转单端，`DIFF_TERM("FALSE")`、`IBUF_LOW_PWR("FALSE")`
2. `CLKFBOUT` 自反馈到 `CLKFBIN`（**不是** `CLKOUTB`）
3. 两路输出各过一个 `BUFG`（MMCM 输出不能直接当时钟用）
4. `RST` 接按键（MMCM 的 RST 是同步复位，官方 Clocking Wizard 也是直接接异步复位）
5. 不引出 `clk_200m` —— 只有 MMCM 用，省一个 BUFG

**资源占用实测：LUT 0 / FF 0 / DSP 0 / BRAM 0 / BUFG 2 / MMCM 1**

> 注：`MMCME2_BASE` 在资源报告里会显示成 `MMCME2_ADV` ——
> 两者是**同一块硬核**，BASE 只是端口裁剪版，不要以为是综合器搞错了。

### 验证记录（✅ 两个闭环都已完成）

**① 综合 + 布局 + 布线 + DRC**（`xc7a100tfgg484-2`）

```
CLK clk_200m    period =  5.000 ns  → 200    MHz
CLK clkfb       period = 20.000 ns  →  50    MHz (PFD)
CLK clk_sys_raw period = 20.833 ns  →  48.0  MHz  ✅
CLK clk_pix_raw period = 80.000 ns  →  12.50 MHz  ✅
DRC：只有 NSTD-1/UCIO-1（顶层未定，管脚未约束），零告警
```

**② 仿真**（`sim/tb/tb_clk_gen.v`，xsim）

> ⚠️ **`clk_gen` 不能用 iverilog 仿真** —— 内部例化了 `IBUFDS` /
> `MMCME2_BASE` / `BUFG`，iverilog 没有这些原语的行为模型。
> 必须用 `bash scripts/sim/run_xsim.sh` 或 Vivado GUI。
> 这是两条仿真流程的分工边界：**纯 RTL 走 iverilog，含原语的走 xsim**。

```
[47.5 ns]   释放复位
[1257.5 ns] MMCM 已锁定（等待 242 个 200MHz 周期）
clk_sys : 4800 周期 / 100us -> 48.0000 MHz   ✅
clk_pix : 1250 周期 / 100us -> 12.5000 MHz   ✅
结果 : *** PASS ***
```

**测量方法说明**：TB 在固定时间窗（100 µs）内**数上升沿个数**，
比在波形窗口用光标量周期可靠得多。
（另注：xsim 的 `%t` 按仿真精度 ps 打印，TB 里用 `$realtime` 避免把
`1258000` 误读成 1.258 ms —— 实际是 1258 ns。）

**GUI 仿真注意**：Vivado 默认 `run 1000ns` 太短（MMCM 要 1257.5 ns 才锁），
需要点 **Run All**，或设置
`set_property -name {xsim.simulate.runtime} -value {1000us} -objects [get_filesets sim_1]`。

---

### 4.1b `i2s_slave_clk` 🚧（替代 `i2s_clkgen`）

```verilog
module i2s_slave_clk #(
    parameter integer SLOT = 32
) (
    input  wire clk,             // clk_sys = 48 MHz
    input  wire rst_n,
    input  wire bclk_i,          // 来自 WM8960（3.072 MHz）
    input  wire lrclk_i,         // 来自 WM8960（48 kHz）
    // ↓↓↓ 输出与 i2s_clkgen 完全一致，所以下游模块零改动
    output reg  bclk_rise,
    output reg  bclk_fall,
    output wire frame_start,
    output wire half_start,
    output wire [5:0] bit_idx,
    output wire sample_stb
);
```

**实现要点：**

1. `bclk_i` / `lrclk_i` 各过 **2 级同步器**（`cdc_sync`）—— 它们与 `clk` 异步
2. 边沿检测：`bclk_rise = bclk_s & ~bclk_s_d`，`bclk_fall = ~bclk_s & bclk_s_d`
3. 位计数器 `bcnt` 在 `bclk_fall` 递增（0~2*SLOT-1），在 `frame_start` 归零
4. `lrclk` 也过同步器，用 `lrclk` 的跳变确定帧边界

**过采样余量**：`48 MHz / 3.072 MHz = 15.6 倍`。
BCLK 半周期 ≈ 7.8 个 `clk_sys` —— 边沿检测和建立时间都绰绰有余。

> ⚠️ **不要照抄 `i2s_clkgen` 的 `DIV` 分频逻辑** —— 从模式下时钟是输入，
> 只是"恢复"出来，不存在分频。这是最容易犯的错。

---

### 4.2 `rst_gen` 🚧

```verilog
module rst_gen (
    input  wire clk,             // 目标时钟域
    input  wire rst_async_n,     // 异步复位源
    output wire rst_n            // 本域同步释放后的复位
);
```

内部直接例化 `rtl/common/rst_sync.v`。三个域各例化一次。

---

### 4.3 `uart_rx` / `uart_tx` 🚧

```verilog
module uart_rx #(parameter integer CLK_FREQ = 96_000_000,
                 parameter integer BAUD     = 115_200) (
    input  wire       clk, rst_n,
    input  wire       rxd,
    output reg  [7:0] data,
    output reg        valid       // 收完一字节给 1 拍
);

module uart_tx #(parameter integer CLK_FREQ = 96_000_000,
                 parameter integer BAUD     = 115_200) (
    input  wire       clk, rst_n,
    input  wire [7:0] data,
    input  wire       send,       // 1 拍脉冲
    output reg        txd,
    output wire       ready       // 空闲可发
);
```

8N1。`CLK_FREQ/BAUD = 833`（96 MHz / 115200），分频器 16 位足够。

---

### 4.4 `i2c_master` 🚧

```verilog
module i2c_master #(parameter integer CLK_FREQ = 96_000_000,
                    parameter integer SCL_FREQ = 100_000) (
    input  wire        clk, rst_n,
    // 命令接口
    input  wire        start,        // 1 拍脉冲启动
    input  wire        rw,           // 0=写 1=读
    input  wire [6:0]  dev_addr,     // 7bit 从机地址
    input  wire [15:0] wdata,        // 要写的 16bit（见下方说明）
    input  wire [7:0]  reg_addr,     // 读操作的寄存器地址
    // 状态
    output reg         busy,
    output reg         done,         // 1 拍脉冲
    output reg         ack_error,
    output reg  [15:0] rdata
);
```

> ⚠️ **WM8960 的写格式和常见 I2C 器件不同**：
> 不是「寄存器地址 1 字节 + 数据 1 字节」，而是**两个字节组成一个 16bit 字**：
> **高 7 位 = 寄存器地址，低 9 位 = 数据**。
> 所以 `wdata[15:0]` 就是打包好的那个字，`i2c_master` 只负责把它当 2 字节发出去。
> 打包在 `wm8960_init` 里做，`i2c_master` 保持通用。
> **写 RTL 前务必核对 datasheet Page 15/63。**

---

### 4.5 `wm8960_init` 🚧

```verilog
module wm8960_init (
    input  wire       clk, rst_n,
    input  wire       start,        // 上电后 1 拍脉冲
    input  wire [2:0] volume,       // 0~7 音量档
    // 接 i2c_master
    output reg        i2c_start,
    output reg        i2c_rw,
    output reg  [6:0] i2c_dev,
    output reg  [15:0] i2c_wdata,
    input  wire       i2c_busy,
    input  wire       i2c_done,
    input  wire       i2c_ack_err,
    output reg        done
);
```

内部是一条 ROM（寄存器地址 + 数据），上电后按顺序写完 → 拉高 `done`。

**最小可用配置序列**（待上板调试时细化）：

| 步骤 | 目的 |
| --- | --- |
| 1 | 复位 + 软上电 |
| 2 | 时钟配置：MCLK = 12.288 MHz 直接作 SYSCLK（不用 PLL） |
| 3 | 音频接口：I2S 从模式、24bit、BCLK/LRCLK 输入 |
| 4 | ADC 使能 + 输入通道（LINE IN） |
| 5 | DAC 使能 + 输出通道 |
| 6 | 耳机 / 喇叭音量 + 使能 |
| 7 | 解除静音 |

---

### 4.6 `cmd_proc` 🚧

```verilog
module cmd_proc (
    input  wire        clk, rst_n,          // clk_sys
    // 从 uart_rx
    input  wire [7:0]  rx_data,
    input  wire        rx_valid,
    // 到 uart_tx
    output reg  [7:0]  tx_data,
    output reg         tx_valid,
    input  wire        tx_ready,
    // 配置输出（都同步到 clk_sys，跨域由 cdc 处理）
    output reg  [24:0] band_gain,           // 5 段 × 5bit 档位
    output reg  [7:0]  volume,              // 数字音量
    output reg         eq_bypass,
    output reg         cfg_load,            // 1 拍脉冲
    // 状态回读（从音频域同步过来）
    input  wire [7:0]  status_peaks,        // 8 段峰值（可选）
    input  wire        audio_running
);
```

**极简命令协议**（ASCII，串口助手直接敲）：

| 命令 | 含义 |
| --- | --- |
| `B<b><nn>\n` | 设置第 b 段（0~4）增益档位 nn（00~20，对应 −10~+10 dB） |
| `V<nn>\n` | 设置数字音量 |
| `P\n` | 打印当前 5 段增益 |
| `Y\n` | 切换 EQ 直通 |

> 先用最简单的 ASCII 协议跑通，后续可换二进制帧。

---

### 4.7 `audio_top` ✅（需小幅扩展）

现有接口（已实现）：

```verilog
module audio_top #(...) (
    input  wire clk, rst_n,                 // clk_audio
    output wire bclk, lrclk,
    input  wire sdin,
    output wire sdout,
    input  wire [24:0] band_gain,
    input  wire cfg_load, bypass,
    output wire cfg_busy, running,
    output wire dbg_bclk_rise, dbg_bclk_fall, dbg_frame_start,
    output wire dbg_half_start, output wire [5:0] dbg_bit_idx, dbg_sample_stb
);
```

**待扩展**（🚧）：

| 新增端口 | 方向 | 说明 |
| --- | --- | --- |
| `volume[7:0]` | in | 数字总音量（Q1.7，1.0 = 128） |
| `spec_l` / `spec_r` + `spec_valid` | out | 送往 FFT 的音频抽头 |

> **抽头位置**：应该取**均衡后、音量前**的信号（显示的是"处理后的频谱"），
> 还是**均衡前**的（显示"原始频谱"）？—— **待定**，建议先取均衡后。

---

### 4.8 `fft_core` ✅ **已实现并验证**

```verilog
module fft_core #(
    parameter integer N          = 1024,
    parameter integer LOG2N      = 10,
    parameter integer DW         = 24,       // 数据 Q1.23
    parameter integer TW         = 16,       // 旋转因子 Q1.15
    parameter integer FIFO_DEPTH = 64        // 内部输入 FIFO
) (
    input  wire                  clk, rst_n, // clk_sys = 48 MHz
    input  wire signed [DW-1:0]  x_in,       // 实数样本
    input  wire                  x_valid,
    output reg  [LOG2N-2:0]      y_index,    // 0 ~ N/2-1
    output reg  [DW:0]           y_mag,      // 幅度（近似）
    output reg                   y_valid,
    output wire                  busy,
    output reg  [7:0]            drop_cnt    // FIFO 溢出计数（诊断用，应恒为 0）
);
```

| 项 | 规格 |
| --- | --- |
| 结构 | 基 2 DIT，**单蝶形时分复用**，in-place，真双口 BRAM |
| 定点 | 数据 Q1.23，旋转因子 Q1.15，每级 ÷2 缩放（共 ÷N） |
| 幅度 | `max + 0.4375·min` 近似（不开方），最大误差 **+0.75 dB**（永远偏高） |
| 实测耗时 | **10,756 clk / 帧**（RUN 10,240 + OUT 513）→ 占帧时间 **1.05%** |
| 实测资源 | **1004 LUT / 126 FF / 2 BRAM36 / 4 DSP48** |
| 时序 | WNS **+2.54 ns** / WHS +0.06 ns @ 48 MHz（路径 17.83 ns，32 级逻辑） |
| 验证 | 4 组测试 x 512 频点 = **2048 个输出逐位一致** |

**内部已包含输入 FIFO** —— 因为 RUN+OUT 期间 BRAM 被独占，
约 11 个样本进不来，需要 FIFO 兜住（详见 [11-fft-design.md](11-fft-design.md) §7）。

> 详细设计推导、地址发生器原理、实施踩坑见 [11-fft-design.md](11-fft-design.md)。

---

### 4.9 `spectrum` 🚧

```verilog
module spectrum (
    input  wire        clk, rst_n,           // clk_audio
    input  wire        y_valid,
    input  wire [8:0]  y_index,
    input  wire signed [16:0] y_re, y_im,
    output reg  [7:0]  bars [0:31],          // 32 根柱高 0~255（汇总输出）
    output reg         bars_valid            // 一帧完成时 1 拍
);
```

职责：
1. 512 个复数点按对数频率分到 32 组（低频密、高频疏）
2. 每组取模 → `sqrt(re²+im²)`（用 `CORDIC` 或近似 `max+0.5min`）
3. 转 dB（查表近似）→ 映射到 0~255
4. 加峰值保持（缓慢衰减）

---

### 4.10 `spec_dpram` 🚧（跨时钟域）

```verilog
module spec_dpram (
    input  wire        clk_wr, rst_n_wr,     // clk_audio
    input  wire        we,
    input  wire [4:0]  addr_wr,
    input  wire [7:0]  din,
    input  wire        clk_rd, rst_n_rd,     // clk_pix
    input  wire [4:0]  addr_rd,
    output reg  [7:0]  dout
);
```

32 × 8bit 双口 BRAM。音频域写、显示域读。

**同步保证**：显示域在每帧起始（`frame_start`）时锁存一份快照，
避免读到写一半的数据（撕裂）。软件上等价于"双缓冲"—— 数据量只有 32 字节，
直接读两次比对也可以。

---

### 4.11 `lcd_timing` ✅ **已实现并验证**

```verilog
module lcd_timing #(
    parameter integer H_SYNC=41, H_BACK=2, H_DISP=480, H_FRONT=2,
    parameter integer V_SYNC=10, V_BACK=2, V_DISP=272, V_FRONT=2,
    // 计数器位宽必须写在参数表里 —— 端口位宽要在解析模块头时就确定，
    // 而 localparam 在它后面。Verilog-2001 允许后面的 parameter 引用前面的。
    parameter integer HW = $clog2(H_SYNC+H_BACK+H_DISP+H_FRONT),
    parameter integer VW = $clog2(V_SYNC+V_BACK+V_DISP+V_FRONT)
) (
    input  wire             clk, rst_n,      // clk_pix = 12.5 MHz
    input  wire [23:0]      rgb_in,          // 调用方按【当拍】x/y 算出的颜色
    output reg  [23:0]      rgb_out,         // 与 hsync/vsync/de 严格同拍
    output reg              hsync, vsync,    // 低有效
    output reg              de,              // 有效像素区（不引出到管脚）
    output wire [HW-1:0]    x,               // 当前扫描位置（组合输出）
    output wire [VW-1:0]    y,
    output reg              sof              // 帧起始，1 拍脉冲
);
```

> **不需要 DE 输出脚** —— 子卡把 `LCD_DE` 用 0 欧姆电阻硬件拉高了
> （见 [06](06-board-resources.md) §9.5）。`de` 只作为内部"当前像素有效"的信号给上层用。

**⚠️ 时序契约（写上层逻辑时必须记住）**

```
周期 T   : x / y = 当前扫描位置（组合），调用方据此算 rgb_in
周期 T+1 : de / hsync / vsync / rgb_out 一起寄存输出
           rgb_out = rgb_in(T)，即【上一拍 x/y 对应的颜色】
```

也就是 **`de` 与 `x` 天然差一拍** —— 这是刻意的：调用方需要当拍的 x/y
才来得及算颜色，而送到屏幕的一组信号必须互相严格对齐。对应关系是
`de`(T+1) ↔ `x`(T) ↔ `rgb_out`(T+1)，**不是** `de` ↔ `x`。

---

### 4.12 `overlay` 🚧

```verilog
module overlay (
    input  wire        clk, rst_n,           // clk_pix
    input  wire [10:0] xpos, ypos,
    input  wire        de,
    input  wire [7:0]  bars [0:31],          // 来自 spec_dpram
    input  wire [23:0] video_in,             // 底层画面（先接彩条生成器）
    output reg  [23:0] video_out
);
```

规则（待细化）：
- 背景：底下是彩条 / 网格
- 频谱条区域：屏幕下方 1/4
- 每根柱：宽度 = 屏幕宽 / 40，间隔 1px
- 柱色：按高度做彩虹渐变（低=绿，中=黄，高=红）
- 边框 + 峰值横线

---

## 5. 延迟预算

| 级 | 时钟数 | 时间 |
| --- | --- | --- |
| I2S 收帧 → FIFO 写 | 1 | 0.08 µs |
| FIFO 读 → EQ 处理 | 6 | 0.49 µs |
| EQ → FIFO → TX 装载 | 2 | 0.16 µs |
| **音频端到端** | **≈ 9 clk** | **0.73 µs** |
| FFT 分帧（1024 点） | 24576 | **21.3 ms** |
| FFT 运算 | ≈ 28000 | 2.3 ms |
| 显示帧周期 | — | 12 ms |
| **音频 → 屏幕更新** | — | **≈ 35 ms** |

> 35 ms 的"音频到画面"延迟在视觉上完全可接受（人眼对画面滞后声音的容忍度约 ±20~40 ms）。
> **这个数字要写进报告，并说明是"算法固有延迟"而不是实现问题。**

---

## 6. 资源预算（XC7A100T：240 DSP / 135 BRAM36 / 63400 LUT）

| 模块 | LUT | FF | DSP | BRAM |
| --- | --- | --- | --- | --- |
| clk_gen + rst_gen | 0 | 80 | 0 | 0 |
| audio_top（**已实测**） | **2494** | **3027** | **10** | 0 |
| uart ×2 | 200 | 250 | 0 | 0 |
| cmd_proc | 500 | 600 | 0 | 0 |
| i2c_master + wm8960_init | 400 | 500 | 0 | 0 |
| fft_core | 800 | 1200 | 4 | 2 |
| spectrum | 400 | 300 | 0 | 1 |
| lcd_timing | 200 | 150 | 0 | 0 |
| overlay | 600 | 400 | 2 | 2 |
| **合计** | **≈ 5600 (8.8%)** | **≈ 6500 (5.1%)** | **16 (6.7%)** | **5 (3.7%)** |

**余量充足**，HDMI（TMDS 编码 + OSERDES）再加进来也够。

---

## 7. 待讨论的开放问题

| # | 问题 | 选项 | 建议 |
| --- | --- | --- | --- |
| 1 | FFT 抽头取均衡前还是均衡后 | 前 / 后 | **均衡后**（显示"处理效果"更有说服力） |
| 2 | 数字总音量做不做 | 做 / 不做 | **先不做**，音量交给 WM8960 的模拟寄存器，避免位宽损失 |
| 3 | 控制接口用 UART 还是按键 | UART / 按键 / 都要 | **UART 为主**（可实时调 5 段），按键做备用 |
| 4 | 底层画面来源 | 生成式 / 摄像头 | **先生成式**（彩条+网格），DVP 走通后再加摄像头 |
| 5 | 输出用 LCD 还是 HDMI | LCD / HDMI / 都做 | **先 LCD**（简单一个数量级），HDMI 为加分项 |
| 6 | 频谱条更新率 | 每帧 / 隔帧 | 每帧（46.9 Hz 更新，视觉上流畅） |

---

## 8. 开发顺序（依赖图）

```
                 ┌─────────────────────────────────────┐
第 1 步 ★        │ clk_gen + rst_gen + 顶层骨架 + LED   │  ← 唯一需要先做且阻塞一切的
                 └────────────────┬────────────────────┘
                                  │
        ┌──────────────┬──────────┴──────────┬─────────────────┐
        ▼              ▼                     ▼                 ▼
第 2 步 i2c_master    uart_rx/tx        fft_core          lcd_timing
        │              │                     │                 │
        ▼              ▼                     ▼                 ▼
第 3 步 wm8960_init   cmd_proc          spectrum          overlay
        │              │                     │                 │
        └──────────────┴─────────┬───────────┘                 │
                                 ▼                             │
第 4 步                    audio_top 扩展 + spec_dpram  ◀───────┘
                                 │
                                 ▼
第 5 步                          top 整合 + 上板联调
```

**第 2 步的四个模块完全独立，可以并行开发。** 三个模块都可以纯仿真验证：

| 模块 | 验证方法 | 需要上板吗 |
| --- | --- | --- |
| `i2c_master` | TB 里写一个 AT24C64 从机模型 | ❌ |
| `uart_rx/tx` | TB 里写一个 UART 对端模型 | ❌ |
| `fft_core` | 与 `numpy.fft.rfft` 逐点对拍 | ❌ |
| `lcd_timing` | TB 检查行/场计数与 HS/VS 相位 | ❌ |

**第 1 步完成后，第 2 步的四个可以同时开工。**

---

## 9. 验收标准（每个模块通用）

- [ ] 端口与本文档 §4 完全一致（名字、位宽、方向）
- [ ] 有独立的 testbench，且**能跑失败场景**（不是只测 happy path）
- [ ] 仿真默认关闭波形（`$test$plusargs("novcd")`）
- [ ] 加入 `scripts/sim/run_iv.sh` 的测试列表
- [ ] Vivado 综合无 `LUTLP-1`（组合环）
- [ ] 资源占用与 §6 预算量级一致
- [ ] 接口若与本文档不符，先改文档再改代码


---

## 整机集成结果（已跑完整实现 ✅）

```bash
vivado -mode batch -source scripts/vivado/build.tcl -tclargs xc7a100tfgg484-2 top constrs
```

| 项 | 实测 |
| --- | --- |
| **WNS** | **+0.581 ns** |
| **WHS** | **+0.082 ns** |
| WPWS | +1.100 ns |
| TNS | 0（无失败端点） |
| Slice LUTs | **4211 / 63400（6.64%）** |
| Slice Registers | 3159 / 126800（2.49%） |
| Block RAM | 2 / 135（1.48%） |
| DSP48 | 14 / 240（5.83%） |
| MMCM / BUFG | 1 / 2 |
| Bonded IOB | 38 / 285 |
| 比特流 | `build/vivado/top.bit`（1230 KB） |
| CDC | 183 + 3 端点，**Safe 全部安全、Unsafe = 0、缺 ASYNC_REG = 0** |

**资源占用非常宽裕**（LUT 不到 7%），留给极坐标视图、按键交互、背景图绰绰有余。

### ⚠️ 整机集成暴露的两件事

**① 缺异步时钟组声明 → 假的时序违例**

第一次实现报 `WNS = -1.497 ns / TNS = -249 ns`，
但那条"关键路径"的 `Requirement` 只有 **0.833 ns** ——
因为 XDC 里没有 `set_clock_groups -asynchronous`，
Vivado 把 clk_sys↔clk_pix 的跨域路径按同步关系硬算。

补上 `constrs/clocks.xdc` 后：**WNS -1.497 → +0.581 ns，TNS -249 → 0** ✓

> 这条路径本来就不需要算 —— 跨域全靠 `async_fifo` 的格雷码指针保证。
> **和第 26 条同类：先看清工具到底在算什么。**

**② `eq_cascade` 的异步复位阻止 DSP 寄存器合并（DPOR-1 × 180）**

DSP48 内部的输出寄存器只有同步复位能力，带异步复位的下游寄存器无法并入，
白占 LUT/FF 且恶化时序。这与 `fft_core` / `audio_fifo` 踩过的是**同一个根因**。

当前时序已收敛，属于优化项，暂不改。
