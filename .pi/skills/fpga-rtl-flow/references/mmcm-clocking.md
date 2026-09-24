# MMCM 时钟规划与可达频率计算

## 1. 7 系列 MMCM 的结构

```
CLKIN ──▶ [÷D] ──▶ PFD ──▶ [×M] ──▶ VCO ──┬─▶ [÷O0] ──▶ CLKOUT0
           DIVCLK_       CLKFBOUT_         ├─▶ [÷O1] ──▶ CLKOUT1
           DIVIDE        MULT_F            ├─▶ ...
                                           └─▶ [÷O6] ──▶ CLKOUT6
                    ▲                     │
                    └──── CLKFBOUT ◀──────┘   （必须把某个输出反馈回 CLKFBIN）
```

**可达输出频率：**

```
Fout = Fin × M / (D × O)
VCO  = Fin × M / D          ← 必须落在 600 ~ 1200 MHz
```

| 参数 | 范围 | 步进 |
| --- | --- | --- |
| `DIVCLK_DIVIDE` (D) | 1 ~ 106 | 1 |
| `CLKFBOUT_MULT_F` (M) | 2.000 ~ 64.000 | **0.125** |
| `CLKOUT0_DIVIDE_F` (O0) | 1.000 ~ 128.000 | **0.125** |
| `CLKOUT1..6_DIVIDE` (O1~O6) | 1 ~ 128 | 1 |
| PFD 频率 | 10 ~ 450 MHz | — |
| VCO 频率 | 600 ~ 1200 MHz | — |

## 2. 关键认识：`CLKOUT0_DIVIDE_F` 的 1/8 步进

**这是最容易漏掉、也最决定成败的一点。**

直觉上会认为"输出分频只能是整数"，于是很多频率会被误判为不可达。

> **真实踩坑**：200 MHz → 12.288 MHz。
> `960 / 12.288 = 78.125`。如果只允许整数分频，就永远除不出来，
> 于是误判为"数学上不可能"，改用近似频率（12.288136 MHz，+11 ppm）。
> 后来发现 `CLKOUT0_DIVIDE_F` 支持 0.125 步进，`78.125` 完全合法，
> **精确解一直存在**。

**教训：判断可达性时，必须把 M 和 O0 的小数能力都算进去。**

## 3. 可达性判定（严谨做法）

要精确得到目标频率 `Ft`，需要存在整数 `D` 和满足步进要求的 `M`、`O` 使
`Fin × M / (D × O) = Ft`，且 VCO 在范围内。

写成有理数形式：设 `Fin / Ft = p / q`（p、q 互质），
则需要 `M / (D×O) = q / p`，即 `M = q × D × O / p`。

**`M` 必须是 1/8 的整数倍**，所以 `8 × q × D × O` 必须能被 `p` 整除。

### 实例：200 MHz → 48 kHz 音频时钟链

```
需要 BCLK = 48kHz × 64 = 3.072 MHz
音频域时钟 F 必须是 BCLK 的整数倍（且 BCLK 半周期是整数个 F 周期）
```

- **正确解（精确）**：`D=5, M=24.000, O0=78.125`
  → PFD = 40 MHz，VCO = 960 MHz，F = `960/78.125` = **12.288 MHz** 精确
  → BCLK = 12.288/4 = 3.072 MHz 精确，LRCLK = 48.000 kHz 精确

- **近似解（如果误判不可达时的退路）**：`D=1, M=3.625, O=59`
  → F = 12.288136 MHz，fs = 48000.53 Hz（+11 ppm ≈ 0.4 音分，不可闻）

### 实例：200 MHz → 1080p30 视频时钟

```
像素时钟 74.25 MHz，TMDS 5 倍过采样 = 371.25 MHz
```

- `D=10, M=37.125` → PFD = 20 MHz，VCO = 742.5 MHz
- `O0 = 2` → **371.25 MHz**（TMDS ×5）
- `O1 = 10` → **74.25 MHz**（像素）

两个输出都是整数分频，正好落在 VCO 的整数倍数上，非常干净。

## 4. 一个 MMCM 不能产出的情况

**同一个 VCO 必须同时被所有输出整除。**

12.288 MHz 与 371.25 MHz 的公倍数：
`LCM(12.288, 371.25) ≈ 95 GHz`，远超 600~1200 MHz 的 VCO 范围。

→ **必须用两个 CMT。** XC7A100T 有 6 个 CMT（每个 = 1 MMCM + 1 PLL），够用。

## 5. 枚举脚本（可直接复用）

在决定 MMCM 参数前，先穷举所有可行解，不要靠手算：

```python
# 穷举 Fin -> Ft 的 MMCM 可行解
# 关键：O 允许 1/8 步进（用 o/8 表示），M 允许 1/8 步进（用 m/8 表示）
sols = []
for D in range(1, 107):
    pfd = Fin / D
    if not (10e6 <= pfd <= 450e6):
        continue
    for m in range(16, 513):              # M = m/8, 2.000~64.000
        M = m / 8.0
        vco = pfd * M
        if not (600e6 <= vco <= 1200e6):
            continue
        for o in range(8, 1025):          # O = o/8, 1.000~128.000
            O = o / 8.0
            f = vco / O
            if abs(f - Ft) < Ft * 1e-9:   # 精确命中
                sols.append((vco, f, D, M, O))

# 优先选 VCO 居中（约 800~1000 MHz）、D 小、M 为整数的解
sols.sort(key=lambda s: (abs(s[0] - 900e6), s[2]))
```

**选解优先级：**
1. VCO 尽量居中（远离 600/1200 边界，留工艺/温度余量）
2. M 尽量是整数（少用小数分频，抖动更小）
3. 其他输出也能落到整数分频上（省 CMT）

## 6. 必须实测验证

算完**一定要用 Vivado 实跑**，不要只靠手算：

```tcl
# 例化 MMCME2_BASE 后
foreach c [get_clocks] {
    puts "CLOCK: [get_property NAME $c]  period=[get_property PERIOD $c]"
}
```

实测输出示例（本项目）：

```
CLOCK: clk_audio_raw  period=81.380    → 12.2880 MHz   ✅
CLOCK: clk_sys_raw    period=10.417    → 96.0    MHz
CLOCK: clk_pix_raw    period=13.468    → 74.25   MHz   ✅
CLOCK: clk_pix5_raw   period= 2.694    → 371.25  MHz   ✅
```

综合若报 `0 errors, 0 critical warnings`，说明 MMCM 参数合法。

## 7. 时钟域规划原则

1. **能合并就合并** —— 同一域内不需要任何 CDC，风险最低
2. **采样率相关的域要"数得清"** —— 比如音频域跑 `fs × 256`，
   则每个样本有整数个时钟，时序确定、无需握手
3. **高速串行域独占一个 CMT** —— TMDS 的 5 倍过采样时钟必须和像素时钟同源且相位确定
4. **只用差分输入时钟接 MMCM** —— MRCC/SRCC 脚才有专用时钟布线资源
5. **`locked` 要同步后再用** —— MMCM 的 `RST` 是同步复位，
   且输出时钟在 `locked` 拉高前不稳定，必须等 `locked` 同步两级后再释放内部复位

```verilog
// 正确做法
wire locked;
(* ASYNC_REG = "TRUE" *) reg [2:0] lock_sync;
always @(posedge clk_out or negedge rst_async_n)
    if (!rst_async_n) lock_sync <= 3'b000;
    else              lock_sync <= {lock_sync[1:0], locked};

wire rst_n = lock_sync[2];   // 三个输出时钟稳定后才释放
```

---

## 8. 一个 MMCM 同时出多个频率

MMCM 的 7 个输出计数器（`CLKOUT0~6`）**共用同一个 VCO**，
所以任意两个输出频率必须都是这个 VCO 的整数（或 CLKOUT0 的 1/8 步进）分频。

### 判定方法

要同时得到 `F1` 和 `F2`，必须存在 `VCO ∈ [600, 1200]` 使：

```
VCO / F1 = O1  和  VCO / F2 = O2   都是合法分频
（O1 若是小数，只能放 CLKOUT0；O2 必须是整数 1~128）
```

把两式联立：`VCO = F1·O1 = F2·O2` → **`O2 = (F1/F2)·O1`**。
把 `F1/F2` 化成分数 `p/q`，则 `O1` 必须是 `q` 的倍数。

### 实例：48 MHz + 12.5 MHz

```
48 / 12.5 = 3.84 = 96/25     →  O1 = 48MHz 的分频比必须是 25 的倍数
O1 ∈ [600/48, 1200/48] = [12.5, 25]   →  只能取 12.5 / 18.75 / 25
   O1=12.5  → VCO=600  （卡下边界）
   O1=18.75 → VCO=900  ← 选它
   O1=25    → VCO=1200 （卡上边界）
```

`O1=18.75` 是小数 → 放 `CLKOUT0_DIVIDE_F`；`O2 = 900/12.5 = 72` 整数 → 放 `CLKOUT1_DIVIDE`。

再从输入时钟反推：`VCO = Fin × M / D = 900`，取 `Fin=200, D=4, M=18`（PFD=50 MHz 合法）。

**优先选 VCO 居中的解**（远离 600/1200 两端），jitter 余量最大。

### 什么时候必须用两个 MMCM

当两个频率的比值导致 `O1` 的合法取值区间内**无解**时。典型例子：

```
12.288 MHz 与 371.25 MHz（TMDS ×5）
LCM ≈ 95 GHz >> 1200 MHz  →  无解，必须两个 CMT
```

判断不出来就直接穷举（见 §5 的枚举脚本）。

### 资源代价认知

`MMCME2_BASE` 与 `MMCME2_ADV` 是**同一块硬核**，BASE 只是端口裁剪版。
资源报告里 BASE 会显示成 `MMCME2_ADV`，属正常现象。

XC7A100T 有 **6 个 CMT**（每个 = 1 MMCM + 1 PLL），
所以"多用几个 MMCM"在资源上通常不是问题，**但每多一个就多一份 jitter/CDC 复杂度**，
能用小数分频凑出来就优先凑。
