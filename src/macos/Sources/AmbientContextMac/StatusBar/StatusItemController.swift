import AppKit
import Foundation

import AmbientContextCore
import AmbientContextMcpServer

/// C# `TrayHost` / `TrayService` (Shell_NotifyIcon + TrackPopupMenu) の macOS 版。
///
/// - 左クリック (とキーボード起動) → 設定ウィンドウ
/// - 右クリック / Ctrl+クリック → コンテキストメニュー
///
/// メニュー項目は Windows 版と同じ 8 項目 (状態行 / 設定 / URL / Token / スニペット /
/// 一時停止・再開 / 終了)。診断ログのカテゴリとイベント名も Windows と揃える
/// (`tray/notify_icon_visible`, `tray/icon_left_click`, `tray/menu_click`, `tray/pause_toggle`)。
@MainActor
final class StatusItemController: NSObject {
    private let mcpHost: McpServerHost
    private let pauseFlag: PauseFlag
    private let openSettings: () -> Void
    private let requestQuit: () -> Void

    private var statusItem: NSStatusItem?

    init(
        mcpHost: McpServerHost,
        pauseFlag: PauseFlag,
        openSettings: @escaping () -> Void,
        requestQuit: @escaping () -> Void
    ) {
        self.mcpHost = mcpHost
        self.pauseFlag = pauseFlag
        self.openSettings = openSettings
        self.requestQuit = requestQuit
        super.init()
    }

    var isPaused: Bool { pauseFlag.isPaused }

    // MARK: - ライフサイクル

    func show() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            AppDiagnosticLog.shared.log(category: "tray", event: "status_item_no_button")
            return
        }
        button.image = MenuBarIcon.makeImage()
        button.toolTip = "Ambient Context MCP"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        // 左右どちらのクリックも 1 つの action で受け、NSApp.currentEvent で分岐する
        // (Windows 版が NIN_SELECT / WM_CONTEXTMENU を 1 つの WndProc で分けるのと同じ)。
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        // VoiceOver / キーボード操作からもメニューを開けるようにしておく。
        button.setAccessibilityLabel("Ambient Context MCP")
        statusItem = item

        // 画面が見えない環境 (CI / 自動検証) でもローカライズとメニュー構成を確認できるよう、
        // 生成したメニュー項目名を 1 行だけ残す。
        AppDiagnosticLog.shared.log(
            category: "tray", event: "notify_icon_visible",
            detail: [
                "language": .string(Strings.language),
                "items": .string(buildMenu().items.map(\.title).joined(separator: " | "))
            ])
    }

    /// 終了時にメニューバーからアイコンを取り除く (C# の `Shell_NotifyIcon(NIM_DELETE)` 相当)。
    func remove() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        AppDiagnosticLog.shared.log(category: "tray", event: "notify_icon_removed")
    }

    // MARK: - クリック

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isSecondary = event?.type == .rightMouseUp
            || (event?.modifierFlags.contains(.control) ?? false)
        if isSecondary {
            showMenu()
        } else {
            AppDiagnosticLog.shared.log(category: "tray", event: "icon_left_click")
            openSettings()
        }
    }

    private func showMenu() {
        guard let statusItem else { return }
        let menu = buildMenu()
        // menu を張ったままにすると以降の左クリックもメニューになるため、
        // 表示直後に外す (Windows の TrackPopupMenu 相当 / PoC 4 §4)。
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// C# `TrayHost.ShowContextMenu` と同じ並び。
    func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let status = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(makeItem(Strings.traySettings, #selector(menuOpenSettings)))
        menu.addItem(.separator())
        menu.addItem(makeItem(Strings.trayCopyMcpUrl, #selector(menuCopyUrl)))
        menu.addItem(makeItem(Strings.trayCopyMcpToken, #selector(menuCopyToken)))
        menu.addItem(makeItem(Strings.trayCopyClaudeCodeSnippet, #selector(menuCopySnippet)))
        menu.addItem(.separator())
        menu.addItem(makeItem(
            pauseFlag.isPaused ? Strings.trayResume : Strings.trayPause,
            #selector(menuTogglePause)))
        menu.addItem(.separator())
        menu.addItem(makeItem(Strings.trayExit, #selector(menuQuit)))
        return menu
    }

    /// C# `GetStatusText()`。
    var statusText: String {
        let suffix = pauseFlag.isPaused ? Strings.trayPausedSuffix : ""
        return "Ambient Context MCP — :\(mcpHost.settings.port)\(suffix)"
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = true
        return item
    }

    // MARK: - メニュー項目

    @objc private func menuOpenSettings() {
        logMenuClick("settings")
        openSettings()
    }

    @objc private func menuCopyUrl() {
        logMenuClick("copy_url")
        Pasteboard.copy(mcpHost.mcpUrl)
    }

    @objc private func menuCopyToken() {
        logMenuClick("copy_token")
        Pasteboard.copy(mcpHost.token)
    }

    @objc private func menuCopySnippet() {
        logMenuClick("copy_snippet")
        Pasteboard.copy(McpClientSnippets.buildClaudeCodeSnippet(
            mcpUrl: mcpHost.mcpUrl, token: mcpHost.token))
    }

    @objc private func menuTogglePause() {
        logMenuClick("pause_resume")
        let paused = pauseFlag.toggle()
        AppDiagnosticLog.shared.log(
            category: "tray", event: "pause_toggle", detail: ["paused": .bool(paused)])
    }

    @objc private func menuQuit() {
        logMenuClick("exit")
        requestQuit()
    }

    private func logMenuClick(_ command: String) {
        AppDiagnosticLog.shared.log(
            category: "tray", event: "menu_click", detail: ["cmd": .string(command)])
    }
}

/// 一時停止フラグ。メニュー (メインスレッド) が書き、`snapshotUpdated` ハンドラ
/// (actor のコンテキスト) が読むのでロックで守る。C# の `TrayHost._paused` +
/// `TrayService.IsPaused` に対応する。
final class PauseFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var paused = false

    var isPaused: Bool {
        lock.lock()
        defer { lock.unlock() }
        return paused
    }

    @discardableResult
    func toggle() -> Bool {
        lock.lock()
        paused.toggle()
        let value = paused
        lock.unlock()
        return value
    }
}

/// C# `ClipboardHelper.SafeCopy` 相当。
enum Pasteboard {
    static func copy(_ value: String) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
