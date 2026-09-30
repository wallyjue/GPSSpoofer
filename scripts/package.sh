#!/bin/zsh
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 GPSSpoofer contributors
# 產生可發布的 build/GPSSpoofer-<版本>.dmg：helper 以 PyInstaller 打包成獨立執行檔，不依賴使用者的 Python。
#
# 用法：
#   ./scripts/package.sh                          # ad-hoc 簽署，給自己或朋友測試
#   SIGN_IDENTITY="Developer ID Application: 名字 (TEAMID)" ./scripts/package.sh
#                                                 # 正式簽署（hardened runtime），之後再公證
#   VERSION=0.2.0 ./scripts/package.sh            # 指定版本號
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP="build/GPSSpoofer.app"
DMG="build/GPSSpoofer-${VERSION}.dmg"
PYI="build/pyinstaller"

[[ -x .venv/bin/python ]] || { echo "請先執行 scripts/setup.sh"; exit 1; }
.venv/bin/python -m pip install -q pyinstaller

echo "▶︎ 1/5 打包 Python helper"
.venv/bin/pyinstaller --noconfirm --log-level WARN --onedir --name location_helper \
    --collect-all pymobiledevice3 --recursive-copy-metadata pymobiledevice3 \
    --distpath "$PYI/dist" --workpath "$PYI/work" --specpath "$PYI" \
    helper/location_helper.py

echo "▶︎ 2/5 編譯 Swift App"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/GPSSpoofer"

echo "▶︎ 3/5 組裝 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/helper"
cp "$BIN" "$APP/Contents/MacOS/GPSSpoofer"
ditto "$PYI/dist/location_helper" "$APP/Contents/Resources/helper/location_helper"
cp packaging/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
if [[ -f packaging/AppIcon.png ]]; then
    ./scripts/make_icon.sh packaging/AppIcon.png "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
else
    echo "⚠️ 沒有 packaging/AppIcon.png，App 會使用系統預設圖示"
fi
# GPL 與內附套件的授權聲明必須隨二進位檔一起散布
.venv/bin/python scripts/collect_licenses.py "$PYI/dist/location_helper/_internal" build/THIRD_PARTY_LICENSES.txt
cp LICENSE build/THIRD_PARTY_LICENSES.txt "$APP/Contents/Resources/"

echo "▶︎ 4/5 簽署（$SIGN_IDENTITY）"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
HELPER_DIR="$APP/Contents/Resources/helper/location_helper"

# 由內而外：先簽所有函式庫，再簽 Python.framework、helper 執行檔，最後簽整個 App
find "$HELPER_DIR/_internal" -type f \( -name "*.so" -o -name "*.dylib" \) -not -path "*/Python.framework/*" -print0 |
    xargs -0 -n 50 codesign "${SIGN_ARGS[@]}"
if [[ -d "$HELPER_DIR/_internal/Python.framework" ]]; then
    codesign "${SIGN_ARGS[@]}" "$HELPER_DIR/_internal/Python.framework"
fi
codesign "${SIGN_ARGS[@]}" --entitlements packaging/helper.entitlements "$HELPER_DIR/location_helper"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"

echo "▶︎ 5/5 製作 DMG"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/GPSSpoofer.app"
ln -s /Applications "$STAGING/Applications"
cp LICENSE "$STAGING/LICENSE.txt"
cp build/THIRD_PARTY_LICENSES.txt "$STAGING/"
rm -f "$DMG"
hdiutil create -quiet -volname "GPSSpoofer $VERSION" -srcfolder "$STAGING" -format UDZO "$DMG"
if [[ "$SIGN_IDENTITY" != "-" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" --timestamp "$DMG"
    echo "下一步公證：xcrun notarytool submit $DMG --keychain-profile <profile> --wait && xcrun stapler staple $DMG"
fi

echo "✅ $(pwd)/$DMG（$(du -h "$DMG" | cut -f1)）"
