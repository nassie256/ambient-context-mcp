import AppKit
import Combine
import Foundation

import AmbientContextCore
import AmbientContextMcpServer

/// 設定ウィンドウの状態。C# `SettingsWindow.xaml.cs` + `TransmissionGroupViewModel` /
/// `TransmissionOptionViewModel` を 1 つにまとめたもの。
///
/// 保存は C# `OnSaveClick` と **同じ 8 ステップ・同じ順序** で行い、診断ログの
/// `settings/save_begin` / `step_failed` / `save_end` / `save_failed` も揃える。
@MainActor
final class SettingsViewModel: ObservableObject {
    /// UI 1 行分の送信オプション (C# `TransmissionOptionViewModel`)。
    struct Option: Identifiable, Hashable {
        let id: String
        let primaryPath: String
        let label: String
        let sensitivity: String
        let linkedPaths: [String]
        var isAllowed: Bool
    }

    /// UI 1 グループ (C# `TransmissionGroupViewModel`)。
    struct Group: Identifiable, Hashable {
        let id: String
        let title: String
        var options: [Option]
    }

    static let retentionHourChoices = [1, 6, 24, 168]
    static let maxEventCountChoices = [100, 500, 1000, 5000]

    private let settingsStore: any SettingsStore
    private let mcpHost: McpServerHost
    private let hub: LocalContextHub
    private let service: MacAmbientContextService
    private let catalogLanguage: String

    /// シート表示の親。`SettingsWindowController` が設定する。
    weak var hostWindow: NSWindow?

    @Published var groups: [Group] = []
    @Published var portText: String = ""
    @Published var autoStart: Bool = false
    @Published var persistEventLog: Bool = false
    @Published var languageSetting: String = ""
    @Published var retentionHours: Int = 24
    @Published var maxEventCount: Int = 500
    @Published var statusMessage: String = ""
    @Published var autostartMessage: String = ""
    @Published var isSaving: Bool = false
    @Published private(set) var mcpStatusText: String = ""
    @Published private(set) var endpoint: String = ""
    @Published private(set) var token: String = ""

    private var initialLanguage: String = ""
    private var lastSavedMediaEnabled: Bool = false

    init(
        settingsStore: any SettingsStore,
        mcpHost: McpServerHost,
        hub: LocalContextHub,
        service: MacAmbientContextService,
        catalogLanguage: String
    ) {
        self.settingsStore = settingsStore
        self.mcpHost = mcpHost
        self.hub = hub
        self.service = service
        self.catalogLanguage = catalogLanguage
        load()
        AppDiagnosticLog.shared.log(category: "settings", event: "window_created")
    }

    // MARK: - 読み込み (C# コンストラクタの Load* 群)

    /// ウィンドウ再表示時に保存済みの値へ戻す。C# は `Closed` でウィンドウごと作り直すため
    /// 未保存の編集は残らない。こちらはインスタンスを使い回すので明示的に読み直す。
    func reload() {
        load()
        statusMessage = ""
        autostartMessage = ""
    }

    private func load() {
        groups = AmbientContextCatalog.getTransmissionUiGroups(language: catalogLanguage)
            .map { group in
                Group(
                    id: group.id,
                    title: Strings.transmissionGroupTitle(groupId: group.id),
                    options: group.options.map { option in
                        Option(
                            id: option.id,
                            primaryPath: option.primaryPath,
                            label: Strings.transmissionOptionLabel(optionId: option.id),
                            sensitivity: option.sensitivity,
                            linkedPaths: option.linkedPaths,
                            isAllowed: false)
                    })
            }

        loadTransmissionSettings()
        loadLocalContextSettings()
        loadUiSettings()
        initialLanguage = languageSetting
        lastSavedMediaEnabled = isMediaEnabled
        autoStart = LoginItemManager.isEnabled
        portText = String(mcpHost.settings.port)
        refreshMcpStatus()
    }

    private func loadTransmissionSettings() {
        let settings = settingsStore.loadAmbientTransmissionSettings()
        for groupIndex in groups.indices {
            for optionIndex in groups[groupIndex].options.indices {
                let option = groups[groupIndex].options[optionIndex]
                groups[groupIndex].options[optionIndex].isAllowed =
                    TransmissionUiSettingsMerge.isOptionEnabled(
                        primaryPath: option.primaryPath,
                        overrides: settings.pathTransmitOverrides)
            }
        }
    }

    private func loadLocalContextSettings() {
        let settings = settingsStore.loadLocalContextSettings()
        retentionHours = Self.retentionHourChoices.contains(settings.maxEventAgeHours)
            ? settings.maxEventAgeHours : Self.retentionHourChoices[0]
        maxEventCount = Self.maxEventCountChoices.contains(settings.maxEventCount)
            ? settings.maxEventCount : Self.maxEventCountChoices[0]
        persistEventLog = settings.persistEventLog
    }

    private func loadUiSettings() {
        let normalized = settingsStore.loadUiSettings().language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        languageSetting = (normalized == "ja" || normalized == "en") ? normalized : ""
    }

    private func refreshMcpStatus() {
        mcpStatusText = Strings.statusMcpRunning(port: mcpHost.settings.port)
        endpoint = mcpHost.mcpUrl
        token = mcpHost.token
    }

    // MARK: - 送信オプション

    var allOptions: [Option] {
        groups.flatMap(\.options)
    }

    /// C# `RefreshSelectAllTransmissionCheckBox` と同じ判定。全 ON のときだけ ON。
    /// 一部だけ ON のときは NSButton の `.mixed` (Windows の未チェック相当) で見せる。
    var allowAllState: NSControl.StateValue {
        let options = allOptions
        guard !options.isEmpty else { return .off }
        if options.allSatisfy(\.isAllowed) { return .on }
        if options.contains(where: \.isAllowed) { return .mixed }
        return .off
    }

    /// 「すべて許可」クリック。C# は IsChecked (mixed は false) の値をそのまま全項目へ配る。
    func setAllOptions(allowed: Bool) {
        for groupIndex in groups.indices {
            for optionIndex in groups[groupIndex].options.indices {
                groups[groupIndex].options[optionIndex].isAllowed = allowed
            }
        }
    }

    var isTitleEnabled: Bool {
        allOptions.contains {
            ($0.id == "foreground.titleSummary" || $0.id == "foreground.rawTitle") && $0.isAllowed
        }
    }

    var isMediaEnabled: Bool {
        allOptions.contains { $0.id.hasPrefix("media.") && $0.isAllowed }
    }

    // MARK: - コピー

    func copyEndpoint() { Pasteboard.copy(endpoint) }

    func copyToken() { Pasteboard.copy(token) }

    func copyClaudeCodeSnippet() {
        Pasteboard.copy(McpClientSnippets.buildClaudeCodeSnippet(mcpUrl: mcpHost.mcpUrl, token: mcpHost.token))
        statusMessage = Strings.statusClaudeCodeCopied
    }

    // MARK: - 保存 (C# OnSaveClick と同じ 8 ステップ)

    func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        AppDiagnosticLog.shared.log(category: "settings", event: "save_begin")
        let startedAt = Date()

        do {
            try step("save_mcp") { self.saveMcpSettings() }
            try step("save_transmission") { self.saveTransmissionSettings() }
            try step("save_local_context") { self.saveLocalContextSettings() }
            try step("save_ui") { self.saveUiSettings() }
            let autostart = try step("apply_autostart") { self.applyAutostart() }
            try await asyncStep("reload_collector") { await self.service.reloadTransmissionPolicy() }
            try step("reload_hub") { self.hub.reloadSettings() }
            try step("reload_mcp") { self.mcpHost.reloadSettings() }

            let languageChanged = languageSetting.caseInsensitiveCompare(initialLanguage) != .orderedSame
            let saved = languageChanged ? Strings.statusSavedNeedsRestart : Strings.statusSaved
            // C# では autostart の失敗が例外になり保存全体が「失敗」と表示される。
            // macOS の SMAppService は開発ビルドなどで日常的に失敗しうるので、他セクションの
            // 保存は活かしつつ、失敗はメインのステータス行にも出す (「保存しました」で
            // 済ませると autoStart だけ効いていないことがユーザに伝わらない)。
            statusMessage = autostart.isFailure
                ? Strings.statusSavedWithAutostartFailure(saved, autostart.message)
                : saved
            refreshMcpStatus()

            AppDiagnosticLog.shared.log(
                category: "settings", event: "save_end",
                detail: [
                    "durationMs": .int(Int(Date().timeIntervalSince(startedAt) * 1000)),
                    "languageChanged": .bool(languageChanged)
                ])

            // Windows には無い macOS 固有の後処理: 権限が要る項目を ON にしたときだけ誘導する。
            let mediaEnabled = isMediaEnabled
            PermissionGuide.checkAfterSave(
                titleEnabled: isTitleEnabled,
                mediaEnabled: mediaEnabled,
                mediaNewlyEnabled: mediaEnabled && !lastSavedMediaEnabled,
                presentingOn: hostWindow)
            lastSavedMediaEnabled = mediaEnabled
        } catch {
            AppDiagnosticLog.shared.logError(category: "settings", event: "save_failed", error: error)
            statusMessage = Strings.statusSaveFailed(
                String(describing: type(of: error)), String(describing: error))
        }
    }

    /// C# `SaveStep`: 失敗したステップ名を残してから再送出する。
    @discardableResult
    private func step<T>(_ name: String, _ action: () throws -> T) throws -> T {
        do {
            return try action()
        } catch {
            AppDiagnosticLog.shared.logError(
                category: "settings", event: "step_failed", error: error,
                detail: ["step": .string(name)])
            throw error
        }
    }

    private func asyncStep(_ name: String, _ action: () async throws -> Void) async throws {
        do {
            try await action()
        } catch {
            AppDiagnosticLog.shared.logError(
                category: "settings", event: "step_failed", error: error,
                detail: ["step": .string(name)])
            throw error
        }
    }

    private func saveMcpSettings() {
        let current = mcpHost.settings
        settingsStore.saveMcpServerSettings(McpServerSettings(
            schemaVersion: 1,
            autoStart: autoStart,
            port: Self.parsePort(portText, fallback: current.port),
            token: current.token))
    }

    private func saveTransmissionSettings() {
        let settings = settingsStore.loadAmbientTransmissionSettings()
        let enabledIds = Set(allOptions.filter(\.isAllowed).map(\.id))
        let catalogOptions = AmbientContextCatalog
            .getTransmissionUiGroups(language: catalogLanguage)
            .flatMap(\.options)
        let overrides = TransmissionUiSettingsMerge.mergeOverrides(
            existingOverrides: settings.pathTransmitOverrides,
            options: catalogOptions,
            enabledOptionIds: enabledIds)

        AmbientTransmissionPolicy.save(
            store: settingsStore,
            settings: AmbientTransmissionSettings(schemaVersion: 1, pathTransmitOverrides: overrides),
            privacyClassifications: AmbientContextCatalog.getPrivacyClassifications(language: catalogLanguage))
    }

    private func saveLocalContextSettings() {
        settingsStore.saveLocalContextSettings(LocalContextSettings(
            schemaVersion: 1,
            maxEventAgeHours: retentionHours,
            maxEventCount: maxEventCount,
            persistEventLog: persistEventLog))
    }

    private func saveUiSettings() {
        settingsStore.saveUiSettings(UiSettings(schemaVersion: 1, language: languageSetting))
        // 実際の切替は次回起動時 (Windows 版と同じ「要再起動」仕様)。
        // AppleLanguages の書き込みは AppDelegate が起動時に行う。
    }

    /// ログイン項目を適用する。
    ///
    /// **成功時にチェックボックスを `SMAppService.status` から読み直さない。**
    /// register() / unregister() 直後の status は反映が遅れることがあり、読み直すと
    /// ユーザの操作が目の前で巻き戻って見える。実状態へ戻すのは失敗したときだけ。
    /// `requiresApproval` は「登録済み・承認待ち」なので ON のまま注記を出す。
    @discardableResult
    private func applyAutostart() -> LoginItemManager.ApplyOutcome {
        let outcome = LoginItemManager.apply(enabled: autoStart)
        autostartMessage = outcome.message
        if outcome.isFailure {
            autoStart = LoginItemManager.isEnabled
        }
        return outcome
    }

    /// C# `ParsePort`: 1..65535 以外は現在値を維持する。
    /// C# の `int.TryParse` は前後の空白 (改行を含む) を無視するので、
    /// トリムも `.whitespacesAndNewlines` で揃える。
    static func parsePort(_ text: String, fallback: Int) -> Int {
        guard let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0, port < 65536 else {
            return fallback
        }
        return port
    }
}
