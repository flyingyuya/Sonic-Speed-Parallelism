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

## 3. 待办

| 优先级 | 内容 | 说明 |
|---|---|---|
| ⭐⭐⭐ | **HDMI 复位后偶尔右半屏撕裂（TMDS 层）** | **DEMO 模式也坏 ⟹ 数据路径无辜 ✗ 疑似 OSERDESE2/5× 时钟相位** ✗ **试过"复位延迟 10µs→2.6ms"✗ 无效（已回退）** ⟹ **下一步需要 ILA 抓 TMDS 或示波器** |
| ⭐⭐⭐ | **波形"多条重叠"**（已解决）| TB 已证明触发算法稳定（周期信号下间隔是周期整数倍）✗ 门限也已提到 1/256 ⟹ 怀疑在 `disp_mix` 的 y 映射/绘制 |
| ⭐⭐⭐ | **波形幅度偏小** | 参考工程能"大开大合"✗ 需要检查 `disp_mix` 里 `wave_sample` → y 的缩放 |
| ⭐⭐ | **HDMI 也用 SD 图片当背景** | 帧缓冲只有一个读口，需要复制或用双口 |
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

