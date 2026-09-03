import AppKit
import SwiftUI

import AmbientContextCore
import AmbientContextMcpServer

/// 設定ウィンドウ (`NSWindow` + `NSHostingController`) の保持と再表示。
///
/// PoC 4 の要件をそのまま適用する:
/// - `isReleasedWhenClosed = false` (閉じても同じインスタンスを再表示する)
/// - `applicationShouldTerminateAfterLastWindowClosed` = false (AppDelegate 側)
/// - 位置・サイズは `setFrameAutosaveName` に任せる (settings.json の `settingsWindow` は未使用)
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settingsStore: any SettingsStore
    private let mcpHost: McpServerHost
    private let hub: LocalContextHub
    private let service: MacAmbientContextService
    private let catalogLanguage: String

    /// `setFrameAutosaveName` / `setFrameUsingName` に使う名前 (UserDefaults のキーになる)。
    static let frameAutosaveName = "SettingsWindow"

    private var window: NSWindow?
    private var model: SettingsViewModel?

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
        super.init()
    }

    /// C# `App.OpenSettings`。既に開いていれば前面に出すだけ。
    ///
    /// C# は `Closed` でウィンドウを捨てて毎回作り直すので、閉じた時点で未保存の編集は消える。
    /// macOS 版はウィンドウとモデルを使い回す (位置を保つため) ので、代わりに再表示のたびに
    /// `reload()` して保存済みの値へ戻す。これをしないと「変更 → 閉じる → 開き直す」で
    /// 保存していない編集が残り、Windows と挙動が食い違う。
    func show() {
        AppDiagnosticLog.shared.log(category: "tray", event: "open_settings_requested")
        if let window {
            model?.reload()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let model = SettingsViewModel(
            settingsStore: settingsStore,
            mcpHost: mcpHost,
            hub: hub,
            service: service,
            catalogLanguage: catalogLanguage)
        let controller = NSHostingController(
            rootView: SettingsView(model: model, onClose: { [weak self] in self?.close() }))

        let window = NSWindow(contentViewController: controller)
        window.title = Strings.windowTitle
        // 最小化 / ズームは無し。リサイズは可 (Windows 版もサイズ変更できる)。
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: 480, height: 480)
        window.setContentSize(NSSize(width: 720, height: 760))
        // setFrameAutosaveName は「以後の変更を保存する」だけ。素の NSWindow には
        // NSWindowController のような自動復元が無いので、保存済みフレームは自分で読む。
        window.setFrameAutosaveName(Self.frameAutosaveName)
        window.setFrameUsingName(Self.frameAutosaveName)
        model.hostWindow = window

        self.window = window
        self.model = model

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        AppDiagnosticLog.shared.log(
            category: "settings", event: "window_shown",
            detail: [
                "title": .string(window.title),
                "visible": .bool(window.isVisible),
                "frame": .string(NSStringFromRect(window.frame)),
                "appWindows": .int(NSApp.windows.count)
            ])
    }

    func close() {
        window?.performClose(nil)
    }

    /// 終了時にウィンドウも畳む。
    func dispose() {
        window?.delegate = nil
        window?.close()
        window = nil
        model = nil
    }

    func windowWillClose(_ notification: Notification) {
        AppDiagnosticLog.shared.log(category: "settings", event: "window_closing")
        // .accessory なのでウィンドウを閉じてもアプリは常駐し続ける。
        // インスタンスは保持し、次回 show() で同じウィンドウ (と位置) を再表示する。
        // 未保存の編集は次の show() の reload() で捨てる (C# の作り直しと同じ結果)。
    }
}
