import Foundation
import Testing
@testable import AmbientContextCore

@Suite("EngineTier1Rules")
struct EngineTier1RulesTests {
    @Test("GetPresenceBucket_maps_idle_seconds")
    func presenceBuckets() {
        #expect(AmbientTier1Rules.getPresenceBucket(nil) == "unknown")
        #expect(AmbientTier1Rules.getPresenceBucket(0) == "active")
        #expect(AmbientTier1Rules.getPresenceBucket(9) == "active")
        #expect(AmbientTier1Rules.getPresenceBucket(10) == "idle")
        #expect(AmbientTier1Rules.getPresenceBucket(119) == "idle")
        #expect(AmbientTier1Rules.getPresenceBucket(120) == "away_short")
        #expect(AmbientTier1Rules.getPresenceBucket(599) == "away_short")
        #expect(AmbientTier1Rules.getPresenceBucket(600) == "away_long")
    }

    @Test("GetBatteryBucket_prefers_charging")
    func batteryBuckets() {
        #expect(AmbientTier1Rules.getBatteryBucket(percent: nil, charging: true) == "unknown")
        #expect(AmbientTier1Rules.getBatteryBucket(percent: 5, charging: true) == "charging")
        #expect(AmbientTier1Rules.getBatteryBucket(percent: 9, charging: false) == "critical")
        #expect(AmbientTier1Rules.getBatteryBucket(percent: 10, charging: false) == "low")
        #expect(AmbientTier1Rules.getBatteryBucket(percent: 19, charging: nil) == "low")
        #expect(AmbientTier1Rules.getBatteryBucket(percent: 20, charging: nil) == "medium")
        #expect(AmbientTier1Rules.getBatteryBucket(percent: 49, charging: nil) == "medium")
        #expect(AmbientTier1Rules.getBatteryBucket(percent: 50, charging: nil) == "ok")
    }

    @Test("GetCpuAndMemoryPressureBuckets")
    func pressureBuckets() {
        #expect(AmbientTier1Rules.getCpuPressureBucket(nil) == "unknown")
        #expect(AmbientTier1Rules.getCpuPressureBucket(49) == "low")
        #expect(AmbientTier1Rules.getCpuPressureBucket(50) == "moderate")
        #expect(AmbientTier1Rules.getCpuPressureBucket(75) == "high")
        #expect(AmbientTier1Rules.getCpuPressureBucket(90) == "critical")

        #expect(AmbientTier1Rules.getMemoryPressureBucket(nil) == "unknown")
        #expect(AmbientTier1Rules.getMemoryPressureBucket(69) == "low")
        #expect(AmbientTier1Rules.getMemoryPressureBucket(70) == "moderate")
        #expect(AmbientTier1Rules.getMemoryPressureBucket(85) == "high")
        #expect(AmbientTier1Rules.getMemoryPressureBucket(95) == "critical")
    }

    @Test("BatteryPercentThresholds_match_windows")
    func batteryThresholds() {
        #expect(AmbientTier1Rules.batteryPercentThresholds == [80, 50, 30, 20])
    }

    // MARK: - アプリ分類

    @Test("ClassifyApp_windows_parity")
    func classifyAppWindows() {
        let table = AppClassificationTable.windows
        #expect(table.count == 27)

        let code = AmbientTier1Rules.classifyApp("code.exe", table: table)
        #expect(code.category == "editor")
        #expect(code.appName == "Visual Studio Code")

        // 大文字小文字を無視する (C# の OrdinalIgnoreCase)。
        #expect(AmbientTier1Rules.classifyApp("CHROME.EXE", table: table).appName == "Chrome")
        #expect(AmbientTier1Rules.classifyApp("explorer.exe", table: table).category == "shell")

        // 未知は ("other", 拡張子なしのファイル名)。
        let unknown = AmbientTier1Rules.classifyApp("foo.exe", table: table)
        #expect(unknown.category == "other")
        #expect(unknown.appName == "foo")

        // 「該当データなし」は両方 "" (サニチネル "unknown" は使わない)。
        #expect(AmbientTier1Rules.classifyApp("", table: table) == AppClassification.none)
        #expect(AmbientTier1Rules.classifyApp("   ", table: table) == AppClassification.none)
    }

    @Test("ClassifyApp_macOS_uses_bundle_ids")
    func classifyAppMacOS() {
        let table = AppClassificationTable.macOS
        #expect(table.count == 46)

        #expect(AmbientTier1Rules.classifyApp("com.microsoft.VSCode", table: table).category == "editor")
        // bundle id の大小揺れ (com.apple.calculator のような実測ケース) に耐える。
        #expect(AmbientTier1Rules.classifyApp("COM.APPLE.SAFARI", table: table).appName == "Safari")
        #expect(AmbientTier1Rules.classifyApp("com.apple.finder", table: table).category == "shell")
        #expect(AmbientTier1Rules.classifyApp("com.googlecode.iterm2", table: table).category == "terminal")

        // 未知の bundle id は呼び出し側が渡す実行ファイル名にフォールバックする
        // (localizedName は OS 言語で変わるため使わない)。
        let unknown = AmbientTier1Rules.classifyApp(
            "com.example.Unknown", table: table, fallbackName: "SomeApp")
        #expect(unknown.category == "other")
        #expect(unknown.appName == "SomeApp")

        #expect(AmbientTier1Rules.classifyApp("", table: table, fallbackName: "SomeApp") == AppClassification.none)
    }

    @Test("AppClassificationTable_categories_are_known")
    func macOSCategoriesAreKnown() {
        let allowed: Set<String> = [
            "editor", "browser", "communication", "media", "terminal", "document", "shell", "other"
        ]
        for key in [
            "com.microsoft.VSCode", "com.apple.Safari", "com.tinyspeck.slackmacgap",
            "com.spotify.client", "com.apple.Terminal", "com.microsoft.Word", "com.apple.finder"
        ] {
            let classification = AmbientTier1Rules.classifyApp(key, table: .macOS)
            #expect(allowed.contains(classification.category))
        }
    }

    // MARK: - タイトル要約

    @Test("SummarizeWindowTitle_returns_empty_for_blank_title")
    func summarizeBlank() {
        #expect(AmbientTier1Rules.summarizeWindowTitle(
            category: "editor", title: "", rules: .macOS).isEmpty)
        #expect(AmbientTier1Rules.summarizeWindowTitle(
            category: "editor", title: "   ", rules: .macOS).isEmpty)
    }

    @Test("SummarizeWindowTitle_extension_key_depends_on_category")
    func summarizeExtension() {
        let editor = AmbientTier1Rules.summarizeWindowTitle(
            category: "editor", title: "Program.cs - MyApp", rules: .macOS)
        #expect(editor["has_title"] == "true")
        #expect(editor["file_ext"] == "cs")

        let document = AmbientTier1Rules.summarizeWindowTitle(
            category: "document", title: "Report.docx — Word", rules: .macOS)
        #expect(document["document_ext"] == "docx")

        let other = AmbientTier1Rules.summarizeWindowTitle(
            category: "other", title: "notes.txt | viewer", rules: .macOS)
        #expect(other["title_ext"] == "txt")

        // 拡張子が見つからないときはキーごと出さない。
        let none = AmbientTier1Rules.summarizeWindowTitle(
            category: "editor", title: "Untitled", rules: .macOS)
        #expect(none["has_title"] == "true")
        #expect(none["file_ext"] == nil)
    }

    @Test("ExtractLikelyExtension_matches_windows_regex")
    func extractExtension() {
        #expect(AmbientTier1Rules.extractLikelyExtension("Program.CS - app") == "cs")
        #expect(AmbientTier1Rules.extractLikelyExtension("a.md") == "md")
        #expect(AmbientTier1Rules.extractLikelyExtension("a.md—x") == "md")
        #expect(AmbientTier1Rules.extractLikelyExtension("a.md-x") == "md")
        #expect(AmbientTier1Rules.extractLikelyExtension("a.md|x") == "md")
        // 9 文字以上は拡張子とみなさない。
        #expect(AmbientTier1Rules.extractLikelyExtension("a.abcdefghi x") == "")
        #expect(AmbientTier1Rules.extractLikelyExtension("no extension here") == "")
    }

    @Test("SummarizeWindowTitle_browser_sites_are_shared")
    func summarizeBrowser() {
        let windows = AmbientTier1Rules.summarizeWindowTitle(
            category: "browser", title: "issue · GitHub", rules: .windows)
        let macOS = AmbientTier1Rules.summarizeWindowTitle(
            category: "browser", title: "issue · GitHub", rules: .macOS)
        #expect(windows["known_site"] == "GitHub")
        #expect(macOS["known_site"] == "GitHub")

        let unknownSite = AmbientTier1Rules.summarizeWindowTitle(
            category: "browser", title: "example.com", rules: .macOS)
        #expect(unknownSite["known_site"] == nil)
    }

    @Test("SummarizeWindowTitle_shell_rules_are_platform_specific")
    func summarizeShell() {
        let powershell = AmbientTier1Rules.summarizeWindowTitle(
            category: "terminal", title: "Windows PowerShell", rules: .windows)
        #expect(powershell["shell"] == "powershell")
        #expect(AmbientTier1Rules.summarizeWindowTitle(
            category: "terminal", title: "cmd - node", rules: .windows)["shell"] == "cmd")
        #expect(AmbientTier1Rules.summarizeWindowTitle(
            category: "terminal", title: "Ubuntu (WSL)", rules: .windows)["shell"] == "wsl")

        // macOS のキーワードは Windows 表では拾わない (逆も同じ)。
        #expect(AmbientTier1Rules.summarizeWindowTitle(
            category: "terminal", title: "zsh — 80x24", rules: .windows)["shell"] == nil)
        #expect(AmbientTier1Rules.summarizeWindowTitle(
            category: "terminal", title: "zsh — 80x24", rules: .macOS)["shell"] == "zsh")
        #expect(AmbientTier1Rules.summarizeWindowTitle(
            category: "terminal", title: "bash", rules: .macOS)["shell"] == "bash")
        #expect(AmbientTier1Rules.summarizeWindowTitle(
            category: "terminal", title: "fish", rules: .macOS)["shell"] == "fish")
        #expect(AmbientTier1Rules.summarizeWindowTitle(
            category: "terminal", title: "ssh build-host", rules: .macOS)["shell"] == "ssh")
        #expect(AmbientTier1Rules.summarizeWindowTitle(
            category: "terminal", title: "Windows PowerShell", rules: .macOS)["shell"] == nil)
    }
}
