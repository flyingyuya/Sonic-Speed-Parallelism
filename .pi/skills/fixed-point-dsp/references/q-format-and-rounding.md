# Q 格式、舍入、饱和：RTL 与 Python 的位级对齐

> 目标：**Python 黄金模型与 RTL 逐位相等**（用 `!==` 比较，不是阈值）。
> 这要求 Python 里每一处舍入/饱和/移位都与 Verilog 语义严格对应。

## 1. 标度推导（一次推清楚，永久复用）

设：
- 数据 `signed [DW-1:0]`，值 = `raw × 2^-DF`（即 Q(DW-DF-1).DF）
- 系数 `signed [CW-1:0]`，值 = `raw × 2^-CF`

```
乘积 raw   = X_raw × B_raw
乘积 值    = (X_raw·2^-DF) × (B_raw·2^-CF) = X_raw·B_raw · 2^-(DF+CF)
```

要还原成数据标度（乘 `2^DF`）：

```
y_raw = 乘积值 × 2^DF = X_raw·B_raw · 2^-(CF)
```

**结论：右移量 = CF，与数据位宽无关。**

```verilog
localparam integer SH  = CF;
localparam [AW-1:0] RND = {{(AW-1){1'b0}}, 1'b1} << (SH-1);   // 2^(CF-1)
```

本项目参数：`DW=24, DF=23`（Q1.23），`CW=18, CF=16`（Q2.16），
`SH=16`，`RND=2^15`，`AW=48`。

## 2. 四舍五入：Verilog `>>>` 与 Python `>>` 语义一致

| 运算 | 负数行为 |
| --- | --- |
| Verilog `>>>`（算术右移） | 向下取整（floor），**不是**向零取整 |
| Python `>>` | 向下取整（floor） |
| C 语言 `>>`（有符号） | 实现定义，通常也是算术移位 |

所以加半个 LSB 再算术右移 = 四舍五入，两边语义完全一致：

```verilog
wire signed [AW-1:0] accr = acc + RND;
wire signed [AW-1:0] ysh  = accr >>> SH;
```
```python
RND = 1 << (SH - 1)
y = (acc + RND) >> SH          # Python 的 >> 对负数就是 floor，一致
```

**不要把 `>>>` 换成除法 `/`** —— Verilog 的 `/` 是向零取整，语义不同。

## 3. 饱和

```verilog
localparam signed [DW-1:0] MAXV = {1'b0, {(DW-1){1'b1}}};   // +2^(DW-1)-1
localparam signed [DW-1:0] MINV = {1'b1, {(DW-1){1'b0}}};   // -2^(DW-1)

wire ovf_p = (ysh > MAXV);
wire ovf_n = (ysh < MINV);
wire signed [DW-1:0] yn = ovf_p ? MAXV : (ovf_n ? MINV : ysh[DW-1:0]);
```

比较时 `MAXV` 会被符号扩展到 `AW` 位（两边同为 signed，取最大宽度）——
Verilog 的表达式位宽规则保证了这一点。

```python
def sat24(v):
    return max(SAMPLE_MIN, min(SAMPLE_MAX, v))
```

**必须专门构造触发饱和的测试激励**（满量程方波、正负极值），
否则 `ovf_p` / `ovf_n` 两个分支永远不被覆盖。

## 4. 累加器的隐式截断

RTL 里状态寄存器是 `AW` 位，超出会被截断（回绕）。Python 是任意精度整数，
**必须显式模拟截断**，否则两边会在极端输入下分叉：

```python
ACC_MASK = (1 << AW) - 1

def wrap_acc(v):
    """把 Python 整数截断到 AW 位有符号，模拟 RTL 寄存器赋值。"""
    v &= ACC_MASK
    if v >= (1 << (AW - 1)):
        v -= (1 << AW)
    return v
```

正常信号下永远不会触发（乘积只有 42 位，累加器 48 位），
但**黄金模型应该连异常路径也一致**，否则测试失去意义。

## 5. 位级对齐检查表

写定点黄金模型时逐项核对：

| RTL 语句 | Python 对应 |
| --- | --- |
| `wire signed [DW+CW-1:0] p = x * b;` | `x * b`（Python 整数乘法精确） |
| `wire signed [AW-1:0] acc = p0 + st1;` | `p0 + s1` |
| `ysh = (acc + RND) >>> SH;` | `(acc + RND) >> SH` |
| `yn = ovf ? MAXV : ysh[DW-1:0];` | `sat24(...)` |
| `st1 <= wrap(...)`（AW 位截断） | `wrap_acc(...)` |
| 有符号常量的符号扩展 | Python 无需处理（任意精度） |

## 6. 逐位对拍 testbench 要点

```verilog
// 1. 逐位比较用 !==（区分 X/Z，且是"完全相等"而非"逻辑相等"）
if (y_out !== yv[n_out]) errors = errors + 1;

// 2. 同时导出 RTL 实际输出，供 Python 侧二次核对
//    （不依赖 testbench 自身的比较逻辑，避免"比较代码本身写错"）
fd = $fopen("sim/vectors/eq_out_rtl.hex", "w");
for (i = 0; i < n_out; i = i + 1) $fdisplay(fd, "%06x", ycap[i]);
$fclose(fd);
```

**为什么要导出实际输出**：如果 testbench 的比较逻辑写错（比如读错数组、
对齐错一拍），它会报 FAIL，但真实原因可能是 TB 的问题。
有原始输出文件就能离线交叉验证。

## 7. 负数十六进制向量的写法

`$readmemh` 读入 `reg signed [DW-1:0]`：

```python
def h(value, bits):
    """负数取二进制补码，输出固定宽度 hex。"""
    return format(value & ((1 << bits) - 1), "0%dx" % ((bits + 3) // 4))

h(-1, 24)     # → 'ffffff'
h(-8388608, 24)  # → '800000'
h(8388607, 24)   # → '7fffff'
```

写入的位宽可以是 2 的幂以外的宽度（如 18 位 → 5 个 hex 位 = 20 位），
`readmemh` 会取低位，对二进制补码结果是正确的。
