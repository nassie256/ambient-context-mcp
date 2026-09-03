import AppKit
import Foundation

import AmbientContextCore
import AmbientContextMcpServer

/// C# `App.xaml.cs` (`OnLaunched` / `ShutdownAsync`) の macOS 版。
///
/// 起動シーケンスは Windows 版と同じ順序:
///   設定ストア → 診断ログ設定 + `app/startup` → UI 言語適用 → McpServerHost →
///   LocalContextHub → MacAmbientContextService → MCP HTTP 起動 → discovery ファイル →
///   snapshotUpdated 配線 → サービス開始 → メニューバーアイコン表示
///
/// WinUI の Anchor Window に相当するものは不要 (`LSUIElement` / `.accessory` なので
/// ウィンドウが 1 つも無くても常駐できる)。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settingsStore: (any SettingsStore)?
    private var mcpHost: McpServerHost?
    private var hub: LocalContextHub?
    private var service: MacAmbientContextService?
    private var httpServer: McpHttpServer?
    private var statusItem: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private let pauseFlag = PauseFlag()
    private var signalSources: [DispatchSourceSignal] = []
    private var shuttingDown = false
    /// App Nap 抑止トークン。プロセスの生存期間ずっと保持する (解放すると App Nap が戻る)。
    private var activityToken: NSObjectProtocol?

    // MARK: - 起動

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 開発 / 検証時に実ユーザ設定を汚さないための逃げ道 (ambient-mcp-dev と同じ環境変数名)。
        let settingsPath = ProcessInfo.processInfo.environment["AMBIENT_SETTINGS"]
        let store = JsonFileSettingsStore(path: settingsPath)
        settingsStore = store

        // App Nap 抑止 (設計書 §7.1 バグ 1-d)。ウィンドウを持たない .accessory アプリは
        // App Nap の対象になりやすく、60 秒周期の capture が数分単位に間引かれる。
        // `.background` は「ユーザに見えない継続的な作業がある」という宣言で、
        // タイマーの合体と App Nap を止める。スリープ自体は抑止しない
        // (`.idleSystemSleepDisabled` などは付けない: 常駐ツールがスリープを妨げるべきでない)。
        // Info.plist の NSAppSleepDisabled は同じ意図の静的な保険 (scripts/build-app.sh)。
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.background], reason: "Ambient context capture")

        AppDiagnosticLog.shared.configure(settingsPath: store.settingsPath)
        AppDiagnosticLog.shared.log(
            category: "app", event: "startup",
            detail: [
                "settingsPath": .string(store.settingsPath),
                "bundlePath": .string(Bundle.main.bundlePath),
                "pid": .int(Int(ProcessInfo.processInfo.processIdentifier))
            ])

        let language = applyUiLanguage(store.loadUiSettings())

        let mcpHost = McpServerHost(settingsStore: store)
        self.mcpHost = mcpHost
        let hub = LocalContextHub(settingsStore: store, language: language)
        self.hub = hub
        let service = MacAmbientContextService(settingsStore: store)
        self.service = service

        settingsWindow = SettingsWindowController(
            settingsStore: store, mcpHost: mcpHost, hub: hub, service: service,
            catalogLanguage: language)

        installSignalHandlers()

        Task { @MainActor in
            await startRuntime(mcpHost: mcpHost, hub: hub, service: service)
        }
    }

    private func startRuntime(
        mcpHost: McpServerHost,
        hub: LocalContextHub,
        service: MacAmbientContextService
    ) async {
        let port = mcpHost.settings.port
        do {
            // transport + Server はリクエストごとに作る (JSON-RPC id 衝突の回避。
            // AmbientMcpServer.RequestPipeline のコメント参照)。
            let server = McpHttpServer(
                pipelineFactory: { try await AmbientMcpServer.makePipeline(hub: hub) },
                tokenProvider: { [mcpHost] in mcpHost.token })
            try await server.start(host: "127.0.0.1", port: port)
            httpServer = server

            try mcpHost.writeDiscoveryFile()
            AppDiagnosticLog.shared.log(
                category: "mcp", event: "listening",
                detail: ["port": .int(port), "discoveryPath": .string(mcpHost.discoveryPath)])
        } catch {
            // ポート競合など。Windows 版と同じく理由 + ポート番号をダイアログで示して終了する。
            AppDiagnosticLog.shared.logError(
                category: "app", event: "startup_failed", error: error,
                detail: ["port": .int(port)])
            showFatalError(Strings.startupError(
                "\(String(describing: type(of: error))): \(String(describing: error))", port: port))
            exit(1)
        }

        // C# `WireSnapshotForwarding` と同じく start の前に配線する (起動直後の capture を取りこぼさない)。
        let pauseFlag = self.pauseFlag
        await service.setSnapshotUpdatedHandler { snapshot in
            if !pauseFlag.isPaused {
                hub.ingest(snapshot)
            }
        }
        await service.start()

        let statusItem = StatusItemController(
            mcpHost: mcpHost,
            pauseFlag: pauseFlag,
            openSettings: { [weak self] in self?.settingsWindow?.show() },
            requestQuit: { NSApp.terminate(nil) })
        statusItem.show()
        self.statusItem = statusItem
    }

    /// C# `ApplyUiCulture` の macOS 版。
    ///
    /// - 明示指定 ("ja" / "en") のときは `AppleLanguages` を書き、**次回起動の OS 側の
    ///   ローカライズ** をその言語に固定する (Windows 版と同じ「要再起動」仕様)。
    /// - 今回の起動では `Strings` に同じ言語を直接渡すので、保存 → 再起動で確実に反映される。
    /// - 空文字はシステム既定に戻す (`AppleLanguages` の上書きを削除)。
    /// - Returns: 実際に採用した言語 ("ja" / "en")。Core のカタログにも同じ値を渡す。
    private func applyUiLanguage(_ ui: UiSettings) -> String {
        let setting = ui.language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if setting == "ja" || setting == "en" {
            UserDefaults.standard.set([setting], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }

        Strings.configure(languageSetting: ui.language)
        AppDiagnosticLog.shared.log(
            category: "app", event: "ui_language",
            detail: [
                "setting": .string(ui.language),
                "resolved": .string(Strings.language),
                "resources": .string(Strings.resourcePath)
            ])
        return Strings.language
    }

    private func showFatalError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Ambient Context MCP"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// `kill` / `launchd` からの終了要求でも後始末 (discovery ファイル削除) を通す。
    ///
    /// `NSApp.terminate` は必ず `RunLoop.main` のソース経由で呼ぶ。メインキューの
    /// block の中から直接 terminate すると、`.terminateLater` が回すネストした run loop が
    /// メインキューを drain できず (dispatch のメインキュー drain は再入不可)、
    /// `reply(toApplicationShouldTerminate:)` を出す Task が永久に走らずデッドロックする
    /// (実機で確認)。
    private func installSignalHandlers() {
        for signalNumber in [SIGTERM, SIGINT] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                AppDiagnosticLog.shared.log(
                    category: "app", event: "signal", detail: ["signal": .int(Int(signalNumber))])
                RunLoop.main.perform(inModes: [.common]) {
                    MainActor.assumeIsolated { NSApp.terminate(nil) }
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - 終了 (C# ShutdownAsync)

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if shuttingDown { return .terminateNow }
        shuttingDown = true
        AppDiagnosticLog.shared.log(category: "app", event: "shutdown_begin")

        Task { @MainActor in
            let service = self.service
            let httpServer = self.httpServer
            await service?.stop()
            await httpServer?.stop()
            self.mcpHost?.tryDeleteDiscoveryFile()
            self.settingsWindow?.dispose()
            self.statusItem?.remove()
            AppDiagnosticLog.shared.log(category: "app", event: "shutdown_end")
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 設定ウィンドウを閉じてもアプリは常駐し続ける (PoC 4 の必須要件)。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock / Launchpad から再度起動された場合は設定を開く (Windows のトレイ左クリック相当)。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow?.show()
        return true
    }
}
