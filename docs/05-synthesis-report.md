# 05 综合实现报告（实测数据）

> 生成命令：
> ```bash
> vivado -mode batch -source scripts/vivado/build.tcl \
>        -tclargs xc7a100tfgg484-2 audio_top constrs/audio_top.xdc
> ```
> 全部报告在 `build/vivado/` 下，可一键复现。

## 0. 更正记录

本文件早期版本有两处错误，已更正：

| 项 | 错误值 | 正确值 | 影响 |
| --- | --- | --- | --- |
| 器件 | `xc7a100tcsg324-1` | **`xc7a100tfgg484-2`** | 封装 (CSG324→FGG484) 和速度等级 (-1→-2) 都不对，管脚约束会全错 |
| 时钟可达性 | "200 MHz 无法精确产生 48 kHz" | **可以**，见第 2 节 | 当时只枚举了整数输出分频，漏掉 `CLKOUT0_DIVIDE_F` 的 1/8 步进 |

**速度等级 -2 是好消息**：比 -1 快约 20~25%，Fmax 更高、时序更容易收敛。

## 1. 器件与约束

| 项 | 值 |
| --- | --- |
| 器件 | **`xc7a100tfgg484-2`**（XC7A100T-2FGG484**I**，工业级） |
| 顶层 | `audio_top` |
| 综合策略 | 默认（`synth_design`），`-flatten_hierarchy none` 保留层次 |
| 时钟约束 | **10 ns (100 MHz) 过约束**，见第 2.3 节说明 |
| 管脚约束 | 未填写（见 [06-board-resources.md](06-board-resources.md)） |

## 2. 时钟方案（本项目最关键的前置结论）

### 2.1 目标频率

| 时钟域 | 频率 | 用途 | 精度要求 |
| --- | --- | --- | --- |
| `clk_audio` | **12.288 MHz** | 音频 DSP + I2S（= 48 kHz × 256） | **必须精确**，否则采样率有偏差 |
| `clk_sys` | 96 MHz | 控制逻辑（UART / 寄存器 / I2C） | 无 |
| `clk_pix` | **74.25 MHz** | 1080p30 像素时钟 | 必须精确，否则显示器不锁 |
| `clk_pix5` | **371.25 MHz** | TMDS 5 倍过采样（OSERDESE2） | 必须精确 |

### 2.2 MMCM 参数（**已用 Vivado 实跑验证**）

板载唯一时钟源是 **200 MHz 差分**（R4/T4 = `IO_L13P/N_MRCC_34`，MRCC 脚，可直接进 MMCM）。

```
CMT#1  DIVCLK_DIVIDE   = 5        PFD = 200/5 = 40 MHz   (合法范围 10~450 MHz)
       CLKFBOUT_MULT_F = 24.000   VCO = 40 × 24 = 960 MHz (合法范围 600~1200 MHz)
       CLKOUT0_DIVIDE_F= 78.125 → 960 / 78.125 = 12.288 MHz  ← 精确
       CLKOUT1_DIVIDE  = 10     → 960 / 10     = 96 MHz

CMT#2  DIVCLK_DIVIDE   = 10       PFD = 200/10 = 20 MHz
       CLKFBOUT_MULT_F = 37.125   VCO = 20 × 37.125 = 742.5 MHz
       CLKOUT0_DIVIDE  = 2      → 742.5 / 2  = 371.25 MHz  (TMDS ×5)
       CLKOUT1_DIVIDE  = 10     → 742.5 / 10 = 74.25  MHz  (像素)
```

Vivado `report_clocks` 实测读数：

```
clk_audio_raw   period = 81.380 ns  → 12.2880 MHz   ✅ 精确
clk_sys_raw     period = 10.417 ns  → 96.0    MHz
clk_pix_raw     period = 13.468 ns  → 74.25   MHz   ✅ 精确
clk_pix5_raw    period =  2.694 ns  → 371.25  MHz   ✅ 精确
```

综合结果 `0 errors, 0 critical warnings, 0 warnings`。

### 2.3 三个必须知道的结论

**① 为什么能精确：`CLKOUT0_DIVIDE_F` 支持 1/8 步进**

`960 / 78.125 = 12.288` 正好整除。这个 78.125 是唯一关键点——如果只用整数分频，
960/O 永远除不出 12.288（`960/12.288 = 78.125`）。这也是我第一遍判断失误的原因。

**② 一个 MMCM 无法同时产出 12.288 和 371.25**

要让同一个 VCO 同时整除出这两个频率，VCO 必须是它们的公倍数。
`LCM(12.288 MHz, 371.25 MHz) ≈ 95 GHz`，远超 600~1200 MHz 的 VCO 范围。
所以视频域必须独占第二个 CMT。XC7A100T 有 **6 个 CMT**（每个 = 1 MMCM + 1 PLL），够用。

**③ 为什么用 100 MHz 过约束而不是真实频率**

真实音频时钟只有 12.288 MHz（周期 81.4 ns）。若按它约束，时序报告全是正裕量，
**看不出优化空间也定位不到关键路径**。按 100 MHz 约束等价于"请把路径优化到 10 ns 以内"，
报告出的 WNS 直接量化设计离目标有多远，从而反推出真实 Fmax。

## 3. 时序结果（xc7a100tfgg484-2）

| 指标 | 值 |
| --- | --- |
| WNS @100 MHz 约束 | **−6.237 ns** |
| 推算关键路径 | 约 **16.2 ns** |
| 推算 Fmax | 约 **61.6 MHz** |
| 实际需求 | 12.288 MHz |
| **实际时序裕量** | 约 **65 ns（5.0 倍余量）** ✅ |
| 组合环 DRC (LUTLP-1) | **0** ✅ |

> 对比：同一设计在 -1 速度等级上是 WNS = −10.083 ns（Fmax ≈ 49.7 MHz）。
> 换到 -2 后快约 24%，与速度等级的预期一致。

### 关键路径

```
Source      : u_eq_r/sect_reg[0]_rep__0/C
Destination : u_eq_r/st1_reg[2][5]/D
Logic Levels: 23  (CARRY4=15  DSP48E1=2  LUT2=1 LUT3=2 LUT4=1 LUT6=2)
```

**路径解析**：`段号 → 系数 mux → DSP1（x·b0 / x·b1）→ 舍入饱和（15 级 CARRY4）
→ DSP2（y·a1）→ 减法 → 写回状态寄存器`。

两处可优化点（**当前不做**：余量已 5 倍，改动需要重新全量验证）：

1. **打断两级乘法串联**：`yn` 在进入 `a1/a2` 乘法前打一拍。
   代价：延迟 +1 clk（+0.08 µs）；收益：路径砍掉约 6 ns，Fmax → 约 90 MHz。
2. **状态寄存器改用同步复位**：当前 `st1/st2` 用异步复位，Vivado 报 100 条
   `DRC DPOR-1`，导致 DSP48 内部寄存器无法被吸收，额外消耗约 500 个 FF。
   代价：需重新验证复位后首样本行为。

## 4. 资源占用（布线后）

| 资源 | 占用 | 总量 | 占比 |
| --- | --- | --- | --- |
| Slice LUTs | 2494 | 63400 | **3.93 %** |
| Slice Registers | 3027 | 126800 | **2.39 %** |
| DSP48E1 | **10** | 240 | **4.17 %** |
| Block RAM Tile | 0 | 135 | 0 % |

**DSP 数量验证**：2 声道 × 5 个并行乘法器（`b0·x`、`b1·x`、`b2·x`、`a1·y`、`a2·y`）= 10 个，
与设计预期完全一致 —— 印证了"时分复用 section"结构：**DSP 占用与滤波器段数无关**，
加段数只增加周期数，不增加乘法器。

## 5. DRC 结果

| 检查项 | 结果 | 说明 |
| --- | --- | --- |
| LUTLP-1（组合环） | **0 错误** ✅ | 曾命中 `audio_fifo` 的 `wptr_nxt → full → do_wr` 组合环，已修 |
| NSTD-1 / UCIO-1 | Warning（自动降级） | 管脚未分配，补齐 XDC 后降级自动失效 |
| DPOR-1 | 100 条 Warning | DSP 相邻寄存器异步复位，见第 3 节优化点 2 |
| DPIP-1 | Warning | DSP 输入未加流水，同上 |
| CFGBVS-1 | Warning | 需在 XDC 里设 `CFGBVS=VCCO` / `CONFIG_VOLTAGE=3.3` |

> **重要教训**：`audio_fifo` 的组合环在 iverilog 里**恰好收敛**，
> 三条 testbench 全部 PASS，但它是上板后真实的竞争风险。
> **仿真通过 ≠ 设计正确**，综合器的 DRC 必须跑。

## 6. 比特流

`build/vivado/audio_top.bit` 已生成，但**当前不可上板**：
管脚 LOC / IOSTANDARD / CFGBVS / CONFIG_VOLTAGE 都还没填。
补齐 [06-board-resources.md](06-board-resources.md) 里的管脚表后即可直接下载。
