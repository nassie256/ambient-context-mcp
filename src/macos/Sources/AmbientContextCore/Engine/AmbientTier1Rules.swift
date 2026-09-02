import Foundation

/// アプリ分類の結果。C# の `(string Category, string AppName)` タプル相当。
///
/// 「該当データなし」は `category` / `appName` 共に `""` で統一する。`"unknown"` という
/// サニチネル文字列は使わない (集計時に `""` / 欠落 / `"unknown"` の 3 系統が混在して
/// バグの温床になるため)。C# 版 `AmbientTier1Rules.ClassifyApp` のコメントと同じ方針。
public struct AppClassification: Sendable, Hashable {
    public var category: String
    public var appName: String

    public init(category: String, appName: String) {
        self.category = category
        self.appName = appName
    }

    /// 「該当データなし」を表す値。
    public static let none = AppClassification(category: "", appName: "")
}

/// フォアグラウンドアプリのキー (Windows は実行ファイル名、macOS は bundle id) を
/// category / appName に写像する表。
///
/// C# 版は `AmbientTier1Rules` に Windows の exe 表を直接埋め込んでいたが、
/// macOS 版では OS ごとに別の辞書が要るため表をパラメータ化した
/// (PoC 2 の「推奨 4」= OS 依存の辞書を分離する、に沿う)。
public struct AppClassificationTable: Sendable, Hashable {
    private let entries: [String: AppClassification]

    /// - Parameter rows: `(キー, category, appName)`。キーの照合は大文字小文字を無視する
    ///   (C# の `StringComparer.OrdinalIgnoreCase` 相当、および bundle id の表記揺れ対策)。
    public init(rows: [(String, String, String)]) {
        var map: [String: AppClassification] = [:]
        for row in rows {
            map[row.0.lowercased()] = AppClassification(category: row.1, appName: row.2)
        }
        entries = map
    }

    public func lookup(_ key: String) -> AppClassification? {
        entries[key.lowercased()]
    }

    public var count: Int { entries.count }

    /// Windows 版 (`AmbientTier1Rules.AppClassifications`) と 1:1 の実行ファイル名表。
    /// パリティテストのために完全一致で保持する。
    public static let windows = AppClassificationTable(rows: [
        ("code.exe", "editor", "Visual Studio Code"),
        ("cursor.exe", "editor", "Cursor"),
        ("devenv.exe", "editor", "Visual Studio"),
        ("idea64.exe", "editor", "IntelliJ IDEA"),
        ("rider64.exe", "editor", "Rider"),
        ("pycharm64.exe", "editor", "PyCharm"),
        ("webstorm64.exe", "editor", "WebStorm"),
        ("chrome.exe", "browser", "Chrome"),
        ("msedge.exe", "browser", "Edge"),
        ("firefox.exe", "browser", "Firefox"),
        ("vivaldi.exe", "browser", "Vivaldi"),
        ("brave.exe", "browser", "Brave"),
        ("slack.exe", "communication", "Slack"),
        ("discord.exe", "communication", "Discord"),
        ("teams.exe", "communication", "Teams"),
        ("ms-teams.exe", "communication", "Teams"),
        ("spotify.exe", "media", "Spotify"),
        ("vlc.exe", "media", "VLC"),
        ("wmplayer.exe", "media", "Windows Media Player"),
        ("windowsterminal.exe", "terminal", "Windows Terminal"),
        ("powershell.exe", "terminal", "PowerShell"),
        ("pwsh.exe", "terminal", "PowerShell"),
        ("cmd.exe", "terminal", "Command Prompt"),
        ("winword.exe", "document", "Word"),
        ("excel.exe", "document", "Excel"),
        ("powerpnt.exe", "document", "PowerPoint"),
        ("explorer.exe", "shell", "File Explorer")
    ])

    /// macOS 版の bundle id 表。出典は `src/macos/poc/02-ax-title/RESULT.md` の「推奨 1」。
    /// category は Windows 版と同じ 8 種 (editor / browser / communication / media /
    /// terminal / document / shell / other) のみを使う。
    ///
    /// bundle id は表記が直感と違うことがある (`com.apple.calculator` は小文字、Cursor は
    /// `com.todesktop.230313mzl4w4u92`) ので、追加時は実機で確認すること。
    public static let macOS = AppClassificationTable(rows: [
        // editor
        ("com.microsoft.VSCode", "editor", "Visual Studio Code"),
        ("com.microsoft.VSCodeInsiders", "editor", "Visual Studio Code"),
        ("com.todesktop.230313mzl4w4u92", "editor", "Cursor"),
        ("com.jetbrains.intellij", "editor", "IntelliJ IDEA"),
        ("com.jetbrains.rider", "editor", "Rider"),
        ("com.jetbrains.pycharm", "editor", "PyCharm"),
        ("com.jetbrains.WebStorm", "editor", "WebStorm"),
        ("com.apple.dt.Xcode", "editor", "Xcode"),
        ("dev.zed.Zed", "editor", "Zed"),
        ("com.sublimetext.4", "editor", "Sublime Text"),
        ("com.apple.TextEdit", "editor", "TextEdit"),
        // browser
        ("com.google.Chrome", "browser", "Chrome"),
        ("com.apple.Safari", "browser", "Safari"),
        ("com.microsoft.edgemac", "browser", "Edge"),
        ("org.mozilla.firefox", "browser", "Firefox"),
        ("com.brave.Browser", "browser", "Brave"),
        ("company.thebrowser.Browser", "browser", "Arc"),
        // communication
        ("com.tinyspeck.slackmacgap", "communication", "Slack"),
        ("com.hnc.Discord", "communication", "Discord"),
        ("com.microsoft.teams2", "communication", "Teams"),
        ("us.zoom.xos", "communication", "Zoom"),
        ("com.apple.MobileSMS", "communication", "Messages"),
        ("com.apple.mail", "communication", "Mail"),
        // media
        ("com.spotify.client", "media", "Spotify"),
        ("com.apple.Music", "media", "Music"),
        ("com.apple.TV", "media", "TV"),
        ("org.videolan.vlc", "media", "VLC"),
        ("com.colliderli.iina", "media", "IINA"),
        ("com.apple.QuickTimePlayerX", "media", "QuickTime Player"),
        // terminal
        ("com.apple.Terminal", "terminal", "Terminal"),
        ("com.googlecode.iterm2", "terminal", "iTerm2"),
        ("dev.warp.Warp-Stable", "terminal", "Warp"),
        ("net.kovidgoyal.kitty", "terminal", "kitty"),
        ("com.github.wez.wezterm", "terminal", "WezTerm"),
        // document
        ("com.microsoft.Word", "document", "Word"),
        ("com.microsoft.Excel", "document", "Excel"),
        ("com.microsoft.Powerpoint", "document", "PowerPoint"),
        ("com.apple.iWork.Pages", "document", "Pages"),
        ("com.apple.iWork.Numbers", "document", "Numbers"),
        ("com.apple.iWork.Keynote", "document", "Keynote"),
        ("com.apple.Preview", "document", "Preview"),
        ("com.apple.Notes", "document", "Notes"),
        ("notion.id", "document", "Notion"),
        // shell
        ("com.apple.finder", "shell", "Finder"),
        ("com.apple.systempreferences", "shell", "System Settings"),
        ("com.apple.Spotlight", "shell", "Spotlight")
    ])
}

/// ウィンドウタイトル要約のうち OS ごとに異なる部分 (terminal のシェル判定)。
/// `KnownBrowserSites` は OS 非依存なので `AmbientTier1Rules` 側に共有で持つ。
public struct TitleSummaryRules: Sendable, Hashable {
    /// 先に一致したものが勝つ。C# の if / else if の並び順をそのまま表現する。
    public struct ShellRule: Sendable, Hashable {
        public var shell: String
        public var keywords: [String]

        public init(shell: String, keywords: [String]) {
            self.shell = shell
            self.keywords = keywords
        }
    }

    public var shellRules: [ShellRule]

    public init(shellRules: [ShellRule]) {
        self.shellRules = shellRules
    }

    /// C# 版 `SummarizeWindowTitle` の terminal 分岐と同じ順序・同じキーワード。
    public static let windows = TitleSummaryRules(shellRules: [
        ShellRule(shell: "powershell", keywords: ["PowerShell", "pwsh"]),
        ShellRule(shell: "cmd", keywords: ["cmd"]),
        ShellRule(shell: "wsl", keywords: ["wsl", "ubuntu"])
    ])

    /// macOS のシェル。設計書 §3.3 の「mac は zsh/bash/fish/ssh を持つ」に対応。
    /// `ssh` はリモートセッションを表す擬似シェル値として扱う。
    public static let macOS = TitleSummaryRules(shellRules: [
        ShellRule(shell: "zsh", keywords: ["zsh"]),
        ShellRule(shell: "bash", keywords: ["bash"]),
        ShellRule(shell: "fish", keywords: ["fish"]),
        ShellRule(shell: "ssh", keywords: ["ssh"])
    ])
}

/// C# 版 `AmbientContextMcp.Desktop/AmbientContext/AmbientTier1Rules.cs` の移植。
/// bucket 判定・アプリ分類・ウィンドウタイトル要約の純粋関数群。
public enum AmbientTier1Rules {
    public static let batteryPercentThresholds: [Int] = [80, 50, 30, 20]

    /// ブラウザタイトルから拾う既知サイト名。OS 非依存なので共有する。
    public static let knownBrowserSites: [String] = [
        "GitHub",
        "Gmail",
        "Google",
        "YouTube",
        "Slack",
        "Notion",
        "Microsoft Learn",
        "ChatGPT",
        "Supabase"
    ]

    public static func getPresenceBucket(_ idleSeconds: Int?) -> String {
        guard let idleSeconds else { return "unknown" }
        switch idleSeconds {
        case ..<10: return "active"
        case ..<120: return "idle"
        case ..<600: return "away_short"
        default: return "away_long"
        }
    }

    public static func getBatteryBucket(percent: Int?, charging: Bool?) -> String {
        guard let percent else { return "unknown" }
        if charging == true { return "charging" }
        switch percent {
        case ..<10: return "critical"
        case ..<20: return "low"
        case ..<50: return "medium"
        default: return "ok"
        }
    }

    public static func getCpuPressureBucket(_ usagePercent: Int?) -> String {
        guard let usagePercent else { return "unknown" }
        if usagePercent >= 90 { return "critical" }
        if usagePercent >= 75 { return "high" }
        if usagePercent >= 50 { return "moderate" }
        return "low"
    }

    public static func getMemoryPressureBucket(_ usedPercent: Int?) -> String {
        guard let usedPercent else { return "unknown" }
        if usedPercent >= 95 { return "critical" }
        if usedPercent >= 85 { return "high" }
        if usedPercent >= 70 { return "moderate" }
        return "low"
    }

    /// - Parameters:
    ///   - key: Windows は実行ファイル名 (`code.exe`)、macOS は bundle id (`com.microsoft.VSCode`)。
    ///   - table: 使用する分類表。
    ///   - fallbackName: 表に無いときの `appName`。macOS では実行ファイル名 (`localizedName` は
    ///     OS 言語で変わるため使わない — PoC 2 の「推奨 2」)。nil のときは `key` から拡張子を
    ///     落とした値を使う (Windows 版 `Path.GetFileNameWithoutExtension` と同じ)。
    public static func classifyApp(
        _ key: String,
        table: AppClassificationTable,
        fallbackName: String? = nil
    ) -> AppClassification {
        if key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .none
        }

        if let match = table.lookup(key) {
            return match
        }

        return AppClassification(
            category: "other",
            appName: fallbackName ?? fileNameWithoutExtension(key))
    }

    public static func summarizeWindowTitle(
        category: String,
        title: String,
        rules: TitleSummaryRules
    ) -> CaseInsensitiveDictionary<String> {
        var summary = CaseInsensitiveDictionary<String>()
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return summary
        }

        summary["has_title"] = "true"

        let ext = extractLikelyExtension(title)
        if !ext.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key: String
            switch category {
            case "editor": key = "file_ext"
            case "document": key = "document_ext"
            default: key = "title_ext"
            }
            summary[key] = ext
        }

        if category == "browser" {
            for site in knownBrowserSites where contains(title, site) {
                summary["known_site"] = site
                break
            }
        } else if category == "terminal" {
            for rule in rules.shellRules {
                if rule.keywords.contains(where: { contains(title, $0) }) {
                    summary["shell"] = rule.shell
                    break
                }
            }
        }

        return summary
    }

    public static func extractLikelyExtension(_ title: String) -> String {
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        guard let match = likelyExtensionRegex.firstMatch(in: title, options: [], range: range),
              let group = Range(match.range(at: 1), in: title) else {
            return ""
        }
        return String(title[group]).lowercased()
    }

    // C# の `Path.GetFileNameWithoutExtension` 相当 (最後の "." 以降を落とす)。
    private static func fileNameWithoutExtension(_ value: String) -> String {
        guard let dot = value.lastIndex(of: "."), dot != value.startIndex else {
            return value
        }
        return String(value[value.startIndex..<dot])
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: [.caseInsensitive]) != nil
    }

    // .NET の `\.([A-Za-z0-9]{1,8})(?:\s|$|\-|\x2014|\|)` と同一。`\x2014` は em dash。
    // パターンは定数なので初期化は失敗しない。
    private static let likelyExtensionRegex: NSRegularExpression = {
        guard let regex = try? NSRegularExpression(
            pattern: "\\.([A-Za-z0-9]{1,8})(?:\\s|$|\\-|\u{2014}|\\|)") else {
            preconditionFailure("likelyExtensionRegex pattern is invalid")
        }
        return regex
    }()
}
