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
    /// `requiresApproval` (登録済みだがユーザがシステム設定で無効化) も「有効にしようとしている」
    /// 状態なのでチェック ON として扱う。
    static var isEnabled: Bool {
        let current = status
        return current == .enabled || current == .requiresApproval
    }

    /// C# `Enable()` / `Disable()` 相当。
    /// - Returns: 成功なら nil、失敗ならユーザ向けの理由文字列。
    @discardableResult
    static func apply(enabled: Bool) -> String? {
        guard isAvailable else {
            AppDiagnosticLog.shared.log(
                category: "autostart", event: "not_bundled",
                detail: ["requested": .bool(enabled), "bundlePath": .string(Bundle.main.bundlePath)])
            return Strings.text("MacAutostartNotBundled")
        }

        do {
            if enabled {
                if status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
            }
            AppDiagnosticLog.shared.log(
                category: "autostart", event: enabled ? "enabled" : "disabled",
                detail: ["status": .string(statusText)])
            return enabled && status == .requiresApproval
                ? Strings.text("MacAutostartRequiresApproval")
                : nil
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
            return Strings.format("MacAutostartUnavailableFormat", nsError.localizedDescription)
        }
    }
}
