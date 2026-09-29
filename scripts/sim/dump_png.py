#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
dump_png.py —— 把仿真导出的 PPM 转成 PNG 放进 docs/images/

用法：
    bash scripts/sim/run_iv.sh disp_top      # 先跑仿真，生成 sim/build/disp_frame.ppm
    python3 scripts/sim/dump_png.py          # 再转成 docs/images/disp_frame.png

为什么要有这一步：
    sim/build/ 被 .gitignore 忽略（那是临时产物），
    但文档里要引用图片，所以必须把图落到一个【被跟踪】的位置。
"""
import os, shutil, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC  = os.path.join(ROOT, 'sim', 'build', 'disp_frame.ppm')
DSTD = os.path.join(ROOT, 'docs', 'images')

if not os.path.exists(SRC):
    print(f"错误：找不到 {SRC}")
    print("      先跑 `bash scripts/sim/run_iv.sh disp_top` 生成它。")
    sys.exit(1)

os.makedirs(DSTD, exist_ok=True)
dst = os.path.join(DSTD, 'disp_frame.png')

try:
    from PIL import Image
    im = Image.open(SRC)
    im.save(dst)
    print(f"  {SRC}  ->  {dst}   ({im.size[0]}x{im.size[1]} {im.mode})")
except ImportError:
    # 没有 PIL 就用 ImageMagick 兜底
    if shutil.which('convert'):
        os.system(f"convert {SRC} {dst}")
        print(f"  {SRC}  ->  {dst}   (ImageMagick)")
    else:
        print("错误：既没有 PIL 也没有 ImageMagick")
        sys.exit(1)
