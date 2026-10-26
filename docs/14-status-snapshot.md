# 项目状态快照（固化）

> 这份文档把"当前能用的、已知受限的、待办的"固定下来，避免以后反复试探。
> 更新方式：每次完成一个阶段就改这里，并在提交信息里注明。

---

## 1. 已经可用（上板验证过）

| 功能 | 状态 | 说明 |
|---|---|---|
| **话筒输入** | ✅ | `LINPUT1`（板载 MEMS 麦克风）|
| **喇叭输出** | ✅ | **双声道**（左右都响）|
| **喇叭静音** | ✅ | 面板 `SPK` 键（清零送 DAC 的 I2S 数据）|
| **EQ** | ✅ | 旁路关闭后生效 |
| **数字回环** | ✅ | ADC → FIFO → DAC |
| **频谱显示** | ✅ | 60 根柱，铺满 480px |
| **波形显示** | ⚠️ | 能显示，但**静默时/吹风时有"多条重叠"现象**（见第 3 节）|
| **LCD 界面** | ✅ | 8 个面板按钮 + 右侧 8 行状态栏 |
| **面板光标** | ✅ | 8 项（VIEW/SPK/HUE/GAIN/BG/DEMO/IN/SD），方框高亮 |
| **SD 图片背景** | ✅ | `SD` 键切图（3 张循环，CMD18 多块读）|
| **HDMI 也能用 SD 图片** | ✅ | **帧缓冲 480×272 RGB565 ✗ LCD 1:1 满屏**；**HDMI 读第二份 320×180 裁剪缓冲再 2× 放大满屏**（两份不同尺寸缓冲，写侧过滤裁剪区）|
| **SD 卡工具** | ✅ | `scripts/sdcard/mkimage.py`（BMP/PNG/JPG → 裸扇区）|
| **按键交互** | ✅ | 单击/双击（KEY1 左移/面板开关，KEY2 右移/确认）|
| **Flash 固化** | ✅ | `program.tcl -tclargs flash`（W25Q128JVSQ，QSPI x4）|

---

## 2. 已知受限（硬件层面，代码已就绪）

### 线路输入（3.5mm 座）

```
现象：I01 切到线路后，喇叭有声音（右声道），但频谱/波形几乎不动
诊断（用户用手指注入 50Hz 验证）：
    摸 R2 的 INPUT_L3 侧 ⟹ 线路模式下有反应 ⟹ LINPUT3 → ADC 通 ✓
    摸 R1 的 INPUT_R1 侧 ⟹ 有反应              ⟹ RINPUT1 → ADC 通 ✓
    从座子插线进来      ⟹ 完全没反应          ⟹ 断在【座子 → C4 → INPUT_R1】
结论：C4（1µF 隔直）开路/虚焊 ⟹ 需要补焊
现状：代码用【模拟旁路】让线路能出声（单声道），但频谱/波形拿不到信号
恢复方法：补焊 C4 后，删掉 WM8960_init.v 里 R45/R46 的线路模式覆盖
```

### 喇叭单声道（历史）

```
现象：旁路开着时，话筒只响左喇叭、线路只响右喇叭
原因：模拟旁路是 LINPUT1→LOUT1（左）、RINPUT1→ROUT1（右）
现状：已关闭旁路（话筒模式），双声道正常 ✓
```

---

## 2.5 HDMI 图片背景的实现要点（2026-10 完成）

```
存储：480×272 RGB565（58 块 BRAM）
  · LCD  读第 1 份 u_fb_lcd  1:1 满屏（clk_pix 12.5 MHz）
  · HDMI 读第 2 份 u_fb_hdmi 320×180 中心裁剪后 2× 放大（clk_hdmi 25 MHz）
  · 写侧共用 sd_img_load；wr2_* 只写落在 [80,400)×[46,226) 的像素

为什么不是"一份缓冲两个读口"：
  Vivado 的 BRAM 推断【不支持 1 写 2 读跨时钟】⟹ 退化成 LUTRAM
  ⟹ 报 DRC UTLZ-1（需要 86,452 个 RAMD64E，只有 19,000 个）
  ⟹ 必须用两份实例

为什么不是 640×360 存储：
  640×360×16 = 103 块 ⟹ 加其它器件 98% ⟹ 布线拥塞 ⟹ clk_sys -1.09 ns ⟹ place 失败
  640×360×8（RGB332）= 52 块 ⟹ 但 256 色在渐变图上色带太重（实测否定）

两份缓冲的参数对照：
               FB_SW FB_SH FB_W FB_H FB_X0 FB_Y0 SHIFT FB_CX FB_CY
  LCD  实例      480   272   480   272    0     0     0     0     0
  HDMI 实例      320   180   640   360    0     0     1     0     0

两个容易踩的坑（都是上板实测发现的）：
  ① disp_top 的 24 位输出是为了迁就 LCD 面板的 BGR 接线做了 R/B 交换
     ⟹ HDMI 走标准 RGB 必须换回来，否则深蓝显示成暖黄
  ② bg_src 的渐变原来用固定位切片 y[8:3]
     ⟹ 272 行刚好，360 行时 y≥256 回绕 ⟹ 两屏背景不一致
     ⟹ 改成 YSH = (VDISP>=512) ? 4 : 3
```

## 2.6 当前构建指标（2026-10-26）

| 项 | 值 |
|---|---|
| **构建结果** | ✅ **0 CRITICAL / 0 WARNING** |
| **Slice LUTs** | **11,768（18.56%）** |
| **Block RAM** | **100.5 / 135（74.44%）** |
| **DSP48** | **26** |
| **`clk_sys`（48 MHz）** | **+1.779 ns** ✅ |
| **`clk_hdmi`（25 MHz）** | **+4.028 ns** ✅ |
| **`clk_pix`（12.5 MHz）** | **远大于 0** ✅ |
| **仿真回归** | **41 / 41 PASS** ✅ |
| **问题账本** | **816 条** |

**警告清零的做法（三类判据）**：

1. **真修 40 条 `REQP-1839`**：`sd_img_load` 的 `wr2_en`/`wr2_addr` 曾误放进
   异步复位块，驱动 BRAM 的 `ENARDEN`/`ADDRARDADDR` ⟹ 移出，改由 `start` 清零。
2. **豁免 50 条 `8-7129`**：参数化模块的高位地址超出实际使用范围
   （`bg_src.x[9:5]`、`text_buf.waddr[9:8]`、`cmd_proc.cfg_auto[0]` 等），
   判据写在 `build.tcl` 的注释里，并注明"前提若变则删除抑制"。
3. **豁免 1 条 `Route 35-328`**：布线器的保守估计，post-route 实测 WNS 全为正。

## 3. 待办

| 优先级 | 内容 | 说明 |
|---|---|---|
| ⭐⭐⭐ | **HDMI 复位后偶尔右半屏撕裂（TMDS 层）** | **DEMO 模式也坏 ⟹ 数据路径无辜 ✗ 疑似 OSERDESE2/5× 时钟相位** ✗ **试过"复位延迟 10µs→2.6ms"✗ 无效（已回退）** ⟹ **下一步需要 ILA 抓 TMDS 或示波器** |
| ⭐⭐⭐ | **波形"多条重叠"**（已解决）| TB 已证明触发算法稳定（周期信号下间隔是周期整数倍）✗ 门限也已提到 1/256 ⟹ 怀疑在 `disp_mix` 的 y 映射/绘制 |
| ⭐⭐⭐ | **波形幅度偏小** | 参考工程能"大开大合"✗ 需要检查 `disp_mix` 里 `wave_sample` → y 的缩放 |
| ⭐⭐ | **双路同步架构重规划** | LCD 与 HDMI 的画面不同步（各自独立实例）|
| ⭐ | **录音 + 回放**（回放时才开喇叭）| 大功能，需要存储 |
| ⭐ | **线路输入**（等补焊 C4）| 代码已就绪 |

---

## 4. 工程基础设施

| 项 | 值 |
|---|---|
| **回归** | **41 个 testbench**（1m30s 并行）|
| **构建** | `scripts/vivado/build.tcl`（支持 `SYNTH_ONLY=1` 只综合 3 分钟）|
| **Lint** | Verible + Verilator（零意外警告）|
| **资源** | ~10k LUT / 68 BRAM / 26 DSP |
| **时序** | `clk_sys` +1.7 / `clk_pix` +35 / `clk_hdmi` +0.4 ns |

---

## 5. 常用命令

```bash
# 仿真（模块级，1.5 分钟）
bash scripts/sim/run_iv.sh

# 只跑某个 TB
bash scripts/sim/run_iv.sh wave_buf

# 只综合（3 分钟，看资源/语法）
SYNTH_ONLY=1 vivado -mode batch -source scripts/vivado/build.tcl \
    -tclargs xc7a100tfgg484-2 top constrs

# 完整构建（10 分钟，出比特流）
vivado -mode batch -source scripts/vivado/build.tcl \
    -tclargs xc7a100tfgg484-2 top constrs

# 烧板（易失，SRAM，10 秒 —— 日常迭代用这个）
vivado -mode batch -source scripts/vivado/program.tcl

# 固化到 QSPI Flash（掉电保持，约 45 秒）
#   ⚠️ 内部流程：write_cfgmem → create_hw_cfgmem(-mem_dev) → 先烧 SRAM
#      （建立 SPI 访问通道）→ program_hw_cfgmem
#   ⚠️ 验证时必须【拔掉 JTAG 线】再上电（JTAG 优先于 QSPI）
vivado -mode batch -source scripts/vivado/program.tcl -tclargs flash

# 写 SD 卡图片
python3 scripts/sdcard/mkimage.py --make-test 3
sudo python3 scripts/sdcard/mkimage.py /dev/sda test0.bmp test1.bmp test2.bmp
```

---

## 6. 分支

| 分支 | 用途 |
|---|---|
| `master` | **主线（当前推荐）** |
| `minimal-line` | 线路输入实验（Boost Mixer 路径）|
| `test-5512646` | 旁路开启版本（单声道）|
| `tx-integration` | 早期 TX 集成实验 |

