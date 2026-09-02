import AppKit
import ApplicationServices
import Foundation

import AmbientContextCore

/// C# `WindowsForegroundAppCollector` の macOS 版。
///
/// - アプリ同定: `NSWorkspace.frontmostApplication` (bundle id / pid / 実行ファイル名)
/// - 分類: `AppClassificationTable.macOS` (bundle id キー)。`processName` / フォールバック
///   `appName` は実行ファイル名を使う (`localizedName` は OS 言語で変わるため — PoC 2 推奨 2)
/// - タイトル: Accessibility API。`titleCaptureEnabled` が false のときは AX を一切呼ばない
///   (権限プロンプトを誘発しないため)
///
/// `NSWorkspace` と AX はメインスレッド API なので型全体を `@MainActor` に置く (設計書 §3.2)。
@MainActor
public struct ForegroundAppCollector {
    /// 応答しないアプリで capture を止めないためのメッセージングタイムアウト (設計書 §3.3)。
    private static let axMessagingTimeoutSeconds: Float = 1.0

    public init() {}

    /// - Parameter titleCaptureEnabled: 送信ポリシー上タイトルが必要かどうか
    ///   (`CaptureFeatureFlags.isTitleCaptureEnabled`)。false なら AX を呼ばない。
    public func collect(titleCaptureEnabled: Bool) -> ForegroundAppContext {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return ForegroundAppContext()
        }

        let executableName = app.executableURL?.lastPathComponent ?? ""
        let bundleId = app.bundleIdentifier ?? ""
        // 分類キーは bundle id。取れないアプリ (一部のヘルパープロセス) は実行ファイル名で代用する。
        let classificationKey = bundleId.isEmpty ? executableName : bundleId
        let classification = AmbientTier1Rules.classifyApp(
            classificationKey,
            table: .macOS,
            fallbackName: executableName)

        let pid = app.processIdentifier
        var title = ""
        if titleCaptureEnabled {
            title = Self.focusedWindowTitle(pid: pid).title
        }

        return ForegroundAppContext(
            processName: executableName,
            processId: pid == 0 ? nil : Int(pid),
            appName: classification.appName,
            category: classification.category,
            hasWindowTitle: !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            rawWindowTitle: title,
            titleSummary: AmbientTier1Rules.summarizeWindowTitle(
                category: classification.category,
                title: title,
                rules: .macOS))
    }

    /// AX 取得の結果。`reason` は空なら成功、そうでなければ degrade 理由
    /// (`accessibility_not_trusted` など)。例外を投げず、1 秒以上ブロックしない。
    public struct TitleResult: Sendable, Hashable {
        public var title: String
        public var reason: String

        public init(title: String, reason: String) {
            self.title = title
            self.reason = reason
        }
    }

    /// アクセシビリティ権限の現在値。プロンプトは出さない
    /// (`AXIsProcessTrustedWithOptions(prompt: true)` は Phase 4 の権限誘導が担当する)。
    public static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// PoC 2 の `focusedWindowTitle` と同じ degrade 契約。
    public static func focusedWindowTitle(pid: pid_t) -> TitleResult {
        guard AXIsProcessTrusted() else {
            return TitleResult(title: "", reason: "accessibility_not_trusted")
        }

        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(appElement, axMessagingTimeoutSeconds)

        var windowRef: CFTypeRef?
        let windowError = AXUIElementCopyAttributeValue(
            appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
        guard windowError == .success, let windowRef else {
            return TitleResult(title: "", reason: "focused_window:" + axErrorName(windowError))
        }
        guard CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
            return TitleResult(title: "", reason: "focused_window:unexpected_type")
        }

        // 直前に CFTypeID が AXUIElement であることを確認済みなので、この cast は失敗しない。
        // (AXUIElement は CF 型なので条件付きキャスト `as?` が使えない。)
        let windowElement = unsafeDowncast(windowRef, to: AXUIElement.self)

        var titleRef: CFTypeRef?
        let titleError = AXUIElementCopyAttributeValue(
            windowElement, kAXTitleAttribute as CFString, &titleRef)
        guard titleError == .success, let titleRef else {
            return TitleResult(title: "", reason: "title:" + axErrorName(titleError))
        }
        guard let title = titleRef as? String else {
            return TitleResult(title: "", reason: "title:unexpected_type")
        }
        return TitleResult(title: title, reason: "")
    }

    /// AXError を診断ログ向けの短い機械可読名にする (PoC 2 と同じ表)。
    public static func axErrorName(_ error: AXError) -> String {
        switch error {
        case .success: return "success"
        case .failure: return "failure"
        case .illegalArgument: return "illegalArgument"
        case .invalidUIElement: return "invalidUIElement"
        case .invalidUIElementObserver: return "invalidUIElementObserver"
        case .cannotComplete: return "cannotComplete"
        case .attributeUnsupported: return "attributeUnsupported"
        case .actionUnsupported: return "actionUnsupported"
        case .notificationUnsupported: return "notificationUnsupported"
        case .notImplemented: return "notImplemented"
        case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
        case .notificationNotRegistered: return "notificationNotRegistered"
        case .apiDisabled: return "apiDisabled"
        case .noValue: return "noValue"
        case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
        case .notEnoughPrecision: return "notEnoughPrecision"
        @unknown default: return "unknown(\(error.rawValue))"
        }
    }
}
