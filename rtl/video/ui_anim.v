//=============================================================================
// ui_anim.v - 属性插值器（UI 三件套之一）
//-----------------------------------------------------------------------------
// 【解决什么问题】
//   现在按 KEY1 切视图预设，屏幕上是【硬跳】：极坐标"啪"地出现 / 消失。
//   这在 12 ms 一帧的液晶上看着很生硬，也不像成品设备。
//
//   这个模块给每个视图维护一个 0..FULL 的"存在度"（level），每帧朝目标
//   走一小步。显示链把几何量乘以 level/FULL，画面就是【平滑地长出来 / 缩回去】。
//
//      目标 = 1  ──每帧 +STEP──▶ 128    （视图展开）
//      目标 = 0  ──每帧 -STEP──▶   0    （视图收起）
//
//   STEP=4、FULL=128 -> 32 帧 -> 32 x 12.01ms ≈ 384 ms，观感正好。
//
// 【为什么可以这么便宜】
//   本工程的显示是"扫描到哪算到哪"，没有 framebuffer —— 不需要为过渡
//   准备一帧缓冲区，也不需要把两个画面渲染两遍再做 alpha 混合。
//   插值的是【几何标量】（柱高系数、波形幅度、圆盘半径），
//   它们是每帧只变一次的慢变量，插值逻辑本身只有几个加减法。
//
// 【为什么用 0..128 而不是 0..255】
//   因为显示侧要算 `x * level / FULL`。FULL=128 时除以 128 就是右移 7 位，
//   零成本；用 255 就得真除法或近似，反而更贵且不精确。
//   level 用 8 位存，只是为了让外部拼接方便。
//
// 【为什么必须有 frame 门控】
//   level 是"每帧走一步"。如果没有 frame 脉冲而是每个 clk_pix 都走，
//   过渡会在几十微秒内结束 —— 和硬跳没区别，还多耗了翻转功耗。
//   所以本模块【只在 frame 那一拍更新】。
//=============================================================================
`timescale 1ns/1ps

module ui_anim #(
    parameter integer NCH  = 3,     // 通道数（本项目 = 三个视图）
    parameter integer FULL = 128,   // 满值（必须是 2 的幂，显示侧才好用移位除）
    parameter integer STEP = 4      // 每帧步进（FULL/STEP = 过渡帧数）
) (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 frame,          // 每帧一个脉冲（显示侧的 sof）

    input  wire [NCH-1:0]       target,         // 1 = 该通道展开
    output reg  [NCH*8-1:0]     level           // 每通道 8 位，取值 0..FULL
);

    integer i;

    always @(posedge clk) begin
        if (!rst_n) begin
            level <= {(NCH*8){1'b0}};
        end else if (frame) begin
            // 只在帧起始更新 —— 见文件头"为什么必须有 frame 门控"
            for (i = 0; i < NCH; i = i + 1) begin
                if (target[i]) begin
                    // 向上：钳到 FULL 就停（不能回绕，否则会突然掉回 0）
                    if (level[i*8 +: 8] > FULL - STEP)
                        level[i*8 +: 8] <= FULL[7:0];
                    else
                        level[i*8 +: 8] <= level[i*8 +: 8] + STEP[7:0];
                end else begin
                    // 向下：钳到 0 就停
                    if (level[i*8 +: 8] < STEP[7:0])
                        level[i*8 +: 8] <= 8'd0;
                    else
                        level[i*8 +: 8] <= level[i*8 +: 8] - STEP[7:0];
                end
            end
        end
    end

endmodule
