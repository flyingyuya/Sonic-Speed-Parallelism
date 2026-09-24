---
name: rtl-verification
description: RTL 自动化验证方法：用 Python 定点黄金模型与 RTL 逐位对拍、三段式测试激励设计、协议行为模型（I2S/SPI 等）编写、分层 testbench 结构、以及 testbench 自身的时序陷阱排查。当需要为 RTL 建立可复现的自动化验证、生成测试向量、编写 testbench 或行为模型，或排查"仿真不通过/两边差一拍/等待信号失效/波形全零"这类问题时使用。
---

# RTL 自动化验证

## 核心原则

**把"结果对不对"交给黄金模型，把"时序对不对"交给协议行为模型。**
两条线分开，出问题时能立刻定位是算法错还是时序错。

```
        ┌──────────────────────────┐
   板上 │  真实硬件 + ILA + 示波器  │  少量、昂贵、不可替代
        ├──────────────────────────┤
   对拍 │  RTL vs Python 定点模型   │  主力：逐位一致，覆盖全部算法
        ├──────────────────────────┤
   单元 │  协议时序检查（帧格式）    │  基础：边界条件、复位、握手
        └──────────────────────────┘
```

---

## 一、黄金模型必须"定点"

浮点模型只能验证**算法设计**对不对，不能验证**定点实现**对不对。

| 能力 | 浮点模型 | 定点模型 |
| --- | --- | --- |
| 验证算法思路 | ✅ | ✅ |
| 验证 Q 格式选得对不对 | ❌ | ✅ |
| 验证舍入/饱和实现 | ❌ | ✅ |
| 验证位宽够不够 | ❌ | ✅ |
| **判据** | "误差小于阈值" | **逐位相等** |

**Java/Python 的整数运算是任意精度的**，而 RTL 是固定位宽。所以定点模型必须
显式模拟每一处截断、舍入、饱和（细节见 `fixed-point-dsp` 技能）。

### 逐位一致的判据写法

```verilog
if (y_out !== yv[n_out]) errors = errors + 1;   // !== 而非 !=
```

`!==` 是"完全相等"（含 X/Z 比较），`!=` 在含 X 时会得到 X 导致误判为通过。

---

## 二、测试激励设计：三段式覆盖

**不要用随机数当激励**——随机数覆盖不到边界，而且失败时不可复现。
用确定性、有目的的三段式：

| 段 | 内容 | 覆盖目标 |
| --- | --- | --- |
| 1 | **单点冲激** | 每个 section 的极点/零点、状态初值路径 |
| 2 | **多音叠加**（如 100/1000/8000 Hz） | 稳态频响、级联顺序 |
| 3 | **满量程方波 + 正负极值** | **饱和分支**（`ovf_p` / `ovf_n`） |

```python
def make_input(n):
    seg = n // 3
    xs = []
    # 段1：冲激
    for i in range(seg):
        xs.append(SAMPLE_MAX // 2 if i == 0 else 0)
    # 段2：多音
    for i in range(seg):
        v = sum(math.sin(2*math.pi*f*i/FS) for f in [100.0, 1000.0, 8000.0])
        xs.append(int(round(v / 3 * 0.25 * SAMPLE_MAX)))
    # 段3：满量程方波（压饱和）
    for i in range(n - 2*seg):
        xs.append(SAMPLE_MAX if ((i*1000)//int(FS)) % 2 == 0 else SAMPLE_MIN)
    return xs
```

**为什么必须专门设计饱和激励**：`ovf_p`/`ovf_n` 两个分支在正常音频下
永远不触发，随机测试也几乎碰不到。没有这段，饱和逻辑等于没测。

---

## 三、行为模型：把"另一个芯片"写出来

验证接口协议时，**写一个行为级的对端器件模型**，而不是在 testbench 里
硬编码波形。

例：I2S codec 模型（同时扮演 ADC 和 DAC）

```verilog
module codec_model #(parameter DW=24, SLOT=32) (
    input  wire clk, rst_n,
    input  wire bclk_rise, bclk_fall, frame_start,
    input  wire [5:0] bit_idx,
    input  wire signed [DW-1:0] adc_l, adc_r,   // 要发送的样本
    output wire sdin,                           // ADC 串行输出
    input  wire sdout,                          // FPGA 的串行输出
    output reg  signed [DW-1:0] cap_l, cap_r,   // 采回来的样本
    output reg  cap_valid
);
    // ADC：在 BCLK 下降沿换数据（与真实 codec 一致）
    // DAC：在 BCLK 上升沿采样
```

**关键：模型的换沿/采样行为必须与真实器件一致**（下降沿发送、上升沿采样）。
这样它才同时检查了 FPGA 侧的时序正确性。

### 一条 testbench 验证双向要分开判定

```verilog
// 接收方向：i2s_rx 解出的样本 == codec 发出的样本
if (rx_l !== exp_l || rx_r !== exp_r) err_rx <= err_rx + 1;
// 发送方向：codec 从 sdout 解出的样本 == 喂给 i2s_tx 的样本
if (cap_l !== exp_l || cap_r !== exp_r) err_tx <= err_tx + 1;
```

**否则收发同时错会互相抵消，测试假通过。**

### 还要验证"参数"而不只是"数据"

例：I2S 的 LRCLK 分频比是否正确，可以直接数帧间隔：

```verilog
always @(posedge clk) begin
    if (bclk_rise) bclk_rise_cnt <= bclk_rise_cnt + 1;
    if (frame_start) begin
        if (seen_first) begin
            if (bclk_rise_cnt == NFRAME) period_ok <= period_ok + 1;
            else                         period_bad <= period_bad + 1;
        end
        seen_first <= 1'b1;
        bclk_rise_cnt <= 0;
    end
end
```

**数据全对但分频比错一倍**是完全可能的（比如 LRCLK 半周期 64 拍而非 32 拍），
只对数据不查参数就会漏掉。

---

## 四、testbench 自身的时序陷阱（真实踩坑集）

### 陷阱 1：`wait(signal)` 可能在信号还没起来时就返回

```verilog
// ✗ 错
cfg_load <= 1'b1;
@(posedge clk);
cfg_load <= 1'b0;
wait (running);          // running = ~cfg_busy；此刻 dirty 还没置位，running 仍为 1
                         // → 立刻返回，后续数据落进配置窗口

// ✓ 对：先等忙起来，再等它落下
wait (cfg_busy);
wait (running);
```

**推广**：等待"忙→闲"的转换，必须 `wait(busy); wait(~busy);`，
不能只等最终状态。

**同样的坑在**：上板控制软件里"写完配置立刻读状态"。必须确认 `cfg_busy` 起来过。

### 陷阱 2：握手信号与时钟沿选通不在同一拍

> RTL 侧：`frame_start` 若比 `bclk_fall` 晚一拍（一个是寄存器输出、
> 一个是组合输出），收发端会在错误的沿执行装载，**整帧数据全零**。

**testbench 侧对应的检查**：不要假设某个信号"应该是寄存器输出"，
先看波形确认它和依赖它的选通信号是否同拍。

```verilog
// 让握手信号与沿选通同拍（组合输出）
assign frame_start = bclk_fall & (bcnt == NLAST);
```

### 陷阱 3：期望值锁存在错误的时刻（差一拍）

```verilog
// 帧结构：frame_start(左声道起点) → 32bit 左 → half_start(右声道起点)
//          → 32bit 右 → 帧尾捕获

// ✗ 错：在 half_start 更新期望值
if (half_start) exp <= pat(fidx+1);
//  下一帧的 half_start 早于本帧的帧尾捕获 → 期望值提前一拍，全部对不上

// ✓ 对：在 frame_start 锁存"本帧实际发送的样本"
if (frame_start) exp <= adc_l[SLOT-1 -: DW];
```

**通用原则：期望值应该在"事务开始"的沿锁存，而不是"下一次事务准备"的沿。**

### 陷阱 4：信号悬空（TB 里接到未驱动的 wire）

testbench 顶层引用被测模块的**内部信号**时，如果这些信号没有引出成端口，
在 TB 里就是悬空的 `z`：

```verilog
// TB 里写 .frame_start(frame_start)，但 audio_top 没把 frame_start 引出端口
// → TB 侧 frame_start 恒为 z，codec 模型永远不动作，输出全零
```

**修法**：给被测模块加一组 `dbg_*` 观测端口（综合时会被优化掉，
或直接给 ILA 用），并在 TB 里接上。

**排查信号**：仿真输出全零 / 计数器不增长 → 先查关键选通信号是不是悬空。

### 陷阱 5：复制粘贴导致左右声道比较对象错位

```verilog
// ✗ 错：cap_buf 只存了左声道，却拿去和右声道的期望比
if (cap_buf[i0+k] !== -ir_ref[k]) err_r++;

// ✓ 对：右声道单独存一份
if (cap_buf_r[i0+k] !== -ir_ref[k]) err_r++;
```

**症状**：左声道 0 错误、右声道 256/256 全错 —— 一看就是比较对象搞错了。

### 陷阱 6：组合环在仿真里恰好收敛

组合环在事件驱动仿真中会迭代求值直到稳定。若环路恰好收敛，
**iverilog 不报错、testbench 全过**，但硬件上是 race。

→ **必须跑综合 DRC 检查 `LUTLP-1`。**（详见 `fpga-rtl-flow` 技能）

---

## 五、分层 testbench 结构

```
tb_<模块>            单元级：只测一个模块，驱动最简单、定位最快
  └─ tb_i2s_loopback   协议级：验接口时序
       └─ tb_<top>      系统级：端到端，验整合与配置流程
```

**为什么要三层**：

| 层 | 定位能力 | 速度 |
| --- | --- | --- |
| 单元 | 精确定位到某个算术/FSM | 最快 |
| 协议 | 定位到接口时序 | 快 |
| 系统 | 只能告诉你"整合有问题" | 慢 |

**系统级失败时，先跑单元级确认模块本身没问题**，再查整合。

### 系统级用"冲激响应比对"做端到端验证

比逐样本比对更实用，因为它**不需要预先知道流水线延迟**：

```
1. 通过配置端口写入参数（触发系数装载）
2. 先送静音，再送冲激，其后全零
3. 在输出流里找第一个非零样本作为 IR 起点
4. 与黄金模型的冲激响应逐位比对
```

```verilog
// 找 IR 起点
i0 = -1;
for (i = 0; i < n_cap; i = i + 1)
    if (cap_buf[i] != 0) begin i0 = i; i = n_cap; end

// 逐位比对 + 顺便报告端到端延迟
for (k = 0; k < NIR; k = k + 1)
    if (cap_buf[i0 + k] !== ir_ref[k]) err_l = err_l + 1;

$display("端到端延迟: %0d 帧 (%0d clk)", i0 - 8, (i0-8) * CLK_PER_FRAME);
```

**同时拿到两个产出**：正确性验证 + **端到端延迟实测值**（可直接写进报告）。

---

## 六、验证产物与可复现性

一次验证应产出：

| 产物 | 用途 |
| --- | --- |
| `sim/vectors/*.hex` | 输入与黄金输出（可离线复核） |
| `sim/vectors/*_rtl.hex` | **RTL 实际输出**（独立于 TB 的比较逻辑） |
| `sim/vectors/*_meta.txt` | 本次向量的配置元信息（段数、增益、样本数） |
| `sim/build/<tb>.log` | 编译告警 |
| 控制台 PASS/FAIL + 不符点个数 + 首个不符点位置 | 快速定位 |

**导出 RTL 实际输出是关键**：如果 TB 自身的比较逻辑写错，
它会报 FAIL，但原因可能是 TB 而不是 RTL。
有原始输出文件就能用 Python 离线交叉验证。

---

## 七、验收标准

- [ ] 黄金模型是**定点**的，与 RTL 逐位一致（`!==`，不是阈值）
- [ ] 测试激励**确定性**（不用随机数，或固定随机种子）
- [ ] 覆盖**饱和分支**（满量程激励）
- [ ] 协议测试**双向独立判定**（避免收发同错互相抵消）
- [ ] 协议测试还验证**参数**（分频比、帧长），不只验证数据
- [ ] 系统级测试能**自动定位 IR 起点**并报告端到端延迟
- [ ] 导出 RTL 实际输出供离线复核
- [ ] 仿真默认**关闭波形**（大向量下 VCD 能有几百 MB）
- [ ] **仿真 PASS 之后仍然跑一遍综合 DRC**（组合环只在综合暴露）

## 延伸阅读

- [references/golden-model-method.md](references/golden-model-method.md)
  —— 定点黄金模型的方法论、RTL ↔ Python 位级映射表、Python 代码组织方式、
  ROM 生成策略、常见反模式
- [references/debug-playbook.md](references/debug-playbook.md)
  —— **仿真失败排查手册**：按现象分类的决策树（输出全零 / 数量不对 /
  差一拍 / 数值偏差 / 完全对不上 / 编译失败）与收尾检查清单

相关技能：定点格式、舍入饱和、位宽预算见 `fixed-point-dsp`；
仿真之后的综合/DRC/时序检查见 `fpga-rtl-flow`。
