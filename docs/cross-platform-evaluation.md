# 跨平台改寫評估：Tauri + Vue + Rust

> 評估日期：2026-10-28　·　基準：`main` @ `57119eb`

## 結論

- **規模**：這是一次**完整改寫**。目前所有 App 程式碼（Swift 約 1,330 行、Python helper 209 行）都會被取代，只有協定設計、路線演算法、翻譯內容和網站可以沿用。
- **工作量**：一人約 **6–9 週**。其中最大的不確定性在「用 Rust 取代 pymobiledevice3」，而不在 UI。
- **最大風險**：Rust 生態目前只有 [`idevice`](https://github.com/jkcoxson/idevice) 一個候選，它還在 0.1.x，作者註明「Breaking changes will happen at each point release until 0.2.0」。iOS 17+ 的 personalized DDI 掛載和 tunnel 建立，在 Windows 和 Linux 上都要先做 PoC 驗證。
- **建議**：分兩階段進行。
  1. **先換殼**：Tauri + Vue，Python helper 改成 Tauri sidecar，stdin/stdout JSON 協定不變。這一步就能讓 App 在三個平台上執行，風險也低。
  2. **再換心臟**：`idevice` 的 PoC 通過後，才用 Rust 取代 sidecar。

## 現況盤點

| 元件 | 檔案 | 行數 | 依賴 Apple 專屬 API |
|---|---|---|---|
| UI（地圖、側邊欄 5 個分頁） | `ContentView.swift` | 544 | SwiftUI、MapKit（`Map`、`MapStyle`、`MapPolyline`、`Annotation`、`MapPitchToggle`） |
| 狀態、裝置操作 | `LocationController.swift` | 224 | `ObservableObject`、`MKCoordinateRegion` |
| 多點路線播放 | `LocationController+Route.swift` | 212 | `CLLocation.distance`、`UserDefaults` |
| 地點搜尋 | `LocationController+Search.swift` | 53 | `MKLocalSearch`（Apple 地圖 POI） |
| helper 子程序管理 | `HelperBridge.swift` | 186 | `Process`、`Pipe` |
| 介面語言 | `AppLanguage.swift` + 3 份 `.strings` | 60 + 282 | `Bundle`、`.lproj` |
| 裝置後端 | `helper/location_helper.py` | 209 | pymobiledevice3；native tunnel 只支援 macOS |
| 打包、CI | `scripts/*.sh`、`build.yml` | 約 300 | PyInstaller、`codesign`、`hdiutil`、`iconutil` |

不受影響：`site/`（GitHub Pages）、`LICENSE`、`packaging/AppIcon*.png`。

## 逐項對照

### 1. 裝置後端：Python → Rust（風險最高）

目前 helper 只有 5 個指令：`list`、`connect`、`set`、`clear`、`disconnect`。介面很小，但每一個指令都依賴 pymobiledevice3 的大量底層實作：

| 功能 | pymobiledevice3 | Rust `idevice` | 狀態 |
|---|---|---|---|
| 列出裝置 | `usbmux.list_devices` | `usbmuxd` | ✅ 有 |
| lockdown 讀取名稱、版本 | `create_using_usbmux` | `lockdown` | ✅ 有 |
| iOS 17+ tunnel | native → userspace → tunneld | `core_device_proxy` + `tunnel_tcp_stack`（in-process TCP stack） | ⚠️ 有，但要驗證是否不需要 root |
| RSD | `RemoteServiceDiscovery` | `xpc` / RSD | ✅ 有 |
| 掛載 personalized DDI（cryptex） | `auto_mount` | `mobile_image_mounter` | ⚠️ README 沒寫是否支援 personalized，要 PoC |
| DVT 定位模擬（iOS 17+） | `LocationSimulation` | `location_simulation` | ✅ 有 |
| iOS 16 以下 `simulatelocation` | `DtSimulateLocation` | 未確認 | ⚠️ 可能要自己實作（協定簡單，約 50 行） |
| 自動下載 DDI | `auto_mount` 內建 | 未確認 | ⚠️ 可能要自己處理下載與 TSS 簽章請求 |

**平台差異**，換成 Rust 之後也一樣存在：

- **Windows**：必須先安裝 Apple Mobile Device Support（iTunes 或 Apple Devices App）才有 usbmuxd。App 要偵測這一點並提示使用者。
- **Linux**：要有 `usbmuxd` daemon，發行版大多內建，但使用者可能需要 udev 權限。
- **macOS native tunnel**（借用 `remoted`）是 macOS 專屬功能，Rust 版要改走 userspace tunnel。目前程式選 native 的原因是「userspace tunnel 在較新的 iOS 上傳 cryptex DDI 時會被 cryptexd 中斷」（見 `location_helper.py` 的 `open_tunnel`），Rust 版要驗證是否有同樣的問題。

**估計**：PoC 3–5 天；正式實作與實機測試（iOS 16、17、18、26 × 三個平台）2–3 週。

### 2. 地圖：MapKit → MapLibre GL JS（要做產品決策）

| 現有功能 | 替代方案 | 注意 |
|---|---|---|
| 標準底圖 | MapLibre + OpenFreeMap / MapTiler 向量圖磚 | OSM 官方圖磚禁止 App 大量使用 |
| 衛星、混合 | Esri World Imagery、MapTiler Satellite | 要 API key，並遵守各家授權條款 |
| 3D 建築、地形 | MapLibre `fill-extrusion` + terrain DEM | 外觀不如 Apple 的 realistic elevation |
| 路況 | Google、HERE、TomTom traffic tiles | **全部要付費**，建議第一版拿掉 |
| 點地圖、標記、路線線條 | `map.on('click')`、Marker、GeoJSON line layer | 直接對應 |
| 鏡頭跟隨 | `map.easeTo` | 直接對應 |

另一個做法是用 **MapKit JS** 保留 Apple 地圖的外觀，但需要 Apple Developer Program 帳號發行 token，而且 token 要放在 App 裡，不建議。

**估計**：4–6 天，包含圖層切換 UI 與授權標示（attribution）。

### 3. 地點搜尋：MKLocalSearch → 地理編碼服務

`MKLocalSearch` 的 POI 品質很難用免費服務取代：

- **Nominatim**（OSM）：免費，但限制每秒 1 次請求，商店名稱搜尋比 Apple 差。
- **Photon**：OSM 資料，可以自架。
- **MapTiler Geocoding、Mapbox、Google Places**：品質較好，要 API key 並付費。

**估計**：2–3 天，另外要決定服務商與 API key 的保管方式。

### 4. UI：SwiftUI → Vue 3

`ContentView.swift`（544 行）可以拆成大約 8 個元件：`MapView`、`MapToolbar`、`DeviceTab`、`SearchTab`、`LocationTab`、`RouteTab`、`LogTab`、`SidebarLayout`。狀態放進 Pinia store，對應現在的 `LocationController` 的 `@Published` 屬性。

需要重做的 macOS 原生行為：`HSplitView` 側邊欄拖曳、⌃⌘S 收合快捷鍵、隨語言更新的視窗標題（Tauri `window.setTitle`）。

**估計**：1.5–2 週，產出約 1,000–1,300 行 Vue/TS。

### 5. 路線播放：放在 Rust，不要放在 WebView

`runRoute()` 每秒送一次座標。**這段邏輯應該移到 Rust（tokio interval），不要寫在 Vue 裡**：WebView 被縮小或移到背景時，瀏覽器會節流 `setTimeout`，路線會變慢或停住。現在的 Swift `Task.sleep` 沒有這個問題。

Rust 端透過 Tauri event 推送 `position`、`leg`、`traveledMeters` 給前端。`CLLocation.distance` 改用 `geo` crate 的 haversine 計算；內插邏輯直接照搬。

**估計**：3–4 天，大約 300 行 Rust。

### 6. 其他

| 項目 | 現況 | 改寫後 | 估計 |
|---|---|---|---|
| 多國語言 | `.strings`，key 是繁中原文 | `vue-i18n` JSON，key 建議改成識別字；`check_strings.py` 改寫 | 1–2 天 |
| 偏好設定 | `UserDefaults` | `tauri-plugin-store` | 0.5 天 |
| 打包 | `package.sh`、PyInstaller、`hdiutil` | `tauri build` → dmg / msi / nsis / AppImage / deb | 2 天 |
| CI | macOS-15 單一 job | 三平台 matrix；Windows、Linux 的程式碼簽章另外處理 | 2–3 天 |
| 第三方授權 | `collect_licenses.py`（Python 套件） | `cargo-about` + `license-checker`（npm） | 1 天 |
| 文件、網站 | README 只寫 macOS | 補上 Windows 和 Linux 的前置需求 | 1 天 |

授權：`idevice` 是 MIT，Tauri 是 MIT / Apache-2.0，都相容本專案的 GPL-3.0。

## 總工作量

| 項目 | 估計 |
|---|---|
| Rust 裝置後端（含 PoC） | 2.5–4 週 |
| Vue UI | 1.5–2 週 |
| 地圖與搜尋替換 | 1–1.5 週 |
| 路線引擎與 Tauri commands | 0.5–1 週 |
| i18n、設定、打包、CI、文件 | 1.5–2 週 |
| **合計（有部分重疊）** | **約 6–9 週** |

分兩階段時，第一階段（Tauri + Vue + Python sidecar）大約 **3.5–5 週**，完成後就能在三個平台發布。第二階段的時程取決於 PoC 結果。

## 會失去或變差的功能

- Apple 地圖的 POI 搜尋品質，以及 realistic 3D 外觀
- 免費的即時路況圖層
- macOS 原生的視窗、側邊欄和捲動手感
- 安裝檔變大：Tauri 本身很小，但第一階段仍然要內附 PyInstaller 打包的 helper

## 第一步：PoC 清單

在決定投入之前，先用一個 Rust CLI 在**三個平台**、**iOS 17 以上的實機**上驗證：

1. 不使用 root 或系統管理員權限，建立 CoreDeviceProxy tunnel
2. 自動下載並掛載 personalized DDI
3. 透過 DVT `location_simulation` 送出一個座標，並且清除
4. 維持連線 10 分鐘以上，每秒送一次座標，連線不中斷

四項都通過，就可以進行第二階段；任何一項失敗，就保留 Python sidecar。
