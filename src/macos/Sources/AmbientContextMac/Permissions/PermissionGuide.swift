import AppKit
import ApplicationServices
import Foundation

import AmbientContextCore

/// 権限が要る収集項目を ON にした「その時だけ」システム設定へ誘導する (設計書 §3.3 / §4 Phase 4)。
///
/// Windows 版には対応物が無い macOS 固有の画面。原則:
/// - **起動時には絶対にプロンプトを出さない。** opt-in していないユーザには一切問い合わせない
///   (`CaptureFeatureFlags` が収集自体も止めている)
/// - アクセシビリティ: `AXIsProcessTrusted()` が false のときだけ案内し、
///   `AXIsProcessTrustedWithOptions(prompt: true)` はプロセスで 1 度だけ呼ぶ
///   (非ブロッキングで即 false を返す。許可は次回 capture 時に反映される)
/// - オートメーション: 事前確認 API が無いため、
///   「Music / Spotify が起動している状態での次回取得時に OS が尋ねる」ことを説明するだけ
@MainActor
enum PermissionGuide {
    private static let accessibilityPaneUrl =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
    private static let automationPaneUrl =
        "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"

    /// 同じ保存操作を繰り返すたびに出さないためのフラグ (プロセス内で 1 度)。
    private static var accessibilityGuideShown = false
    private static var automationGuideShown = false
    private static var accessibilityPrompted = false

    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// 設定保存の直後に呼ぶ。
    /// - Parameters:
    ///   - titleEnabled: 保存後に `foreground.titleSummary` / `foreground.rawTitle` のどちらかが ON か。
    ///   - mediaEnabled: 保存後に `media.*` のいずれかが ON か。
    ///   - mediaNewlyEnabled: 今回の保存で media が OFF→ON になったか (ON のままの再保存では出さない)。
    ///   - window: シートの親。nil なら独立ウィンドウのアラートになる。
    static func checkAfterSave(
        titleEnabled: Bool,
        mediaEnabled: Bool,
        mediaNewlyEnabled: Bool,
        presentingOn window: NSWindow?
    ) {
        if titleEnabled, !AXIsProcessTrusted(), !accessibilityGuideShown {
            accessibilityGuideShown = true
            AppDiagnosticLog.shared.log(
                category: "permissions", event: "accessibility_guide_shown",
                detail: ["trusted": .bool(false)])
            present(
                title: Strings.text("MacPermissionAccessibilityTitle"),
                message: Strings.text("MacPermissionAccessibilityMessage"),
                paneUrl: accessibilityPaneUrl,
                window: window,
                onOpen: { requestAccessibilityPromptOnce() })
        }

        if mediaEnabled, mediaNewlyEnabled, !automationGuideShown {
            automationGuideShown = true
            AppDiagnosticLog.shared.log(category: "permissions", event: "automation_guide_shown")
            present(
                title: Strings.text("MacPermissionAutomationTitle"),
                message: Strings.text("MacPermissionAutomationMessage"),
                paneUrl: automationPaneUrl,
                window: window,
                onOpen: nil)
        }
    }

    /// `AXIsProcessTrustedWithOptions(prompt: true)` はプロセスあたり 1 度だけ。
    /// 非ブロッキングで即 false を返し、OS が「システム設定を開きますか」ダイアログを出す。
    private static func requestAccessibilityPromptOnce() {
        guard !accessibilityPrompted else { return }
        accessibilityPrompted = true
        // `kAXTrustedCheckOptionPrompt` は C の可変グローバルとして取り込まれ、Swift 6 の
        // strict concurrency ではそのまま参照できない。値は安定した公開文字列なので直接使う。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        AppDiagnosticLog.shared.log(
            category: "permissions", event: "accessibility_prompt_requested",
            detail: ["trusted": .bool(trusted)])
    }

    private static func present(
        title: String,
        message: String,
        paneUrl: String,
        window: NSWindow?,
        onOpen: (@MainActor () -> Void)?
    ) {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: Strings.text("MacPermissionOpenSettings"))
        alert.addButton(withTitle: Strings.text("MacPermissionLater"))

        let handle: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            onOpen?()
            if let url = URL(string: paneUrl) {
                NSWorkspace.shared.open(url)
            }
        }

        if let window {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { handle(response) }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            handle(alert.runModal())
        }
    }
}
