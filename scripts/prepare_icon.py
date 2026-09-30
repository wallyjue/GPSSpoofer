#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 GPSSpoofer contributors
"""
把 AI 生成的「白底 + 圓角方形」圖示整理成 macOS 26 以後的規格：
取出圓角方形的內部，輸出滿版、不透明的 1024×1024 PNG，交給系統自己套用圓角遮罩。

macOS 26 以後，如果舊式 .icns 自帶圓角或透明邊距，系統會把它裝進灰色外框；
只有滿版方形才會被直接套用系統的圓角遮罩。

用法：.venv/bin/python scripts/prepare_icon.py [輸入] [輸出]
      預設 packaging/AppIcon-original.png → packaging/AppIcon.png
"""

import sys

from PIL import Image, ImageChops

CANVAS = 1024
# 往內裁掉的比例：去掉原圖的圓角與玻璃邊框，系統遮罩會再裁掉四角
INSET_RATIO = 0.07


def find_body_bbox(image: Image.Image) -> tuple[int, int, int, int]:
    """以「藍色明顯多於紅色」的像素找出主體範圍，避開白底與灰色陰影。"""
    r, _, b = image.convert("RGB").split()
    bbox = ImageChops.subtract(b, r).point(lambda v: 255 if v > 60 else 0).getbbox()
    if bbox is None:
        raise SystemExit("找不到圖示主體")
    return bbox


def main() -> None:
    src = sys.argv[1] if len(sys.argv) > 1 else "packaging/AppIcon-original.png"
    dst = sys.argv[2] if len(sys.argv) > 2 else "packaging/AppIcon.png"

    image = Image.open(src).convert("RGB")
    left, top, right, bottom = find_body_bbox(image)
    side = min(right - left, bottom - top)
    inset = side * INSET_RATIO
    cx, cy = (left + right) / 2, (top + bottom) / 2
    half = side / 2 - inset
    box = tuple(round(v) for v in (cx - half, cy - half, cx + half, cy + half))

    image.crop(box).resize((CANVAS, CANVAS), Image.LANCZOS).save(dst)
    print(f"✅ {dst}（{CANVAS}×{CANVAS}，滿版方形）")


if __name__ == "__main__":
    main()
