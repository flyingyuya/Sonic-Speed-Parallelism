# 仿真失败排查手册

> 按现象查找，不要乱改。**每次只改一个变量，改完立刻重跑。**

---

## 决策树

```
仿真结果不对
├── 输出全零 / 计数器不增长
│   └─▶ A. 信号悬空或时钟没动
├── 输出全对但数量不对（少了/多了）
│   └─▶ B. 握手/流控问题
├── 输出整体差一拍（平移）
│   └─▶ C. 期望值锁存时刻错
├── 输出形状对但数值差一点
│   └─▶ D. 定点格式/舍入问题
├── 输出完全对不上
│   └─▶ E. 算法或位序问题
└── 编译就失败
    └─▶ F. 语法/声明顺序/参数问题
```

---

## A. 输出全零 / 计数器不增长

**首要怀疑：testbench 引用了被测模块的内部信号，但该信号没有引出成端口。**

未引出端口的内部信号在 TB 顶层是悬空的 `z`：

```verilog
// tb 里：
audio_top dut (... .dbg_frame_start(frame_start) ...);
// 如果 audio_top 没有 dbg_frame_start 端口，这里的 frame_start 恒为 z

// 行为模型里的判断：
if (frame_start) ...     // 恒假 → 永远不动作 → 输出全零
```

**排查步骤：**
1. 在 TB 里 `$display` 这个信号的当前值，看是不是 `z` 或 `x`
2. `$dumpfile`/`$dumpvars` 然后在波形里看
3. 检查被测模块是否真的有这个端口（`grep <signal> rtl/xxx.v`）

**修法**：给被测模块加一组 `dbg_*` 观测端口（综合时会被优化掉，或给 ILA 用）。

**其他可能：**
- 时钟根本没产生（`always #5 clk = ~clk;` 忘了写，或 `initial` 没启动）
- 复位没释放（`rst_n` 一直是 0）
- 使能条件里多了一个恒假的项（如 `running` 在配置完成前恒为 0）

---

## B. 输出数量不对

| 现象 | 原因 | 排查 |
| --- | --- | --- |
| 输出比输入少 | 上游 valid 来时下游没 ready，被丢弃 | 看是否有 FIFO 溢出；检查 `x_ready` 握手 |
| 输出比输入多 | 下游空转时重复输出 | FIFO 欠载时是否 `data_en=0` 保持而不是输出零 |
| 输出数量刚好差一个 | 首/末样本的边界处理 | 复位后第一个事务可能不完整，跳过前 2 个再判定 |

**握手正确的写法（TB 侧驱动）：**
```verilog
@(posedge clk);
while (!x_ready) @(posedge clk);   // 等下游能收
x_in    <= data;
x_valid <= 1'b1;
@(posedge clk);                    // 保持一个周期
x_valid <= 1'b0;
```

**握手的经典 bug（RTL 侧）**：把 `full`/`ready` 用组合逻辑派生自
**下一拍的指针**，形成组合环。必须用**已寄存的指针**译码。

---

## C. 整体差一拍

**症状**：`RTL[0] == 期望[1]`，或差 N 拍；数据形状完全一致。

**排查：期望值是在哪个沿锁存的？**

```
帧结构：frame_start(本帧起点) → ... → half_start(半帧) → ... → 帧尾捕获
```

```verilog
// ✗ 错：在「下一次事务准备」的沿更新期望值
if (half_start) exp <= pat(fidx + 1);
//  下一帧的 half_start 早于本帧的帧尾捕获 → 提前一拍

// ✓ 对：在「事务开始」的沿锁存本帧实际发送的值
if (frame_start) exp <= adc_l[SLOT-1 -: DW];
```

**通用原则：期望值在"事务开始"的沿锁存。**

**另一类差一拍**：DUT 端的握手信号与时钟沿选通不同拍：

```verilog
// ✗ 一个是寄存器输出，一个是组合输出
always @(posedge clk) frame_start <= (bcnt == NLAST);
assign bclk_fall = (divcnt == 0);          // 不同拍！

// ✓ 让二者同拍（都用组合）
assign frame_start = bclk_fall & (bcnt == NLAST);
```

---

## D. 形状对但数值差一点

**按误差量级定位：**

| 误差量级 | 原因 |
| --- | --- |
| 整体偏移几 dB | **系数量化削顶**（Q 格式范围不够）→ 加 `check_coef_range` 硬断言 |
| 固定偏移一点 | 舍入方式不同（截断 vs 四舍五入）→ 检查 `>>>` 与 `>>` 语义 |
| 低频段误差特别大 | 滤波器结构条件数差（如低架在近 DC 的 w0² 相消） |
| 只有极端值错 | 饱和分支实现错 |
| 差值恒为 ±1 LSB | 舍入偏置常量差 1（`1<<(SH-1)` vs `1<<SH`） |

**排查工具：用定点系数算频响，与浮点对比**
```python
# 注意 a0 必须用同一标度，否则虚报巨大误差
A0 = float(1 << CF)
H = (b0 + b1*z + b2*z*z) / (A0 + a1*z + a2*z*z)
```

**Sanity check**：定点误差应随精度提高**单调下降**。
若高精度反而误差大，一定是评估代码错了。

---

## E. 完全对不上

| 现象 | 原因 |
| --- | --- |
| 左右声道内容互换 | 帧内 L/R 顺序搞反（I2S 里 LRCLK 低=左，第一个 32 位是左声道） |
| 只有某些段正常 | 系数 ROM 地址算错 / 装载 FSM 的段序号错 |
| 只有某些增益档正常 | 只检查了部分档位的系数范围，某些档越界被削顶 |
| 系数写错位置 | 系数端口地址映射不一致（`sect*5 + k` 的 k 顺序） |
| 数据位序颠倒 | 移位寄存器的 MSB/LSB 方向搞反 |

**排查：dump 内部状态**

```verilog
// 直接层次访问 DUT 内部寄存器（iverilog 支持）
$display("gain_reg=%0d  st=%0d  ld_cnt=%0d", dut.gain_reg, dut.st, dut.ld_cnt);
for (i = 0; i < 25; i = i + 1)
    $display("  coe[%0d] = %0d", i, $signed(dut.u_eq_l.coe[i]));
```

**实战案例**：端到端对拍只有 `band0` 系数是错的，其余全对。
→ 说明装载 FSM 在**中途换了档位**：`cfg_load` 处理逻辑直接写了
`gain_reg <= band_gain`，而 FSM 正在按 `ld_cnt` 顺序读地址，
前 5 个（band0）用旧档、后 20 个用新档。
**修法：请求只置 `dirty`，`gain_reg` 在装载开始时整批锁存。**

**这个 bug 的启发**：`wait(running)` 如果在上电时就为真，
会在配置窗口内继续灌数据 —— 必须 `wait(cfg_busy); wait(running);`。

---

## F. 编译失败

| 报错 | 原因 |
| --- | --- |
| `Unable to bind wire/reg/memory 'xxx'` | **先用后声明**。Verilog 要求 net 先声明；把 wire 声明全部前置到模块顶部 |
| `Port N of module expects 1 bit(s), given 32` | 端口位宽不匹配，常见于直接传字面量 `0` 给 1 位端口 → 用显式 wire |
| `Part select out of range` | 索引越界（如 `bcnt==63` 时算 `62-bcnt` 得 -1）→ 用选择器保证索引合法 |
| `warning: Port ... is not connected` | 端口忘了接，检查实例化 |
| 参数运算报错 | 对 `integer` 型 localparam 做位选（如 `NFRAME[5:0]`）→ 定义单独的向量型 localparam |

**避免先用后声明**：把模块内所有 `wire` 声明集中放在实例化之前。

```verilog
module audio_top (...);
    // ---- 声明区（全部前置）----
    wire a, b;
    wire [7:0] c;
    wire ready_w, valid_w;

    // ---- 逻辑与实例化 ----
    assign a = ...;
    submod u_sub (...);
endmodule
```

---

## 收尾检查清单（仿真 PASS 之后）

仿真通过**不代表设计正确**。收尾必做：

- [ ] 跑 Vivado 综合，检查 `LUTLP-1`（组合环）= 0
- [ ] 确认资源占用能用手算解释（DSP 个数 = 并行乘法器个数）
- [ ] 确认没有 `warning` 级别的悬空端口
- [ ] 确认测试覆盖了饱和分支
- [ ] 确认测试覆盖了复位后的第一个事务
- [ ] `git status` 干净（产物都被忽略）
