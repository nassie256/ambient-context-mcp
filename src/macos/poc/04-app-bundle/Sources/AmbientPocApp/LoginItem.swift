import Foundation
import ServiceManagement

/// SMAppService.mainApp のラッパ。実 .app バンドルから起動されていないと
/// register() は kSMErrorInvalidSignature 等で失敗する (PoC ではその挙動も記録する)。
enum LoginItem {
    static func statusText() -> String {
        switch SMAppService.mainApp.status {
        case .notRegistered: return "notRegistered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notFound: return "notFound"
        @unknown default: return "unknown"
        }
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @discardableResult
    static func register() -> String {
        do {
            try SMAppService.mainApp.register()
            let s = "loginitem register ok status=\(statusText())"
            PocLog.log(s)
            return s
        } catch {
            let ns = error as NSError
            let s = "loginitem register FAILED domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription) status=\(statusText())"
            PocLog.log(s)
            return s
        }
    }

    @discardableResult
    static func unregister() -> String {
        do {
            try SMAppService.mainApp.unregister()
            let s = "loginitem unregister ok status=\(statusText())"
            PocLog.log(s)
            return s
        } catch {
            let ns = error as NSError
            let s = "loginitem unregister FAILED domain=\(ns.domain) code=\(ns.code) desc=\(ns.localizedDescription) status=\(statusText())"
            PocLog.log(s)
            return s
        }
    }
}
