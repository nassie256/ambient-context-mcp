import Foundation

/// Localizable.strings は SwiftPM の `.process("Resources")` により
/// AmbientPocApp_AmbientPocApp.bundle 内の {en,ja}.lproj に配置される。
///
/// 注意: SwiftPM が自動生成する `Bundle.module` は
///   1. `Bundle.main.bundleURL/AmbientPocApp_AmbientPocApp.bundle` (= .app の **直下**)
///   2. ビルド時の絶対パス (.build/.../release/...) ← 開発機だけで通ってしまう罠
/// の順にしか探さない。.app 直下に置くと `codesign` が
/// "unsealed contents present in the bundle root" で失敗するため使えない。
/// そこで Contents/Resources に置き、自前のアクセサで解決する。
enum PocResources {
    static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("AmbientPocApp_AmbientPocApp.bundle"),
           let b = Bundle(url: url) {
            return b
        }
        return Bundle.module // 開発時 (swift run) のフォールバック
    }()
}

enum L {
    static func t(_ key: String) -> String {
        NSLocalizedString(key, bundle: PocResources.bundle, comment: "")
    }

    static var settings: String { t("tray.settings") }
    static var copyMcpUrl: String { t("tray.copyMcpUrl") }
    static var copyMcpToken: String { t("tray.copyMcpToken") }
    static var copyClaudeCodeSnippet: String { t("tray.copyClaudeCodeSnippet") }
    static var pause: String { t("tray.pause") }
    static var resume: String { t("tray.resume") }
    static var exit: String { t("tray.exit") }
    static var pausedSuffix: String { t("tray.pausedSuffix") }

    /// 起動時に解決結果をログへ出す (言語切替の検証用)。
    static func dumpResolved() {
        let langs = (UserDefaults.standard.stringArray(forKey: "AppleLanguages") ?? []).joined(separator: ",")
        PocLog.log("i18n AppleLanguages=[\(langs)] bundle=\(PocResources.bundle.bundlePath)")
        PocLog.log("i18n localizations=\(PocResources.bundle.localizations.sorted())")
        for key in ["tray.settings", "tray.copyMcpUrl", "tray.pause", "tray.exit", "settings.tab.mcpServer"] {
            PocLog.log("i18n \(key)=\(t(key))")
        }
    }
}
