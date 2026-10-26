#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 GPSSpoofer contributors
# 開發用：編譯 release 版並包成 build/GPSSpoofer.app（只能在本機執行，發布請用 package.sh）
# helper 使用專案內的 .venv，所以 .app 搬到別台電腦需要重新執行 setup.sh 與本腳本。
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

[[ -x .venv/bin/python ]] || { echo "請先執行 scripts/setup.sh"; exit 1; }

swift build -c release
BIN="$(swift build -c release --show-bin-path)/GPSSpoofer"

APP="build/GPSSpoofer.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GPSSpoofer"
ditto "$(dirname "$BIN")/GPSSpoofer_GPSSpoofer.bundle" "$APP/Contents/Resources/GPSSpoofer_GPSSpoofer.bundle"
cp helper/location_helper.py "$APP/Contents/Resources/"

cp packaging/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :GPSHelperPython string ${ROOT}/.venv/bin/python" "$APP/Contents/Info.plist"
if [[ -f packaging/AppIcon.png ]]; then
    ./scripts/make_icon.sh packaging/AppIcon.png "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

codesign --force --sign - "$APP" >/dev/null
echo "✅ 已產生 $ROOT/$APP"
