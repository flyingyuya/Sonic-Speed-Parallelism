#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
mkimage.py —— 把 BMP 图片按固定布局写进 SD 卡的裸扇区

===============================================================================
为什么要这个脚本
-------------------------------------------------------------------------------
FPGA 侧读的是【裸扇区】，不解析 FAT 文件系统（那样要移植一整套 FAT 代码，
代价远大于收益）。所以图片必须按 RTL 约定的偏移直接写进卡的某个位置。

布局（和 rtl/top.v 里的 IMG_SECTOR_BASE 必须一致）：
    扇区 0      ~ 2047     保留（MBR / 分区表 / 原有文件系统，不动）
    扇区 2048   ~ 2559     图 0    （512 扇区 = 256 KB）
    扇区 2560   ~ 3071     图 1
    扇区 3072   ~ 3583     图 2
    ...

RTL 侧算地址的公式（rtl/top.v）：
    rd_sec_addr = IMG_SECTOR_BASE + (ui_img_idx << 9)
                                   = 2048 + 图序号 × 512

每张图占 512 扇区 = 262144 字节。480×272 的 RGB565 需要
480×272×2 = 261120 字节 ⟹ 刚好装得下（剩 1024 字节补零）。

===============================================================================
用法
-------------------------------------------------------------------------------
    # 先看看要写什么（不写卡，只检查）
    python3 mkimage.py --dry-run /dev/sdX img0.bmp img1.bmp img2.bmp

    # 真正写卡（会要求确认，必须输入 YES）
    sudo python3 mkimage.py /dev/sdX img0.bmp img1.bmp img2.bmp

    # 生成几张测试图（画渐变+条纹，方便肉眼判断有没有错位）
    python3 mkimage.py --make-test 3

⚠️ 目标必须是【块设备】（例如 /dev/sdX、/dev/mmcblk0、/dev/disk4），
   不允许直接写普通文件；写卡会覆盖 1 MB 之后的内容，脚本会二次确认。
===============================================================================
"""

import argparse
import os
import struct
import subprocess
import sys

# ---------------------------------------------------------------- 布局常量
SECTOR_SIZE     = 512
IMG_SECTOR_BASE = 2048          # 必须与 rtl/top.v 的 IMG_SECTOR_BASE 一致
IMG_SECTORS     = 512           # 每张图占 512 扇区 = 256 KB
IMG_BYTES       = IMG_SECTORS * SECTOR_SIZE

LCD_W, LCD_H    = 480, 272      # 和 LCD 分辨率一致


def rgb888_to_565(r, g, b):
    """24 位 RGB -> 16 位 RGB565（高位在前，R 占 5 位）"""
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)


def load_bmp(path, want_w=LCD_W, want_h=LCD_H):
    """
    读 24 位无压缩 BMP，返回 RGB565 的小端字节串。

    为什么不用 PIL：这个脚本要能在没装 PIL 的机器上跑（只是转个格式，
    自己解析 BMP 头就够了，20 行）。如果装了 PIL 也可以，但我们不依赖它。
    """
    with open(path, 'rb') as f:
        data = f.read()

    if data[:2] != b'BM':
        raise ValueError(f"{path}: 不是 BMP 文件")

    data_off = struct.unpack_from('<I', data, 10)[0]
    w        = struct.unpack_from('<i', data, 18)[0]
    h        = struct.unpack_from('<i', data, 22)[0]
    bpp      = struct.unpack_from('<H', data, 28)[0]
    comp     = struct.unpack_from('<I', data, 30)[0]

    if comp != 0:
        raise ValueError(f"{path}: 只支持无压缩 BMP（当前压缩方式 {comp}）")
    if bpp != 24:
        raise ValueError(f"{path}: 只支持 24 位 BMP（当前 {bpp} 位）")

    if (w, abs(h)) != (want_w, want_h):
        raise ValueError(
            f"{path}: 尺寸是 {w}x{abs(h)}，需要 {want_w}x{want_h}\n"
            f"        （可以用 --resize 让脚本帮你缩放，或者在 PC 上先处理好）")

    flip = h > 0                      # 正的 BMP 是自下而上存的
    row_bytes = ((w * 3 + 3) // 4) * 4
    out = bytearray(want_w * want_h * 2)

    for y in range(want_h):
        src_y = (want_h - 1 - y) if flip else y
        row = data_off + src_y * row_bytes
        for x in range(want_w):
            off = row + x * 3
            b = data[off]
            g = data[off + 1]
            r = data[off + 2]
            v = rgb888_to_565(r, g, b)
            o = (y * want_w + x) * 2
            out[o]     = v & 0xFF          # 小端：低字节在前
            out[o + 1] = (v >> 8) & 0xFF
    return bytes(out)


def make_test_image(idx, path):
    """画一张测试图：渐变 + 网格 + 序号色块（方便看错位/偏移）"""
    row_bytes = ((LCD_W * 3 + 3) // 4) * 4
    pixel_data = bytearray()
    for y in range(LCD_H - 1, -1, -1):          # BMP 自下而上
        row = bytearray()
        for x in range(LCD_W):
            r = (x * 255) // LCD_W
            g = (y * 255) // LCD_H
            b = 64 + 40 * idx
            if (x % 60) < 2 or (y % 40) < 2:     # 网格线
                r = g = b = 255
            if (x - 20) ** 2 + (y - 20) ** 2 < 400:  # 左上角标记点
                r = g = b = 0
            row += bytes([b & 0xFF, g & 0xFF, r & 0xFF])
        row += b'\x00' * (row_bytes - len(row))
        pixel_data += row

    file_size = 54 + len(pixel_data)
    hdr = bytearray(54)
    hdr[0:2] = b'BM'
    struct.pack_into('<I', hdr, 2, file_size)
    struct.pack_into('<I', hdr, 10, 54)
    struct.pack_into('<I', hdr, 14, 40)
    struct.pack_into('<i', hdr, 18, LCD_W)
    struct.pack_into('<i', hdr, 22, LCD_H)
    struct.pack_into('<H', hdr, 26, 1)
    struct.pack_into('<H', hdr, 28, 24)
    struct.pack_into('<I', hdr, 30, 0)
    struct.pack_into('<I', hdr, 34, len(pixel_data))

    with open(path, 'wb') as f:
        f.write(hdr)
        f.write(pixel_data)


def is_system_disk(dev):
    """
    判断 dev 是不是"装了操作系统的那块盘"。

    为什么必须检查：这个脚本会覆盖目标设备 1 MB 之后的内容
    （480x272 的图就在这个位置）。如果手滑写成 /dev/sda 而 sda 是系统盘，
    分区表和文件系统会被毁掉。
    这里比较的是【整盘名】，所以 /dev/sda1 这种分区名也会被挡。
    """
    try:
        root = subprocess.run(['findmnt', '-n', '-o', 'SOURCE', '/'],
                              capture_output=True, text=True, timeout=5).stdout.strip()
        # findmnt 可能返回 /dev/nvme0n1p2[/@] 这种形式，取 /dev/ 前的部分
        if '[' in root:
            root = root.split('[')[0]
        if not root:
            return False
        pk = subprocess.run(['lsblk', '-no', 'PKNAME', root],
                            capture_output=True, text=True, timeout=5).stdout.strip()
        if not pk:
            return False
        return os.path.realpath(dev) == os.path.realpath('/dev/' + pk)
    except Exception:
        return False


def make_channel_image(path):
    """
    生成"通道识别图"：4 条纯色竖条，用来一次定死颜色通道顺序。

      第 1 条（最左）：纯红   (255,0,0)
      第 2 条：纯绿   (0,255,0)
      第 3 条：纯蓝   (0,0,255)
      第 4 条（最右）：纯白 (255,255,255)

    怎么判读（假设 LCD 朝向正常、左→右）：
      · 看到 红 绿 蓝 白  ⟹ 颜色通道完全正确 ✓
      · 看到 蓝 绿 红 白  ⟹ R 和 B 交换了（BGR 当成 RGB）
      · 看到 绿 红 蓝 白  ⟹ R 和 G 交换
      · 看到 白 蓝 绿 红  ⟹ 整幅左右翻转
      · 颜色都像但偏暗/偏亮 ⟹ 位扩展（5/6 位到 8 位）的方式有问题
    """
    bars = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 255)]
    bar_w = LCD_W // 4
    row_bytes = ((LCD_W * 3 + 3) // 4) * 4
    pixel_data = bytearray()
    for y in range(LCD_H - 1, -1, -1):
        row = bytearray()
        for x in range(LCD_W):
            idx = min(x // bar_w, 3)
            r, g, b = bars[idx]
            if y < 4 or y >= LCD_H - 4:      # 上下各留 4 行黑边，便于判断方向
                r = g = b = 0
            row += bytes([b, g, r])
        row += b'\x00' * (row_bytes - len(row))
        pixel_data += row

    file_size = 54 + len(pixel_data)
    hdr = bytearray(54)
    hdr[0:2] = b'BM'
    struct.pack_into('<I', hdr, 2, file_size)
    struct.pack_into('<I', hdr, 10, 54)
    struct.pack_into('<I', hdr, 14, 40)
    struct.pack_into('<i', hdr, 18, LCD_W)
    struct.pack_into('<i', hdr, 22, LCD_H)
    struct.pack_into('<H', hdr, 26, 1)
    struct.pack_into('<H', hdr, 28, 24)
    struct.pack_into('<I', hdr, 30, 0)
    struct.pack_into('<I', hdr, 34, len(pixel_data))
    with open(path, 'wb') as f:
        f.write(hdr)
        f.write(pixel_data)


def write_card(dev, images, dry_run=False):
    if os.path.isdir(dev):
        sys.exit(f"错误: {dev} 是目录（macOS 上要写 /dev/diskX 而不是 /Volumes/...）")
    if not os.path.exists(dev):
        sys.exit(f"错误: {dev} 不存在")

    # 安全闸：绝不允许写系统盘
    if is_system_disk(dev):
        sys.exit(f"\n🚨 拒绝执行：{dev} 是【系统盘】（装了操作系统的盘）。\n"
                 f"   写它会毁掉你的系统。请用 lsblk 确认 SD 卡的设备名。\n")

    total = IMG_SECTOR_BASE * SECTOR_SIZE + len(images) * IMG_BYTES
    print(f"目标设备 : {dev}")
    print(f"图片数量 : {len(images)}")
    print(f"写入范围 : 扇区 {IMG_SECTOR_BASE} 起，共 {len(images) * IMG_SECTORS} 扇区")
    print(f"写入长度 : {len(images) * IMG_BYTES / 1024 / 1024:.2f} MB")
    print(f"结束位置 : {total / 1024 / 1024:.2f} MB 处")
    print()

    for i, (name, blob) in enumerate(images):
        sec = IMG_SECTOR_BASE + i * IMG_SECTORS
        print(f"  图 {i}: {name:30s} -> 扇区 {sec:6d} (0x{sec * SECTOR_SIZE:08X})"
              f"  {len(blob)} 字节")

    if dry_run:
        print("\n--dry-run：只检查，不写卡")
        return

    print("\n⚠️  这会覆盖卡上 1 MB 之后的内容！")
    if input("确认写入请输入 YES: ").strip() != "YES":
        sys.exit("已取消")

    with open(dev, 'r+b') as f:
        for i, (name, blob) in enumerate(images):
            off = (IMG_SECTOR_BASE + i * IMG_SECTORS) * SECTOR_SIZE
            f.seek(off)
            f.write(blob)
            # 补零到整块（保证 512 扇区对齐，避免残留旧图边缘）
            pad = IMG_BYTES - len(blob)
            if pad > 0:
                f.write(b'\x00' * pad)
            print(f"  已写 图 {i} @ 0x{off:08X}")
        f.flush()
        os.fsync(f.fileno())

    print("\n完成。FPGA 侧：IMG_SECTOR_BASE = "
          f"{IMG_SECTOR_BASE}，每张图 {IMG_SECTORS} 扇区。")


def main():
    ap = argparse.ArgumentParser(
        description="把 BMP 按固定布局写进 SD 卡裸扇区")
    ap.add_argument('device', nargs='?', help='目标块设备（如 /dev/sdX）')
    ap.add_argument('images', nargs='*', help='BMP 文件（顺序 = 图序号）')
    ap.add_argument('--dry-run', action='store_true', help='只检查，不写卡')
    ap.add_argument('--make-test', type=int, metavar='N',
                    help='生成 N 张测试图 test0.bmp..testN-1.bmp')
    ap.add_argument('--make-channel', metavar='FILE',
                    help='生成通道识别图（4 条纯色竖条：红/绿/蓝/白）')
    args = ap.parse_args()

    if args.make_channel:
        make_channel_image(args.make_channel)
        print(f"已生成 {args.make_channel}（红/绿/蓝/白 四条竖条）")
        return

    if args.make_test:
        for i in range(args.make_test):
            p = f"test{i}.bmp"
            make_test_image(i, p)
            print(f"已生成 {p}  ({LCD_W}x{LCD_H} 24 位 BMP)")
        return

    if not args.device or not args.images:
        ap.print_help()
        sys.exit(1)

    loaded = []
    for p in args.images:
        blob = load_bmp(p)
        loaded.append((os.path.basename(p), blob))

    write_card(args.device, loaded, dry_run=args.dry_run)


if __name__ == '__main__':
    main()
