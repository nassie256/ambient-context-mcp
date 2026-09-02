import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var paused = false
    private let port = 37690
    private var mcpUrl: String { "http://127.0.0.1:\(port)/mcp" }
    private let token = "poc-token-0123456789"

    func applicationDidFinishLaunching(_ notification: Notification) {
        PocLog.log("app didFinishLaunching pid=\(ProcessInfo.processInfo.processIdentifier) bundle=\(Bundle.main.bundlePath) bundleId=\(Bundle.main.bundleIdentifier ?? "<none>")")
        PocLog.log("activationPolicy=\(NSApp.activationPolicy().rawValue) (1 = .accessory)")
        L.dumpResolved()
        PocLog.log("loginitem initial status=\(LoginItem.statusText())")

        installStatusItem()
        runScriptedActions()
    }

    // MARK: - Status item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else {
            PocLog.log("statusitem FAILED: no button")
            return
        }
        button.image = Self.makeTemplateImage()
        button.image?.isTemplate = true
        button.toolTip = "Ambient Context MCP"
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item
        PocLog.log("statusitem created visible=\(item.isVisible) length=\(item.length) hasImage=\(button.image != nil) template=\(button.image?.isTemplate ?? false)")
    }

    /// メニューバー用テンプレート画像をコードで描画 (actool 不要)。
    private static func makeTemplateImage() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            // 同心の弧 3 本 + 中心のドット ("ambient" を表す電波風のマーク)
            for (i, r) in [3.0, 6.0, 8.0].enumerated() {
                let path = NSBezierPath()
                path.appendArc(withCenter: NSPoint(x: rect.midX, y: rect.midY - 5),
                               radius: r, startAngle: 35, endAngle: 145)
                path.lineWidth = 1.5 - Double(i) * 0.1
                path.stroke()
            }
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 1.5, y: rect.midY - 6.5, width: 3, height: 3)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let type = NSApp.currentEvent?.type
        PocLog.log("statusitem click eventType=\(String(describing: type))")
        if type == .rightMouseUp {
            showMenu()
        } else {
            openSettings()
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let suffix = paused ? L.pausedSuffix : ""
        let status = NSMenuItem(title: "Ambient Context MCP — :\(port)\(suffix)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(makeItem(L.settings, #selector(openSettingsMenu)))
        menu.addItem(.separator())
        menu.addItem(makeItem(L.copyMcpUrl, #selector(copyUrl)))
        menu.addItem(makeItem(L.copyMcpToken, #selector(copyToken)))
        menu.addItem(makeItem(L.copyClaudeCodeSnippet, #selector(copySnippet)))
        menu.addItem(.separator())
        menu.addItem(makeItem(paused ? L.resume : L.pause, #selector(togglePause)))
        menu.addItem(.separator())
        menu.addItem(makeItem(L.exit, #selector(quit)))
        return menu
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func showMenu() {
        guard let statusItem else { return }
        let menu = buildMenu()
        PocLog.log("menu items=\(menu.items.map(\.title))")
        // menu をセットして popUp すると以降の左クリックもメニューになるため、
        // 表示直後に nil に戻す (Windows 版の TrackPopupMenu 相当)。
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // MARK: - Menu actions

    @objc private func openSettingsMenu() { openSettings() }

    @objc private func copyUrl() { copy(mcpUrl, label: "url") }
    @objc private func copyToken() { copy(token, label: "token") }
    @objc private func copySnippet() {
        copy("claude mcp add ambient-context --transport http \(mcpUrl) --header \"Authorization: Bearer \(token)\"", label: "snippet")
    }

    private func copy(_ value: String, label: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        let ok = pb.setString(value, forType: .string)
        PocLog.log("pasteboard copy \(label) ok=\(ok) readback=\(pb.string(forType: .string) == value)")
    }

    @objc private func togglePause() {
        paused.toggle()
        PocLog.log("pause toggled paused=\(paused)")
    }

    @objc private func quit() {
        PocLog.log("quit requested")
        NSApp.terminate(nil)
    }

    // MARK: - Settings window

    func openSettings() {
        if let window = settingsWindow {
            PocLog.log("settings window reuse frame=\(NSStringFromRect(window.frame))")
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: controller)
        window.title = L.t("settings.title")
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false // 閉じてもインスタンスを保持し、再表示できるようにする
        window.delegate = self
        window.setContentSize(NSSize(width: 520, height: 360))
        window.setFrameAutosaveName("SettingsWindow")
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        PocLog.log("settings window created autosave=\(window.frameAutosaveName) frame=\(NSStringFromRect(window.frame))")
    }

    func windowWillClose(_ notification: Notification) {
        // .accessory なのでウィンドウを閉じてもアプリは終了しない。
        PocLog.log("settings window closed; app stays alive (LSUIElement/.accessory)")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        PocLog.log("app willTerminate")
    }

    // MARK: - Scripted self-test (画面が見えない環境用)

    private func runScriptedActions() {
        let env = ProcessInfo.processInfo.environment
        if let secs = env["AMBIENT_POC_AUTOQUIT"].flatMap(Double.init) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
                PocLog.log("autoquit")
                NSApp.terminate(nil)
            }
        }
        guard env["AMBIENT_POC_SELFTEST"] == "1" else { return }
        PocLog.log("selftest begin")
        copyUrl()
        copyToken()
        copySnippet()
        togglePause()
        PocLog.log("menu(paused) items=\(buildMenu().items.map(\.title))")
        togglePause()
        openSettings()
        settingsWindow?.close()
        openSettings() // 再表示 = 同一インスタンスであることの確認
        PocLog.log("settings window same instance on reopen=\(settingsWindow != nil)")
        settingsWindow?.close()

        if env["AMBIENT_POC_LOGINITEM"] == "cycle" {
            LoginItem.register()
            LoginItem.unregister()
            PocLog.log("loginitem final status=\(LoginItem.statusText())")
        }
        PocLog.log("selftest end")
    }
}
