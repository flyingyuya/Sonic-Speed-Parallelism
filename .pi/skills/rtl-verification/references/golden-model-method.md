# 定点黄金模型：方法论与完整案例

## 1. 为什么必须是定点模型

一句话：**浮点模型验证不了定点实现。**

```
算法设计（浮点）  ──▶  验证"这个滤波器的思路对不对"
                    ↓ 量化（Q 格式选择、位宽、舍入策略）
定点实现（RTL）   ──▶  验证"这套实现能不能还原算法意图"
```

浮点模型看不到的问题：

| 问题 | 浮点模型能发现吗 |
| --- | --- |
| Q 格式范围不够导致系数削顶 | ❌ |
| 位宽不够导致累加器溢出 | ❌ |
| 舍入方式实现错（截断 vs 四舍五入） | ❌ |
| 饱和分支写反 | ❌ |
| 有符号/无符号扩展错误 | ❌ |

这些问题在浮点模型里全部消失，但它们是 RTL 里最常见的 bug 来源。

## 2. 位级对齐的完整映射表

以本项目 `eq_cascade`（DF2T 双二阶）为例：

**RTL：**
```verilog
localparam integer SH = CF;                                  // = 16
localparam [AW-1:0] RND = {{(AW-1){1'b0}}, 1'b1} << (SH-1);  // 2^15

wire signed [DW+CW-1:0] p0 = x_cur * b0;      // 24 × 18 = 42 位
wire signed [AW-1:0]    acc  = p0 + st1[sect];
wire signed [AW-1:0]    accr = acc + RND;
wire signed [AW-1:0]    ysh  = accr >>> SH;
wire signed [DW-1:0]    yn   = ovf_p ? MAXV : (ovf_n ? MINV : ysh[DW-1:0]);

wire signed [DW+CW-1:0] pa1 = yn * a1;
wire signed [AW-1:0]    st1n = p1 + st2[sect] - pa1;
wire signed [AW-1:0]    st2n = p2 - pa2;
```

**Python：**
```python
class Biquad:
    __slots__ = ("b0","b1","b2","a1","a2","s1","s2")

    def step(self, x: int) -> int:
        # RTL: acc = p0 + st1;  yn = sat((acc + RND) >>> SH)
        acc = x * self.b0 + self.s1
        y = sat24((acc + RND) >> SH)

        # RTL: st1' = p1 + st2 - a1*y ; st2' = p2 - a2*y  （AW 位截断）
        self.s1 = wrap_acc(x * self.b1 + self.s2 - y * self.a1)
        self.s2 = wrap_acc(x * self.b2 - y * self.a2)
        return y
```

**逐项对照：**

| RTL | Python | 说明 |
| --- | --- | --- |
| `x * b0`（42 位） | `x * self.b0` | Python 任意精度，正常范围内精确 |
| `acc + RND` | `acc + RND` | RND 常量两边同值 |
| `accr >>> SH` | `(acc + RND) >> SH` | **两边都是 floor 语义，一致** |
| `ovf ? MAXV : ysh[DW-1:0]` | `sat24(...)` | 饱和 |
| `st1 <= ...`（AW 位） | `wrap_acc(...)` | **必须显式模拟位宽截断** |

**最容易漏的是最后一行。** 正常信号下不会触发，但黄金模型应该连异常路径也一致。

## 3. Python 黄金模型的组织方式

**一个文件、一套常量、可被多个脚本导入。**

```
scripts/golden/
├── dsp.py          # 常量 + 定点运算 + 滤波器模型 + 设计函数
└── gen_all.py      # 调用 dsp.py 生成向量和 ROM
```

`dsp.py` 的结构：

```python
# ---- 1. 位宽常量（与 RTL 参数一一对应）----
DW, DF = 24, 23          # 数据 Q1.23
CW, CF = 18, 16          # 系数 Q2.16
AW     = 48              # 累加器
SH     = CF              # 右移量 = 系数小数位（推导见 fixed-point-dsp）
RND    = 1 << (SH - 1)

SAMPLE_MAX = (1 << (DW-1)) - 1
SAMPLE_MIN = -(1 << (DW-1))

# ---- 2. 定点基础运算 ----
def sat24(v): ...        # 饱和
def wrap_acc(v): ...     # AW 位截断
def quant_coef(c, bits=CW, frac=CF): ...   # 浮点 -> 定点 Q 格式

# ---- 3. 位级模型 ----
class Biquad: ...        # 单段，与 RTL 的一个 section 一一对应
class Cascade: ...       # 多段级联，与 RTL 的时分复用顺序一致

# ---- 4. 浮点设计 ----
def peaking_eq(f0, fs, q, gain_db): ...
def first_order_low_shelf(f0, fs, v): ...
def design_band(band_idx, gain_idx): ...

# ---- 5. 分析工具 ----
def check_coef_range(table, bits, frac): ...   # 设计期硬断言
def response_db(table, freqs, fixed=True): ... # 频响评估（注意 a0 缩放）
```

**关键：`dsp.py` 里不能 import numpy 以外的东西**，
保证任何机器上 `python3 scripts/golden/gen_all.py` 就能跑（无 scipy 依赖）。

## 4. 从"算法"到"RTL 参数"的单一真相来源

**位宽常量只在一处定义，RTL 参数和 Python 常量必须一致。**

```
Python dsp.py:  DW=24 DF=23  CW=18 CF=16  AW=48
                      ↕ 必须一致
RTL:  eq_cascade #(.DW(24), .CW(18), .CF(16), .AW(48))
```

**建议加一致性检查**：在 `gen_all.py` 里把参数写进 `*_meta.txt`，
testbench 启动时读出来打印，和 RTL 参数对比。

```
# eq_meta.txt
NSECT=5 NSAMP=6000 DW=24 CW=18
```
```
// testbench 输出
$display(" 样本数=%0d  段数=%0d  数据 Q1.%0d  系数 Q2.%0d", NSAMP, NSECT, DW-1, CF);
```

人眼核对虽然土，但能挡住"改了 Python 忘了改 RTL"这类低级错误。

## 5. 生成 ROM 而不是片上算系数

**片上实时计算滤波器系数需要 sin/cos/sqrt/除法，定点误差难以控制。**
离线用 Python 高精度算好、量化、查表，片上只需一次 ROM 读 + 寄存器写：

```python
# 生成 Verilog ROM（case 语句，自包含，不依赖外部 .mem 文件路径）
for band in range(nband):
    for gi in range(NGAIN):
        sec = design_band(band, gi)
        q = [quant_coef(c) for c in sec]
        base = (band * NGAIN + gi) * 5
        for k in range(5):
            lines.append("  %d'd%d: dout = 18'sh%s;\n" % (aw, base+k, h(q[k], CW)))
```

**为什么用 `case` 而不是 `$readmemh`**：
`$readmemh` 的路径在综合/仿真/换目录时容易失效；
`case` 生成的 ROM 自包含，Vivado 会推断成 LUT ROM 或 BRAM，两边都稳。

**ROM 文件必须标注"自动生成，不要手改"**：

```verilog
// eq_coeff_rom.v - 均衡器系数表（**本文件由 scripts/golden/gen_all.py 自动生成**）
```

## 6. 完整工作流

```bash
# 1. 设计 + 检查 + 生成向量和 ROM（一次脚本搞定）
python3 scripts/golden/gen_all.py
#   输出：
#     频点(Hz) :   20   50   100  300  1000  3000  8000 ...
#     浮点(dB) :  +5.976 +5.537 +2.630 ...
#     定点(dB) :  +6.000 +5.581 +2.678 ...
#     最大定点误差: 0.0481 dB
#   若不达标（>0.1dB）或系数越界 → 脚本 SystemExit，不生成坏 ROM

# 2. 位级对拍
bash scripts/sim/run_iv.sh
#   结果 : *** PASS ***  RTL 与黄金模型完全一致

# 3. 综合验证（组合环、时序、资源）
vivado -mode batch -source scripts/vivado/build.tcl -tclargs <PART> <TOP> <XDC>
```

**第 1 步必须能"失败"**：`gen_all.py` 在系数越界或频响误差超标时
必须 `raise SystemExit`，而不是打印个警告继续生成。
静默生成一个坏 ROM 的排查成本远高于直接报错。

## 7. 常见反模式

| 反模式 | 后果 |
| --- | --- |
| 用浮点模型对拍 | 定点 bug 全部漏掉 |
| 用"误差 < 阈值"而非逐位相等 | 掩盖系统性偏差 |
| 用随机激励 | 覆盖不到边界，失败不可复现 |
| 基准值在错误的时刻锁存 | 全序列差一拍，误判为 RTL 错 |
| 黄金模型与 RTL 位宽常量分头维护 | 改了一边忘了另一边 |
| 系数越界只警告不报错 | 生成坏 ROM，后患无穷 |
| 不导出 RTL 实际输出 | TB 比较逻辑写错时无法区分 |
| 只跑仿真不跑综合 | 组合环漏网 |
