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

    /// C# `SettingsWindowPlacement` と同じ既定値 / 下限。
    static let defaultWidth: CGFloat = 720
    static let defaultHeight: CGFloat = 760
    static let minWidth: CGFloat = 480
    static let minHeight: CGFloat = 480

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
        beginForegroundPresentation()
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
        // 既定の sizingOptions には `.minSize` が入っていて、SwiftUI コンテンツの最小サイズが
        // そのままウィンドウの `contentMinSize` を上書きしてしまう。その結果ウィンドウが
        // 画面より高いまま縮められなくなるので、サイズ制約は下の `contentMinSize` だけに任せる。
        controller.sizingOptions = []

        let window = NSWindow(contentViewController: controller)
        window.title = Strings.windowTitle
        // 最小化 / ズームは無し。リサイズは可 (Windows 版もサイズ変更できる)。
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentMinSize = NSSize(width: Self.minWidth, height: Self.minHeight)
        window.setContentSize(NSSize(width: Self.defaultWidth, height: Self.defaultHeight))
        // setFrameAutosaveName は「以後の変更を保存する」だけ。素の NSWindow には
        // NSWindowController のような自動復元が無いので、保存済みフレームは自分で読む。
        window.setFrameAutosaveName(Self.frameAutosaveName)
        let restored = window.setFrameUsingName(Self.frameAutosaveName)
        Self.applyPlacement(to: window, restored: restored)
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

    /// C# `SettingsWindowPlacement.Apply` 相当。復元したフレームを作業領域 (メニューバー /
    /// Dock を除いた領域) に収める。
    ///
    /// `setFrameUsingName` は保存時のサイズをそのまま復元するので、以前に画面より高い
    /// ウィンドウを保存していると画面外にはみ出したまま開いてしまう。サイズは
    /// `minWidth/minHeight`〜作業領域に clamp し、位置もタイトルバーを掴める範囲へ寄せる。
    /// 初回 (復元なし) は既定サイズで作業領域の中央に置く。
    private static func applyPlacement(to window: NSWindow, restored: Bool) {
        let screen = window.screen ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        var frame = window.frame
        frame.size.width = min(max(frame.width, minWidth), visible.width)
        frame.size.height = min(max(frame.height, minHeight), visible.height)

        if restored {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        } else {
            frame.origin.x = visible.minX + (visible.width - frame.width) / 2
            frame.origin.y = visible.minY + (visible.height - frame.height) / 2
        }

        window.setFrame(frame, display: false)
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

    /// 設定ウィンドウを開いている間だけ「通常のアプリ」になる (設計書 §7.1 バグ 2)。
    ///
    /// `.accessory` のままだと、ウィンドウを出しても **アプリはアクティブになれない**
    /// (`NSApp.activate` も System Events の `set frontmost` も効かない)。その結果
    /// Accessibility API から見ると `frontmost: false` で、ウィンドウが列挙できたり
    /// できなかったりし、SwiftUI 側の AX 属性 (ボタン名など) も埋まらないため
    /// `click button "保存"` のような AX 操作が一切通らなかった。
    ///
    /// メニューバー常駐アプリで設定ウィンドウを持つときの定番の回避策として、
    /// **ウィンドウが開いている間だけ `.regular`** に切り替え、閉じたら `.accessory` に戻す。
    /// 開いている間は Dock アイコンと通常のアプリメニューが出る (許容する差分。README/
    /// 設計書に明記)。常駐そのものは `applicationShouldTerminateAfterLastWindowClosed` が
    /// false なので影響を受けない。
    private func beginForegroundPresentation() {
        guard NSApp.activationPolicy() != .regular else { return }
        NSApp.setActivationPolicy(.regular)
        AppDiagnosticLog.shared.log(
            category: "settings", event: "activation_policy",
            detail: ["policy": .string("regular")])
    }

    /// ウィンドウを閉じたら常駐アプリ (Dock に出ない) に戻す。
    private func endForegroundPresentation() {
        guard NSApp.activationPolicy() != .accessory else { return }
        NSApp.setActivationPolicy(.accessory)
        AppDiagnosticLog.shared.log(
            category: "settings", event: "activation_policy",
            detail: ["policy": .string("accessory")])
    }

    func windowWillClose(_ notification: Notification) {
        AppDiagnosticLog.shared.log(category: "settings", event: "window_closing")
        endForegroundPresentation()
        // .accessory なのでウィンドウを閉じてもアプリは常駐し続ける。
        // インスタンスは保持し、次回 show() で同じウィンドウ (と位置) を再表示する。
        // 未保存の編集は次の show() の reload() で捨てる (C# の作り直しと同じ結果)。
    }
}
