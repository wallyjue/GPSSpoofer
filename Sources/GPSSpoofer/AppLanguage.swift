// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 GPSSpoofer contributors

import Foundation

/// App 內可選的介面語言。字串 key 就是繁體中文原文，所以繁體中文不需要翻譯檔。
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case traditionalChinese = "zh-Hant"
    case simplifiedChinese = "zh-Hans"
    case english = "en"
    case japanese = "ja"

    static let storageKey = "appLanguage"

    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: storageKey).flatMap(AppLanguage.init) ?? .system
    }

    var id: Self { self }

    /// 各語言用自己的文字顯示，看不懂目前介面的人也找得到
    var nativeName: String {
        switch self {
        case .system: L("跟隨系統")
        case .traditionalChinese: "繁體中文"
        case .simplifiedChinese: "简体中文"
        case .english: "English"
        case .japanese: "日本語"
        }
    }

    var locale: Locale {
        self == .system ? .autoupdatingCurrent : Locale(identifier: rawValue)
    }

    /// 指定語言時直接讀該語言的 .lproj，`String(localized:locale:)` 的 locale 只影響格式、不影響查哪個翻譯
    var bundle: Bundle {
        guard self != .system,
              let url = Bundle.strings.url(forResource: rawValue, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return .strings }
        return bundle
    }
}

extension Bundle {
    /// package.sh / build_app.sh 會把 SwiftPM 資源包放進 Contents/Resources；`swift run` 時退回 Bundle.module
    static let strings: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("GPSSpoofer_GPSSpoofer.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}

/// 依目前選擇的語言翻譯介面字串
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: AppLanguage.current.bundle)
}
