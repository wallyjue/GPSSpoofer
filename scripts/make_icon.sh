#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 GPSSpoofer contributors
# 把 1024×1024 以上的正方形 PNG 轉成 macOS 用的 .icns
# 用法：./scripts/make_icon.sh [輸入 PNG] [輸出 icns]
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="${1:-packaging/AppIcon.png}"
OUT="${2:-build/AppIcon.icns}"

[[ -f "$SRC" ]] || { echo "找不到圖示：$SRC"; exit 1; }
WIDTH=$(sips -g pixelWidth "$SRC" | awk '/pixelWidth/ {print $2}')
HEIGHT=$(sips -g pixelHeight "$SRC" | awk '/pixelHeight/ {print $2}')
if [[ "$WIDTH" != "$HEIGHT" ]]; then
    echo "❌ 圖示必須是正方形，目前是 ${WIDTH}×${HEIGHT}：$SRC"
    exit 1
fi
if (( WIDTH < 1024 )); then
    echo "❌ 圖示至少要 1024×1024，目前是 ${WIDTH}×${HEIGHT}：$SRC"
    exit 1
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET" "$(dirname "$OUT")"
for size in 16 32 128 256 512; do
    sips -z $size $size "$SRC" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) "$SRC" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$OUT"
rm -r "$(dirname "$ICONSET")"
echo "✅ $OUT"
