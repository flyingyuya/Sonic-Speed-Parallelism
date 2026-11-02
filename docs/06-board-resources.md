# 06 PA-Starlite 板级资源清单与管脚规划

> **数据来源**：`docs/璞致FPGA核心开发版/璞致 Artix-7系列 之PA-Starlite开发板用户手册.pdf`
> 与 `04.硬件相关/01.原理图/Puzhi PA-StarLite Schematic.pdf`
>
> ✅ **52 条引脚映射已用 Vivado 器件数据库逐条核对**（`xc7a100tfgg484-2`），
除 `HDMI_CEC` 一条外全部正确。核对方法见本文件末尾 §13。

⚠️ 原理图 PDF 是多栏排版，`pdftotext` 提取会串列，**不能作为管脚来源**。
正确做法：**把 PDF 渲染成 PNG 直接读图**（`pdftoppm -png -r 150`）。

---

## 1. 主控芯片

| 项 | 值 |
| --- | --- |
| 型号 | XC7A100T-**2**FGG484**I** |
| Vivado PART | **`xc7a100tfgg484-2`** |
| 封装 | FGG484（484 脚 BGA） |
| 速度等级 | **-2**（工业级温度） |
| LUT / FF / DSP / BRAM | 63400 / 126800 / 240 / 135 |
| CMT 数量 | 6（每个 = 1 MMCM + 1 PLL） |

> 同系列还有 PA35T / PA75T / PA200T，除 PA35T 无 MIPI 外**管脚完全兼容**。

## 2. 时钟（**唯一时钟源**）

| 信号 | 管脚名 | 位置 | 说明 |
| --- | --- | --- | --- |
| `CLK_200M_P` | `IO_L13P_MRCC_34` | **R4** | 200 MHz 差分 |
| `CLK_200M_N` | `IO_L13N_MRCC_34` | **T4** | MRCC 脚 → 可直接驱动 MMCM |

**IOSTANDARD（来自官方例程 XDC，已实测可用）**：

```tcl
set_property -dict {PACKAGE_PIN R4 IOSTANDARD DIFF_SSTL15} [get_ports sys_clk_p]
```

- 是 **`DIFF_SSTL15`（1.5V SSTL 差分）**，**不是 LVDS** ——
  因为 bank 34 是 DDR3 的 bank，Vcco = 1.5V，LVDS_25 在这里不可用
- N 端（T4）**不需要写 PACKAGE_PIN**，Vivado 会从 P 端自动推导差分对
- `DIFF_SSTL15` 通常依赖 DCI 端接或板载 100Ω，**直接照抄官方写法即可**

**板上没有第二个晶振。** 所有时钟必须由这一路 200 MHz 经 MMCM 派生
（`clk_audio` / `clk_sys` / `clk_pix` / `clk_pix5`，参数见 [05-synthesis-report.md](05-synthesis-report.md) §2）。

> 注：以太网 PHY（RTL8211FD）自带 25 MHz 晶振 Y2，但那颗晶振接在 PHY 上，不接 FPGA。

## 3. 复位 / 按键 / LED

| 信号 | 管脚名 | 位置 | 有效电平 |
| --- | --- | --- | --- |
| `RST_N`（复位按键） | `IO_L19N_14` | R14 | 按下 = 低 |
| `KEY1` | `IO_L7P_14` | W21 | 按下 = 低 |
| `KEY2` | `IO_L9P_14` | Y21 | 按下 = 低 |
| `LED1` | `IO_L7N_T1_D10_14` | **W22** | 高 = 亮 |
| `LED2` | `IO_L9N_T1_DQS_D13_14` | **Y22** | 高 = 亮 |

> ✅ **W22 冲突已解决**：手册 §3.11 把 `HDMI_CEC` 也标成 W22，是**笔误**。
> Vivado 器件数据库核实：`W22 = IO_L7N_T1_D10_14`（LED1），
> `HDMI_CEC = IO_L18P_T2_A12_D28_14 = **U17**`。

## 4. UART（控制接口，**必用**）

| 信号 | 管脚名 | 位置 | 说明 |
| --- | --- | --- | --- |
| `UART_TX`（FPGA→PC） | `IO_L22P_14` | P15 | CH340E，3.3V |
| `UART_RX`（PC→FPGA） | `IO_L19P_14` | P14 | |

用途：5 段均衡器增益实时调参、频谱数据回传、ILA 之外的自建调试通道。

## 5. I2C（板载 EEPROM，**拿来练手的神器**）

| 信号 | 管脚名 | 位置 | 说明 |
| --- | --- | --- | --- |
| `E2PROM_I2C_SCL` | `IO_L23P_14` | N13 | AT24C64D，读地址 0xA1 / 写地址 0xA0 |
| `E2PROM_I2C_SDA` | `IO_L23N_14` | N14 | |

> **为什么重要**：音频 codec（WM8960 / ES8388 等）上电后**必须通过 I2C 写寄存器才能出声**。
> 板载 EEPROM 是一个已经焊好、有确定器件地址的 I2C 从机 ——
> **用它在板上把 I2C master 调通，再去接音频模块**，可以完全排除"是 I2C 写错还是模块没接好"的扯皮。

## 6. HDMI 输出 ✅ **已按原理图逐条核实**

数据来源：`docs/璞致FPGA核心开发版/04.硬件相关/01.原理图/Puzhi PA-StarLite Schematic.pdf`
**第 14 页「PA-StarLite – HDMI OUT」**（渲染成图后直接读，不是 PDF 文本提取）。

### 6.1 管脚表

| 信号 | FPGA 管脚 | 说明 |
| --- | --- | --- |
| `HDMI_CLK_P` | **Y18** | `IO_L13P_14` |
| `HDMI_CLK_N` | **Y19** | `IO_L13N_14` |
| `HDMI_DATA0_P` | **V18** | `IO_L14P_14` |
| `HDMI_DATA0_N` | **V19** | `IO_L14N_14` |
| `HDMI_DATA1_P` | **AA19** | `IO_L15P_14` |
| `HDMI_DATA1_N` | **AB20** | `IO_L15N_14` |
| `HDMI_DATA2_P` | **V17** | `IO_L16P_14` |
| `HDMI_DATA2_N` | **W17** | `IO_L16N_14` |
| `HDMI_I2C_SDA` | **U20** | DDC 数据 |
| `HDMI_I2C_SCL` | **T21** | DDC 时钟 |
| `HDMI_HPD` | **V20** | 热插拔检测 |
| `HDMI_OUT_EN` | **V22** | 经 `NC7SZ125` 缓冲的 OE（原理图第 14 页） |
| `HDMI_CEC` | ⚠️ **有冲突，见 6.3** | |

### 6.2 电气结构（重要：**直连差分对，没有发送芯片**）

```
FPGA 差分对 ──[51Ω 串阻]──▶ HDMI 连接器 J5
```

**没有 HDMI 发送芯片**（不像有些板子用 ADV7511 之类）✓
所以 TMDS 编码 + 串行化必须**在 FPGA 里做**：

| 需求 | 纯 RTL 实现 |
| --- | --- |
| TMDS 8b/10b 编码 | 纯组合逻辑（XOR/XNOR 链 + DC 平衡），约 150 LUT/通道 ✓ 可手写 |
| 5:1 串行化 | `OSERDESE2`（**器件原语**，和 `MMCME2_BASE`/`IBUFDS` 同一类，不是 IP 核） |
| 差分输出 | `OBUFDS` |
| 输出使能 | `HDMI_OUT_EN`（**V22**）需要驱动 |

> **只需要做 TMDS（不要 CEC / 音频通道 / HDCP / InfoFrame）= DVI 输出** ✓
> HDMI 显示器的 DVI 兼容模式都接受 ✓ 大幅简化 ✓

### 6.3 ⚠️ `HDMI_CEC` 的管脚冲突（原理图自身矛盾）

| 出处 | 声称 |
| --- | --- |
| 原理图 **第 14 页**（HDMI OUT） | `W22` = `HDMI_CEC` |
| 原理图 **第 15 页**（LED/KEY） | **`W22` = `LED1`**（BLUE_LED，串 330Ω 到 D4） |

**两页不可能同时成立** ✗ —— 这是原理图内部矛盾。

**本工程的规避策略**（不去赌哪个对）：

1. **不使用 `HDMI_CEC`** —— 我们只做 TMDS/DVI，CEC 本来就不需要 ✓
2. **`LED1` 仍按第 15 页用 `W22`** —— 那一页有专门的 LED 符号 + 330Ω 限流电阻，
   描述最具体；而且 LED 不驱动也不会影响 HDMI（CEC 未使用）✓
3. **上板时留意**：如果发现 LED1 不亮、而 HDMI 的 CEC 脚有信号，说明第 14 页是对的

> 手册 §3.11 原本写 `HDMI_CEC = W22` —— 现在看**手册可能是对的**，
> 之前我判断「手册笔误、正确是 U17」是**读图读错了**，本次已用高清渲染推翻。

### 6.4 分辨率与时钟可行性

TMDS 串行化需要 **像素时钟 × 5**（`OSERDESE2` 5:1 DDR）：

| 分辨率 | 像素时钟 | 5× 时钟 | 难度 |
| --- | --- | --- | --- |
| 640×480@60 | 25.175 MHz | 125.9 MHz | ✅ 轻松 |
| 800×600@60 | 40.0 MHz | 200 MHz | ✅ 容易 |
| 1280×720@30 | 37.125 MHz | 185.6 MHz | ✅ 容易 |
| **1280×720@60** | 74.25 MHz | **371.25 MHz** | ⚠️ 有挑战 |
| 1920×1080@60 | 148.5 MHz | 742.5 MHz | ❌ `OSERDESE2` 上限约 1250 Mbps，做不到 |

**MMCM 方案**（第二个 MMCM，板上有 6 个 CMT）：

```
输入 200 MHz  →  D = 5, M = 18.5625  →  VCO = 742.5 MHz
                     ÷10 = 74.25 MHz   (1280×720@60 像素时钟)
                     ÷2  = 371.25 MHz  (TMDS 5× 时钟)
   M = 18.5625 = 18 + 4.5/8  ✓ 正好落在 MMCM 的 1/8 步进上
```

### 6.5 ⚠️ 仍需上板核实

1. **Bank 14 的 Vcco 电压** —— `TMDS_33` 需要 Vcco = 3.3V。
   手册 §3.10 说以太网在 bank 14 且电平 1.8V，需确认实际供电。
2. `HDMI_OUT_EN`（V22）**高有效还是低有效** —— 要查 `NC7SZ125` 的 OE 极性
3. `HDMI_HPD`（V20）是否需要读（通常不读也能亮）
4. **显示器兼容性** —— 只做 TMDS 时是 DVI 信号，HDMI 显示器基本都接受

---

## 6b. 触摸屏（XPT2046，**已反推出来**）

数据来源：`04.通用子卡原理图/Puzhi 4.3 Inch LCD Schematic.pdf`
+ `02.连接器管脚与等长/璞致PA-Starlite 连接器引脚信号和等长 .xlsx`（JM1 工作表）。

**子卡上就有 XPT2046**（U2），四线 SPI，面板是 4 线电阻屏（`X_L/X_R/Y_T/Y_B`）。

| 信号 | 子卡 40P 脚 | JM1 脚 | FPGA 脚 | Bel |
| --- | --- | --- | --- | --- |
| `TP_SPI_nCS` | 37 | 37 | **E19** | `IO_L14P_SRCC_16` |
| `TP_SPI_DOUT` | 38 | 38 | **B20** | `IO_L16P_16` |
| `TP_SPI_DCLK` | 39 | 39 | **D19** | `IO_L14N_SRCC_16` |
| `TP_SPI_DIN` | 40 | 40 | **A20** | `IO_L16N_16` |
| `TP_nINT` | 31 | 31 | C19 | ⚠️ **R12 是 NC 未焊，中断用不了，只能轮询** |

### 怎么反推出来的（证据链）

1. 子卡原理图里有两个 40 脚连接器：`LCD1` 是屏的 FPC 座（对 FPGA 不可见）；
   `CON40/J1` 才是与主板对接的排针，触摸信号在这里。
2. **交叉验证**：已有的 LCD 映射实测已点亮 ——
   `lcd_clk=F18`=JM1 **30**，子卡 30 脚丝印 `LCD_DCLK` ✓；
   `lcd_hs=C18`=JM1 **29**，子卡 29 脚 `LCD_HS` ✓；
   `lcd_vs=E18`=JM1 **32**，子卡 32 脚 `LCD_VS` ✓。
   三条全对上 → **CON40 与 JM1 是 1:1 的**。
3. **反证**：JM1 的 33/34/35/36 是 GND，而子卡 35/36 是空接。
   触摸信号不可能在 35/36（会被直接接地）→ **只能是 37~40**。
4. **左右列分别是奇/偶脚号**：CON40 是 2x20 排针，左列 37/39、右列 38/40。
   所以对标签时**先按奇偶分列，再看上下顺序** —— 这是唯一不会读错的办法。
   （第一版就是按"标签的上下位置"硬对，把 nCS/DCLK 和 DOUT/DIN 全写反了。）

> ⚠️ 这**不是** lcdwiki 那个通用 40pin RGB 标准（那个是 30=PCLK/31=HSYNC/32=VSYNC、
> 触摸在 35~39）。璞致这块子卡是 **29=HS/30=DCLK/32=VS**、触摸在 37~40，**另一套排法**。
> 详见 `constrs/touch.xdc` 头部注释与[账本](08-skills-index.md)第 69 条。

### ⚠️ 出厂状态：U2 **未焊**

**实测确认（2026-10-04）：子卡上的 `U2`（XPT2046）根本没焊，`R10`（VREF 上拉 0Ω）也是 NC。**
这块子卡是"触摸电路可选焊"的 —— 出厂可能只有屏和背光。

现象：`tp_dout` 悬空 -> FPGA 输入恒读高 -> 原始读数恒为 **4095**（0xFFF），
状态行诊断显示 **`E0000 L0`**（DOUT 全程无低电平）。

**要让触摸可用，需要：**

| 项 | 是否必须 | 说明 |
| --- | --- | --- |
| **焊上 U2** | ✅ **必须** | XPT2046，SSOP-16/TSSOP-16 |
| 焊上 R10（0Ω，VREF→VDD_3V3） | ❌ **可不焊** | 固件已改用 **PD=11（内部参考）**，不依赖外部 VREF |
| C5/C6 去耦电容 | 建议 | 图上没标 NC，但顺手确认一下 |

> 固件侧的命令字节：`0xDC`（读 X）/ `0x9C`（读 Y）—— `PD1:PD0 = 11` 表示
> 使用**内部参考**、ADC 常开。若以后把 R10 焊上，可改回 `0xD0/0x90`
> （PD=00，转换间掉电）省一点电，见 `rtl/touch/xpt2046.v` 注释。

**上板验证方法**：状态行第二行会实时显示 `TX#### TY####`（原始读数）。
手指按下去数字必须跟着变；若一直是 `000` 或 `FFF`，说明脚号推错或 SPI 没通。

---

## 7. 摄像头（MIPI 接口 J4）

| 信号 | 管脚名 | 位置 |
| --- | --- | --- |
| `MIPI_CLK_P` / `_N` | `IO_L13P/N_13` | V13 / V14 |
| `MIPI_DATA_P0` / `_N0` | `IO_L12P/N_13` | W11 / W12 |
| `MIPI_DATA_P1` / `_N1` | `IO_L11P/N_13` | Y11 / Y12 |
| `MIPI_LP_CLK_P` / `_N` | `IO_L14P/N_13` | U15 / V15 |
| `MIPI_LP_DATA_P0` / `_N0` | `IO_L10P/N_13` | V10 / W10 |
| `MIPI_LP_DATA_P1` / `_N1` | `IO_L9P/N_13` | AA10 / AA11 |
| `MIPI_CAM_CLK` | `IO_L15P_13` | T14 |
| `MIPI_CAM_nRST` | `IO_L15N_13` | T15 |
| `MIPI_IIC_SCL` | `IO_L16P_13` | W15 |
| `MIPI_IIC_SDA` | `IO_L16N_13` | W16 |

**只有 3 对差分（2 data lane + 1 clock lane）**，即单路 MIPI。

### 关于双目摄像头子卡（PZ5640-D / PZ5640-M）

原理图显示这是**两张不同的子卡**：

| 子卡 | 导出信号 | 说明 |
| --- | --- | --- |
| `PZ5640-**D**` | `CAM1_D0..D9`, `CAM1_PCLK/HSYNC/VSYNC`, `CAM2_*` | **DVP 并口**（也复用标注了 MIPI 网络名） |
| `PZ5640-**M**` | 只有 MIPI 差分对 | MIPI |

而 OV5640 的引脚是**复用**的：

```
DVP 8bit 模式:  数据 = D[9:2]        (注意不是 D[7:0]！)
MIPI 模式:      D4=MIPI_DN0  D5=MIPI_DP0  D6=MIPI_CLKN
                D7=MIPI_CLKP D8=MIPI_DN1  D9=MIPI_DP1
```

子卡原理图里有一个 `CON40` 连接器把 `CAM1_*/CAM2_*` 全部引出，
**其命名与主板的 JM1（40P 扩展口）对应**。

> ⚠️ **必须实物核实**：把子卡插到 **JM1**（而不是 J4 MIPI 座）时，
> 用万用表确认 `CAM1_D9..D2`、`CAM1_PCLK`、`CAM1_HSYNC`、`CAM1_VSYNC`、`CAM1_IIC_*`
> 是否真的通到 FPGA 管脚，以及子卡的 DOVDD 电平（原理图上看到 `VDD_CAM1_2V8` / `VDD_CAM1_1V5`）。
> JM1 在 **bank 16（HR bank，1.8/2.5/3.3V 可选，默认 3.3V）**，可以调到 2.5V 匹配。

**如果 DVP 路径走通，摄像头就是一天的工作量；如果只能走 MIPI，就是几个月的工程量。**

## 8. 40P 扩展口（JM1 / JM2）

两个 40 脚（2×20）牛角座，全部是普通 IO，**含 MRCC/SRCC 时钟脚**。

| | JM1（bank 16） | JM2（bank 15） |
| --- | --- | --- |
| 电平 | HR bank，1.8/2.5/3.3V 可选，**默认 3.3V** | 同左 |
| 时钟脚 | `IO_L11P_SRCC_16` B17 / `IO_L12P_MRCC_16` D17 / `IO_L13P_MRCC_16` C18 / `IO_L14P_SRCC_16` E19 | `IO_L11P_SRCC_15` J20 / `IO_L12P_MRCC_15` J19 / `IO_L13P_MRCC_15` K18 / `IO_L14P_SRCC_15` L19 |
| 电源 | 1: 5V, 2: 3.3V | 同左 |

**完整引脚表见** `04.硬件相关/02.连接器管脚与等长/*.xlsx`（含走线等长数据）。

### ⚠️ JM1 已被 LCD 吃掉，音频模块必须接 JM2

| | JM1（bank 16） | JM2（bank 15） |
| --- | --- | --- |
| 信号脚 | pin 5~32（28 个）+ 37~40（4 个）= 32 | 同样 32 个 |
| 已被占用 | **LCD 占 pin 5~30 + 32 = 27 个** | 空闲 |
| 剩余 | pin 31 + pin 37~40 = **5 个** | **全部 32 个空闲** |

**结论：音频模块接 JM2。** JM2 引脚：
- `IO_L11P_SRCC_15` J20（pin 21）/ `IO_L12P_MRCC_15` J19（pin 25）
- `IO_L13P_MRCC_15` K18（pin 29）/ `IO_L14P_SRCC_15` L19（pin 37）
- 其余为普通 IO

### 音频模块接线规划（**待音频模块到货后细化**）

板上没有 I2S 座，所以音频模块要靠杜邦线接 JM1/JM2。建议：

| 信号 | 方向 | 建议引脚 | 理由 |
| --- | --- | --- | --- |
| `MCLK`（12.288 MHz，可选） | FPGA → 模块 | `IO_L12P_MRCC_16` (D17) | 时钟输出，走 MRCC 脚减少抖动 |
| `BCLK` | FPGA → 模块 | 任意普通 IO | 3.072 MHz |
| `LRCLK` | FPGA → 模块 | 任意普通 IO | 48 kHz |
| `SDIN`（模块 → FPGA） | 输入 | 任意普通 IO | |
| `SDOUT`（FPGA → 模块） | 输出 | 任意普通 IO | |
| `I2C_SCL` / `SDA` | 双向 | 任意普通 IO + 4.7k 上拉 | codec 寄存器配置 |

> **注意**：如果模块 I2C 总线与板载 EEPROM 共用，会有地址冲突风险 ——
> **建议 I2C 完全独立接一组新 IO**，电源也从 JM1 取 3.3V。

## 9. LCD 4.3 英寸（Puzhi 4.3 Inch LCD）

数据来源：`Puzhi 4.3 Inch LCD Schematic.pdf` + **官方例程**
`05.FPGA源码教程/3_16_PZ_LCD/`（含完整 XDC，已实测可用）。

### 9.1 电气接口：**单端并行 RGB，不是差分**

| 项 | 值 |
| --- | --- |
| 接口类型 | **RGB888 并行 + 3 根控制线** |
| 电平 | **全部 `LVCMOS33` 单端** |
| 信号数 | 24 (RGB) + 3 (CLK/HS/VS) = **27**，另可能有 1 根 DE |
| 连接器 | 40P，插到 **JM1** |

> **常见误解**：XDC 里会出现 `IO_L1P_16` / `IO_L1N_16` 这种带 P/N 的引脚名，
> 让人以为是差分。实际上 7 系列的**每个 IO 引脚都属于某个差分对**，
> 但 P/N 两半**可以各自当独立单端信号使用**。证据：
> ```
> lcd_rgb[0] = F13 = IO_L1P_16
> lcd_rgb[2] = F14 = IO_L1N_16     ← 同一个差分对的两个半边，各当一根单端线用
> ```
> 整个官方 XDC 里 LCD 部分**没有一处差分标准**，全是 `IOSTANDARD LVCMOS33`。
>
> （如果看到一个模块有 `xxx_p` / `xxx_n` 两个端口，那才是差分 ——
> 但 `LCD_TOP.v` 里的 `sys_clk_p/sys_clk_n` 是 **200 MHz 系统时钟**，不是 LCD 信号。）

### 9.2 时序参数（480×272）

官方例程 `LCD_TOP.v` 里的参数：

| | 同步 | 后沿 | 有效 | 前沿 | 总计 |
| --- | --- | --- | --- | --- | --- |
| 水平 | 41 | 2 | **480** | 2 | 525 |
| 垂直 | 10 | 2 | **272** | 2 | 286 |

```
帧率 = 像素时钟 / (525 × 286)
```

### 9.3 像素时钟：12.5 MHz

官方例程用 Clocking Wizard 生成，实测 MMCM 参数：

```
DIVCLK_DIVIDE    = 4        PFD = 200/4 = 50 MHz
CLKFBOUT_MULT_F  = 15.125   VCO = 50 × 15.125 = 756.25 MHz
CLKOUT0_DIVIDE_F = 60.500   → 756.25 / 60.5 = 12.5 MHz
```

帧率 = 12.5e6 / 150150 = **83.2 Hz**（高于 60 Hz，面板可接受）。

> **注意**：12.5 MHz 与音频的 12.288 MHz **无法共用一个 MMCM**
> （VCO 需同时整除二者，`1.5625·o1 = 1.536·o2` 在 o ≤ 1024 内无解）。
> LCD 要独占一个 CMT。XC7A100T 有 6 个，够用。

### 9.4 实现状态 ✅

| 项 | 文件 |
| --- | --- |
| 时序发生器 | `rtl/video/lcd_timing.v`（56 LUT / 47 FF，参数化） |
| 管脚约束 | `constrs/lcd.xdc`（27 条，与本表 §9.4 已程序化交叉核对，27/27 一致） |
| 验证 | `sim/tb/tb_lcd_timing.v` —— **七项守恒检查全部通过** |

验证不靠看波形，而是用**一帧总量守恒** + **逐像素遍历**：

```
帧周期          150150 拍 = 525 x 286        = 12.012 ms (83.25 Hz)
DE 像素数       130560  = 480 x 272
HSYNC 低电平    11726   = 41 x 286
VSYNC 低电平    5250    = 10 x 525
x 遍历          每行 0->479 连续无断点（共 544 行 / 2 帧）
y 遍历          每行 +1 到 271
rgb 对齐        rgb_out 与 de 严格同拍，DE 之外恒为 0
```

> ⚠️ **一条容易写错的时序契约**：`de` / `hsync` / `vsync` / `rgb_out` 是**寄存输出**，
> 而 `x` / `y` 是**当拍组合输出**（调用方要靠它算颜色）。
> 所以 **`de` 与 `x` 天然差一拍**，拿当拍的 `x` 去对 `de` 会全错。
> 正确的对应关系是：`de`(T+1) ↔ `x`(T) ↔ `rgb_out`(T+1)。

### 9.5 管脚

**直接抄官方 XDC**（`3_16_PZ_LCD/PZ_LCD.srcs/constrs_1/new/LCD.xdc`），已验证可用：

| 信号 | 管脚 | JM1 脚位 | FPGA 引脚名 |
| --- | --- | --- | --- |
| `lcd_rgb[0]` | F13 | 6 | `IO_L1P_16` |
| `lcd_rgb[1]` | E16 | 5 | `IO_L5P_16` |
| `lcd_rgb[2]` | F14 | 8 | `IO_L1N_16` |
| `lcd_rgb[3]` | D16 | 7 | `IO_L5N_16` |
| `lcd_rgb[4]` | D14 | 10 | `IO_L6P_16` |
| `lcd_rgb[5]` | C13 | 9 | `IO_L8P_16` |
| `lcd_rgb[6]` | D15 | 12 | `IO_L6N_16` |
| `lcd_rgb[7]` | B13 | 11 | `IO_L8N_16` |
| `lcd_rgb[8]` | C14 | 14 | `IO_L3P_16` |
| `lcd_rgb[9]` | A13 | 13 | `IO_L10P_16` |
| `lcd_rgb[10]` | C15 | 16 | `IO_L3N_16` |
| `lcd_rgb[11]` | A14 | 15 | `IO_L10N_16` |
| `lcd_rgb[12]` | E13 | 18 | `IO_L4P_16` |
| `lcd_rgb[13]` | A15 | 17 | `IO_L9P_16` |
| `lcd_rgb[14]` | E14 | 20 | `IO_L4N_16` |
| `lcd_rgb[15]` | A16 | 19 | `IO_L9N_16` |
| `lcd_rgb[16]` | B15 | 22 | `IO_L7P_16` |
| `lcd_rgb[17]` | B17 | 21 | `IO_L11P_SRCC_16` |
| `lcd_rgb[18]` | B16 | 24 | `IO_L7N_16` |
| `lcd_rgb[19]` | B18 | 23 | `IO_L11N_SRCC_16` |
| `lcd_rgb[20]` | F16 | 26 | `IO_L2P_16` |
| `lcd_rgb[21]` | D17 | 25 | `IO_L12P_MRCC_16` |
| `lcd_rgb[22]` | E17 | 28 | `IO_L2N_16` |
| `lcd_rgb[23]` | C17 | 27 | `IO_L12N_MRCC_16` |
| `lcd_hs` | C18 | 29 | `IO_L13P_MRCC_16` |
| `lcd_clk` | F18 | 30 | `IO_L15P_16` |
| `lcd_vs` | E18 | 32 | `IO_L15N_16` |

**JM1 pin 31（`IO_L13N_MRCC_16` = C19）官方例程未使用 —— 很可能就是 `LCD_DE`**（见 9.5）。

### 9.5 三个必须注意的坑

**① DE 由子卡硬件拉高，我们不用驱动** ✅

读子卡原理图确认：`LCD_DE` 经 **0Ω 电阻（R13，已贴）直接接到 VDD_3V3**，
且面板侧 `DE` 脚（pin 34）的 4.7K 上拉 R5 是 **NC**，
所以 DE 完全由 `LCD_DE` 网络决定 → **恒为高电平**。

这就解释了官方例程为什么不驱动 DE 也能正常显示。
→ **我们的工程同样不需要生成 DE**，JM1 pin 31 因此是空闲的。

（同图还确认：面板 `DISP` 脚经 R4 4.7K 上拉到 3.3V，显示常开。）

**② 官方例程把 `lcd_rgb` 声明成 `inout`**
```verilog
inout [23:0] lcd_rgb      // 例程写法
```
代码里只当输出用（`assign lcd_rgb = ...`）。三态端口会引入额外的 IO buffer、
浪费资源、还可能引入竞争。**我们应该改成 `output [23:0]`**。

**③ 官方例程完全没有时序约束**
整个 `LCD.xdc` 里**没有一条 `create_clock`**。
点灯级别的例程无所谓，但**我们的工程必须加**（否则时序报告不可信）。

### 9.6 触摸屏

子卡上有 **XPT2046 电阻触摸控制器**，通过 **SPI** 与 FPGA 通信
（`TP_SPI_nCS` / `TP_SPI_DCLK` / `TP_SPI_DIN` / `TP_SPI_DOUT` / `TP_nINT`）。

这是**可选加分项**：给均衡器加个触摸调参界面。
优先级低，先不做。

## 10. SD 卡（来自手册，**有冲突待核实**）

| 信号 | 管脚名 | 位置 |
| --- | --- | --- |
| `SD_CLK` | `IO_L8P_14` | AA20 |
| `SD_CMD` | `IO_L10P_14` | AB21 |
| `SD_DATA0` | `IO_L17N_14` | AB18 |
| `SD_DATA1` | `IO_L17P_14` | AA18 |
| `SD_DATA2` | `IO_L10N_14` | AB22 |
| `SD_DATA3` | `IO_L8N_14` | AA21 |

> ⚠️ 原理图文本提取显示 AA20 对应 `IO_L7N_T1_D10_14`（bank 14 的另一个引脚名），
> 与手册的 `IO_L8P_14` 不符。**用 SD 卡前必须核实。**

## 11. DDR3

| 项 | 值 |
| --- | --- |
| 型号 | `MT41K256M16TW-107 IT` × 2 |
| 单颗容量 | 256M × 16 = 4 Gb = **512 MB** |
| 总容量 | **1 GB** |
| Bank | 34（地址/命令）、35（数据） |

> 用户手册写"单颗容量 512**M**b"，与芯片型号矛盾；按型号应为 **512MB**，你之前说的是对的。
>
> **本项目当前不使用 DDR3**（无 MIG）。理由见 [01-architecture.md](01-architecture.md)：
> Overlay 是程序化生成 + 流式混叠，只需行缓存（BRAM），不需要整帧缓存。

## 12. 其它

| 资源 | 说明 |
| --- | --- |
| QSPI Flash | W25Q128JVSQ，128 Mb |
| 以太网 | RTL8211FD，RGMII，bank 14，1.8V，PHY_AD=001 |
| 配置 | JTAG 优先于 QSPI，无需切换 |
| 板载调试器 | USB 转 JTAG，一根 TypeC 线搞定供电+调试 |

---

## 待核实清单（写 XDC 之前必须完成）

| # | 项 | 为什么关键 | 怎么核实 |
| --- | --- | --- | --- |
| 1 | **Bank 14 的 Vcco** 与 HDMI 的 IOSTANDARD | 决定 TMDS 能否直接驱动，决定 HDMI 方案可行性 | 查 HDMI 官方例程的 XDC |
| 1b | `sys_clk` 的 IOSTANDARD | ~~已解决~~ → **`DIFF_SSTL15`**（官方 LCD 例程 XDC 实测） | ✅ |
| 1c | ~~LCD_DE 接在 JM1 哪个脚~~ | ~~可能导致画面偏移~~ | ✅ **已解决：DE 由子卡 0Ω 电阻拉到 3.3V，恒高，不用驱动** |
| 1d | `HDMI_OUT_EN` 的引脚与极性 | 有的 HDMI 电路需要使能才输出 | 查原理图读图 |
| 2 | W22 到底是 LED1 还是 HDMI_CEC | 管脚约束冲突 | 万用表测 W22 与 LED1 限流电阻的连通性 |
| 3 | 摄像头子卡插 JM1 时 DVP 是否通到 FPGA | 决定视频输入是"一天"还是"几个月" | 万用表测子卡 CON40 的 D0-D9/PCLK/HSYNC/VSYNC 与 FPGA 管脚通断 |
| 4 | 子卡 DOVDD 电平（2.8V？1.8V？） | 决定 JM1 bank 电压档位 | 量子卡上的 `VDD_CAM1_2V8` 实际电压 |
| 5 | SD 卡 6 个脚的真实位置 | 手册与原理图提取结果不符 | 万用表 |
| 6 | `HDMI_OUT_EN` / `HDMI_HPD` 引脚 | 有的 HDMI 电路需要使能信号才输出 | 查原理图 + 官方例程 XDC |


---

## 13. 引脚映射核对方法（可复现）

原理图 PDF 文本提取会串列，手册也可能有笔误。**唯一权威来源是 Vivado 的器件数据库。**

```tcl
# /tmp/dump.tcl —— 导出 FGG484 全部 484 个引脚的 位置 -> PIN_FUNC
create_project -in_memory -part xc7a100tfgg484-2
read_verilog /tmp/empty.v          # 内容: module empty(input a); endmodule
synth_design -top empty -part xc7a100tfgg484-2 -quiet
set f [open /tmp/pins.txt w]
foreach p [lsort [get_package_pins]] {
    puts $f "[get_property NAME $p] [get_property PIN_FUNC $p]"
}
close $f
```
```bash
vivado -mode batch -nojournal -nolog -source /tmp/dump.tcl
```

`PIN_FUNC` 是长名（`IO_L7N_T1_D10_14`），手册用短名（`IO_L7N_14`）。
归一化规则：**只保留 `IO_L<n><P/N>_<bank>`，丢掉 `_T<n>` / `MRCC` / `SRCC` / 复用功能名**。

```python
import re
def norm(f):
    m = re.match(r'^IO_L(\d+)([PN])_.*_(\d+)$', f)
    return f"IO_L{m.group(1)}{m.group(2)}_{m.group(3)}" if m else f
```

**核对结果：52 条手册映射中 51 条一致，唯一错误是 `HDMI_CEC`（W22 → U17）。**

> 这个方法是通用的：任何手册/原理图的引脚表，都可以这样批量核对一遍，
> 比逐个用万用表量快得多，而且不会漏。
