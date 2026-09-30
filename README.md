# iPhone 定位模擬（macOS）

在 Mac 上用地圖選點，修改已開啟「開發者模式」的 iPhone 所回報的 GPS 位置。
原理和 Xcode 的「Simulate Location」相同，走 DVT `LocationSimulation` 服務。

```
SwiftUI + MapKit App ──stdin/stdout JSON──▶ helper/location_helper.py ──▶ pymobiledevice3 ──USB──▶ iPhone
```

## 需求

- macOS 14 以上、Python 3.10 以上、Swift（Command Line Tools 即可）
- iPhone 已信任這台 Mac，且「設定 → 隱私權與安全性 → 開發者模式」已開啟

## 安裝與執行

```bash
./scripts/setup.sh        # 建立 .venv 並安裝 pymobiledevice3
./scripts/build_app.sh    # 產生 build/GPSSpoofer.app
open build/GPSSpoofer.app
```

開發時也可以直接在專案根目錄執行 `swift run`。

## 使用方式

1. 用 USB 接上 iPhone，按「重新整理」→ 選擇裝置 →「連線」。
   第一次連線會下載並掛載 Developer Disk Image，大約需要數十秒。
2. **點地圖**：放下目標點；開啟「點擊地圖後立即傳送」時，會直接套用到 iPhone。
3. **輸入經緯度**：填入緯度 / 經度（也可以把 `25.03, 121.56` 整串貼到緯度欄），
   按「移動地圖到此座標」讓視圖跳過去，再按「傳送目標座標到 iPhone」。
4. **搜尋地點**：在「搜尋地點」輸入店名或地址後按 Enter，會以目前地圖範圍為中心搜尋，
   並自動移到第一筆結果。點其他結果可以切換；按 ⊕ 會加入路線。
5. **多點路線**：地圖上方切到「新增路線點」後，點地圖依序加點，
   或從搜尋結果、「把目標加入路線」加入。在側邊欄「多點路線」分頁可以：
   - 調整順序、刪除路線點，並查看全程距離與預估時間
   - 設定速度（1–120 km/h，有步行、慢跑、單車、汽車快捷鍵），移動途中調整會立即生效
   - 選擇抵達終點後要停止、回到起點循環，還是來回往返
   - 開始、暫停、停止；iPhone 每秒更新一次位置，地圖可以設定跟著移動
6. 「還原真實定位」或「中斷連線」會讓 iPhone 回到真實 GPS。

> iOS 17 以後，模擬定位只在連線期間有效。App 關閉後 iPhone 會自動恢復真實位置。

## 連線方式（iOS 17+）

helper 會依序嘗試，全程不需要 sudo：

1. macOS native tunnel（借用系統 `remoted` 的 tunnel）
2. pymobiledevice3 userspace tunnel
3. `tunneld`：前兩者都失敗時，另外執行 `sudo .venv/bin/pymobiledevice3 remote tunneld`

iOS 16 以下改走 lockdown 的 `com.apple.dt.simulatelocation`。

## 打包發布

```bash
./scripts/package.sh                 # → build/GPSSpoofer-0.1.0.dmg（ad-hoc 簽署）
```

- **App 圖示**：打包時會把 `packaging/AppIcon.png` 轉成 `.icns`。這張圖必須是**滿版、不透明**的正方形（1024 px 以上），
  圓角由系統自己套用。在 macOS 26 以後，自帶圓角或透明邊距的圖示會被裝進灰色外框。
  AI 生成的「白底＋圓角方形」原圖放在 `packaging/AppIcon-original.png`，
  執行 `.venv/bin/python scripts/prepare_icon.py` 就會轉成滿版圖。
- helper 用 PyInstaller 打包成獨立執行檔，放在 `Contents/Resources/helper/`，使用者不需要安裝 Python。
- 用 ad-hoc 簽署的版本傳給別人時，對方第一次開啟前要執行
  `xattr -dr com.apple.quarantine /Applications/GPSSpoofer.app`，或在「系統設定 → 隱私權與安全性」手動允許。
- 正式發布需要 Apple Developer Program 的 Developer ID 憑證，以及完整的 Xcode（提供 `notarytool`）：
  ```bash
  SIGN_IDENTITY="Developer ID Application: 名字 (TEAMID)" VERSION=0.1.0 ./scripts/package.sh
  xcrun notarytool submit build/GPSSpoofer-0.1.0.dmg --keychain-profile <profile> --wait
  xcrun stapler staple build/GPSSpoofer-0.1.0.dmg
  ```
- 目前只產生 Apple Silicon（arm64）版本。
- 打包時會自動產生 `build/THIRD_PARTY_LICENSES.txt`，並連同 `LICENSE` 一起放進 App 和 DMG。

## 已知限制

- `build_app.sh` 產生的開發版 `.app` 寫死專案 `.venv` 的路徑，只能在本機使用；發布請用 `package.sh`
- 中國大陸地區 Apple 地圖使用 GCJ-02 座標，點選位置會與實際 WGS-84 有數百公尺偏移

## 授權

本專案以 [GNU General Public License v3.0 or later](LICENSE)（GPL-3.0-or-later）授權。

Copyright (C) 2026 GPSSpoofer contributors

之所以採用 GPL，是因為後端使用的 [pymobiledevice3](https://github.com/doronz88/pymobiledevice3) 是 GPL-3.0-or-later。
DMG 內附的 Python 與約 100 個第三方套件都與 GPL-3.0 相容（MIT、BSD、Apache-2.0、ISC、MPL-2.0、LGPL-3.0、PSF 等），
各自的授權聲明收錄在 DMG 與 App 內的 `THIRD_PARTY_LICENSES.txt`。

**散布 DMG 的注意事項**：GPL 要求提供二進位檔的同時也要提供完整原始碼，包含建置腳本。
請在發布 DMG 的同一處（例如 GitHub Releases）提供對應版本的原始碼，或附上原始碼的取得方式。
