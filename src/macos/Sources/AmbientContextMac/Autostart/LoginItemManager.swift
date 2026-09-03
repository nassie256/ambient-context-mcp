import AppKit
import Foundation
import ServiceManagement

import AmbientContextCore

/// C# `AutostartManager` (HKCU\...\Run) の macOS 版。`SMAppService.mainApp` を使うので
/// システム設定の「一般 → ログイン項目」に "Ambient Context MCP" として現れる。
///
/// `SMAppService` は **実際の .app バンドルから起動されていること** を要求する。
/// `swift run` の裸バイナリでは `register()` が
/// `SMAppServiceErrorDomain code=1` (kSMErrorInvalidSignature) 等で失敗するので、
/// UI に例外を投げず「理由の文字列」を返して設定画面のステータス行に出す (PoC 4 §6.3)。
enum LoginItemManager {
    /// .app バンドル内で動いているか。false のときログイン項目は使えない。
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    static var status: SMAppService.Status {
        SMAppService.mainApp.status
    }

    static var statusText: String {
        switch status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    /// C# `AutostartManager.IsEnabled()` 相当。
    /// `requiresApproval` は「登録済みだがユーザ承認待ち」なので **有効** 側に数える
    /// (チェックは ON のまま、承認が要ることはステータス行の注記で伝える)。
    static var isEnabled: Bool {
        let current = status
        return current == .enabled || current == .requiresApproval
    }

    /// `apply(enabled:)` の結果。
    /// 「失敗」と「登録できたが承認待ち」を呼び出し側が区別できるようにする
    /// (承認待ちはチェックを ON のままにしたい。失敗のときだけ実状態へ戻す)。
    enum ApplyOutcome: Sendable, Equatable {
        /// 要求どおりになった。
        case applied
        /// 登録はできたが、システム設定でユーザの承認 (有効化) が要る。
        case pendingApproval(String)
        /// 変更できなかった。
        case failed(String)

        /// ステータス行に出す注記 (無ければ空文字)。
        var message: String {
            switch self {
            case .applied: return ""
            case .pendingApproval(let text), .failed(let text): return text
            }
        }

        var isFailure: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// C# `Enable()` / `Disable()` 相当。
    @discardableResult
    static func apply(enabled: Bool) -> ApplyOutcome {
        guard isAvailable else {
            AppDiagnosticLog.shared.log(
                category: "autostart", event: "not_bundled",
                detail: ["requested": .bool(enabled), "bundlePath": .string(Bundle.main.bundlePath)])
            return .failed(Strings.text("MacAutostartNotBundled"))
        }

        do {
            if enabled {
                if status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                // 一度も register() していない .app の status は `.notFound` になる。
                // その状態で unregister() を呼ぶと SMAppServiceErrorDomain code=1
                // ("Operation not permitted") を投げるので、登録済み
                // (`.enabled` / `.requiresApproval`) のときだけ解除する。
                // `.notFound` / `.notRegistered` は「既に無効」なので C#
                // `AutostartManager.Disable()` (値が無ければ何もしない) と同じく no-op。
                if isEnabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            AppDiagnosticLog.shared.log(
                category: "autostart", event: enabled ? "enabled" : "disabled",
                detail: ["status": .string(statusText)])
            // register() 直後の status は反映が遅れることがある。ここでの読み出しは
            // 「承認待ちかどうか」の注記にだけ使い、チェックボックスの値には反映しない。
            return enabled && status == .requiresApproval
                ? .pendingApproval(Strings.text("MacAutostartRequiresApproval"))
                : .applied
        } catch {
            let nsError = error as NSError
            AppDiagnosticLog.shared.logError(
                category: "autostart", event: "apply_failed", error: error,
                detail: [
                    "requested": .bool(enabled),
                    "domain": .string(nsError.domain),
                    "code": .int(nsError.code),
                    "status": .string(statusText)
                ])
            return .failed(
                Strings.format("MacAutostartUnavailableFormat", nsError.localizedDescription))
        }
    }
}
