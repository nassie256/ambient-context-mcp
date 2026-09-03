import Foundation

/// C# `AmbientContextMcp.Resources.Strings` (src/windows/AmbientContextMcp.Desktop/Resources/Strings.cs)
/// の移植。キーは C# のプロパティ名をそのまま使い、値は `Resources/{en,ja}.lproj/Localizable.strings`
/// に置く。
///
/// **`Bundle.module` は使わない。** SwiftPM が生成する `Bundle.module` は
/// `.app` 直下 → ビルド時の絶対パス (`.build/...`) の順にしか探さず、
/// 開発機でだけ通る罠になる (PoC 4 §5 / 設計書 §4 Phase 4)。ここでは
///   1. `Bundle.main.resourceURL` (= `.app/Contents/Resources`, build-app.sh が .lproj を配置)
///   2. `#filePath` から辿るソースツリー (`swift run` / テスト実行時)
/// の順に `.lproj/Localizable.strings` を直接読む。
///
/// 言語決定: 明示設定 (`ui.language` = "ja" / "en") が最優先。空なら
/// `Locale.preferredLanguages` の先頭が ja 始まりなら ja、それ以外は英語
/// (C# の「日本語環境のみ日本語、それ以外は英語」と同じ方針)。
enum Strings {
    /// C# は `CultureInfo.CurrentUICulture` を 1 度だけ見る。こちらは起動時に
    /// `configure(languageSetting:)` を 1 度呼び、以降は固定。
    private static let state = StringsState()

    /// 実際に採用した言語 ("ja" / "en")。Core のカタログ言語にも同じ値を渡す。
    static var language: String { state.language }

    /// 解決したリソースディレクトリ (診断ログ用)。
    static var resourcePath: String { state.resourcePath }

    /// - Parameter languageSetting: `UiSettings.language` の生値 ("" / "ja" / "en")。
    static func configure(languageSetting: String) {
        state.configure(languageSetting: languageSetting)
    }

    /// キー未定義なら en にフォールバックし、それも無ければキー自身を返す。
    static func text(_ key: String) -> String {
        state.text(key)
    }

    /// `%1$@` 形式のプレースホルダを埋める。C# の `string.Format` (`{0}`) に対応。
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), arguments: arguments)
    }

    // MARK: - C# Strings.cs と 1:1 のアクセサ

    static var windowTitle: String { text("WindowTitle") }
    static var tabMcpServer: String { text("TabMcpServer") }
    static var mcpServerGroup: String { text("McpServerGroup") }
    static var labelStatus: String { text("LabelStatus") }
    static var labelEndpoint: String { text("LabelEndpoint") }
    static var labelToken: String { text("LabelToken") }
    static var labelPort: String { text("LabelPort") }
    static var buttonCopy: String { text("ButtonCopy") }
    static var portChangeNote: String { text("PortChangeNote") }
    static var autoStartCheckbox: String { text("AutoStartCheckbox") }
    static var persistEventLogCheckbox: String { text("PersistEventLogCheckbox") }
    static var persistEventLogNote: String { text("PersistEventLogNote") }
    static var copyClaudeCodeSnippet: String { text("CopyClaudeCodeSnippet") }
    static var tabTransmission: String { text("TabTransmission") }
    static var transmissionExplanation: String { text("TransmissionExplanation") }
    static var allowAllCheckbox: String { text("AllowAllCheckbox") }
    static var eventHistoryGroup: String { text("EventHistoryGroup") }
    static var sensitivityLegend: String { text("SensitivityLegend") }
    static var labelRetention: String { text("LabelRetention") }
    static var labelMaxCount: String { text("LabelMaxCount") }
    static var retention1Hour: String { text("Retention1Hour") }
    static var retention6Hours: String { text("Retention6Hours") }
    static var retention24Hours: String { text("Retention24Hours") }
    static var retention7Days: String { text("Retention7Days") }
    static var count100: String { text("Count100") }
    static var count500: String { text("Count500") }
    static var count1000: String { text("Count1000") }
    static var count5000: String { text("Count5000") }
    static var buttonSave: String { text("ButtonSave") }
    static var buttonClose: String { text("ButtonClose") }

    static var labelLanguage: String { text("LabelLanguage") }
    static var languageSystemDefault: String { text("LanguageSystemDefault") }
    static var languageJapanese: String { text("LanguageJapanese") }
    static var languageEnglish: String { text("LanguageEnglish") }

    static var statusSaved: String { text("StatusSaved") }
    static var statusSavedNeedsRestart: String { text("StatusSavedNeedsRestart") }
    static var statusClaudeCodeCopied: String { text("StatusClaudeCodeCopied") }
    static func statusSaveFailed(_ type: String, _ message: String) -> String {
        format("StatusSaveFailedFormat", type, message)
    }
    /// 保存自体は成功したが、ログイン項目の適用だけ失敗したときのメインステータス行。
    /// (C# は autostart の失敗が例外になり保存全体が失敗表示になる。macOS 版は他の
    /// セクションの保存を活かしたうえで、失敗をここに出す)
    static func statusSavedWithAutostartFailure(_ saved: String, _ reason: String) -> String {
        format("MacStatusSavedAutostartFailedFormat", saved, reason)
    }
    static func statusMcpRunning(port: Int) -> String {
        format("StatusMcpRunningFormat", String(port))
    }

    static var txGroupForegroundApp: String { text("TxGroupForegroundApp") }
    static var txGroupActivity: String { text("TxGroupActivity") }
    static var txGroupMedia: String { text("TxGroupMedia") }
    static var txGroupEnvironment: String { text("TxGroupEnvironment") }

    static var traySettings: String { text("TraySettings") }
    static var trayCopyMcpUrl: String { text("TrayCopyMcpUrl") }
    static var trayCopyMcpToken: String { text("TrayCopyMcpToken") }
    static var trayCopyClaudeCodeSnippet: String { text("TrayCopyClaudeCodeSnippet") }
    static var trayPause: String { text("TrayPause") }
    static var trayResume: String { text("TrayResume") }
    static var trayPausedSuffix: String { text("TrayPausedSuffix") }
    static var trayExit: String { text("TrayExit") }

    static func startupError(_ detail: String, port: Int) -> String {
        format("StartupErrorFormat", detail, String(port))
    }

    // MARK: - カタログ由来 ID → 表示名 (C# TransmissionGroupViewModel と同じ写像)

    static func transmissionGroupTitle(groupId: String) -> String {
        switch groupId {
        case "foregroundApp": return txGroupForegroundApp
        case "activity": return txGroupActivity
        case "media": return txGroupMedia
        case "environment": return txGroupEnvironment
        default: return groupId
        }
    }

    static func transmissionOptionLabel(optionId: String) -> String {
        switch optionId {
        case "foreground.identity": return text("TxUiForegroundIdentity")
        case "foreground.titleSummary": return text("TxUiForegroundTitleSummary")
        case "foreground.rawTitle": return text("TxUiForegroundRawTitle")
        case "activity.switchRate": return text("TxUiActivitySwitchRate")
        case "activity.switchBurst": return text("TxUiActivitySwitchBurst")
        case "media.overview": return text("TxUiMediaOverview")
        case "media.title": return text("TxUiMediaTitle")
        case "media.artist": return text("TxUiMediaArtist")
        case "media.album": return text("TxUiMediaAlbum")
        case "environment.timezone": return text("TxUiEnvironmentTimezone")
        case "environment.displays": return text("TxUiEnvironmentDisplays")
        default: return optionId
        }
    }
}

/// `Strings` の可変状態。起動直後に 1 度だけ書き、以降は読むだけだが、
/// actor をまたいで読まれ得るのでロックで守る。
private final class StringsState: @unchecked Sendable {
    private let lock = NSLock()
    private var table: [String: String] = [:]
    private var fallback: [String: String] = [:]
    private var languageValue = "en"
    private var resourcePathValue = ""

    var language: String {
        lock.lock()
        defer { lock.unlock() }
        return languageValue
    }

    var resourcePath: String {
        lock.lock()
        defer { lock.unlock() }
        return resourcePathValue
    }

    func configure(languageSetting: String) {
        let resolved = StringsState.resolveLanguage(setting: languageSetting)
        let directory = StringsState.resourceDirectory()
        let loaded = directory.flatMap { StringsState.loadTable(directory: $0, language: resolved) } ?? [:]
        let english = resolved == "en"
            ? loaded
            : (directory.flatMap { StringsState.loadTable(directory: $0, language: "en") } ?? [:])

        lock.lock()
        languageValue = resolved
        resourcePathValue = directory?.path ?? ""
        table = loaded
        fallback = english
        lock.unlock()
    }

    func text(_ key: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return table[key] ?? fallback[key] ?? key
    }

    /// 明示設定が最優先。空なら OS の優先言語 (ja 始まりのみ ja)。
    static func resolveLanguage(setting: String) -> String {
        let normalized = setting.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalized.hasPrefix("ja") { return "ja" }
        if normalized.hasPrefix("en") { return "en" }
        let preferred = (Locale.preferredLanguages.first ?? "en").lowercased()
        return preferred.hasPrefix("ja") ? "ja" : "en"
    }

    /// `.lproj` を含むディレクトリ。バンドル実行なら Contents/Resources、
    /// `swift run` ならソースツリーの Sources/AmbientContextMac/Resources。
    static func resourceDirectory() -> URL? {
        if let resources = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resources.appendingPathComponent("en.lproj").path) {
            return resources
        }
        let sourceResources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // App/
            .deletingLastPathComponent()   // AmbientContextMac/
            .appendingPathComponent("Resources")
        if FileManager.default.fileExists(atPath: sourceResources.appendingPathComponent("en.lproj").path) {
            return sourceResources
        }
        return nil
    }

    /// `Localizable.strings` (旧形式 plist) を辞書として読む。
    /// `NSLocalizedString` を使わないのは、バンドルの言語交渉ではなく
    /// 「設定で選んだ言語」を確実に採用するため。
    static func loadTable(directory: URL, language: String) -> [String: String]? {
        let url = directory
            .appendingPathComponent("\(language).lproj")
            .appendingPathComponent("Localizable.strings")
        guard let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: String] else {
            return nil
        }
        return dictionary
    }
}
