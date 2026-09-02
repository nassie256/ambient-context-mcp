import Foundation
import Network

import AmbientContextCore

/// C# `WindowsNetworkContextCollector` (`NetworkInterface.GetIsNetworkAvailable`) の macOS 版。
///
/// `NWPathMonitor` は「開始してから最初のパスが届くまで」に僅かなラグがあるため、
/// capture のたびに作り直さず 1 個を常駐させ、最新パスをキャッシュして同期で読む。
/// Windows 版は空だった `interfaceKinds` をここで埋める (設計書 §3.3)。
public final class NetworkCollector: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ambient-context.network-monitor")
    private let lock = NSLock()
    private var latest = NetworkContext()
    private var started = false

    public init() {}

    /// 監視を開始する。二重呼び出しは無視する。
    public func start() {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let context = NetworkContext(
                isAvailable: path.status == .satisfied,
                interfaceKinds: Self.interfaceKinds(of: path))
            self.lock.lock()
            self.latest = context
            self.lock.unlock()
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        lock.lock()
        let wasStarted = started
        started = false
        lock.unlock()
        if wasStarted {
            monitor.cancel()
        }
    }

    /// 直近に観測したパス。まだ 1 度も届いていなければ既定値 (offline / 空リスト)。
    public func collect() -> NetworkContext {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// `NWPath.availableInterfaces` の種別を wifi / wired / cellular / other に写像する。
    /// 重複は排除し、出現順を保つ。
    static func interfaceKinds(of path: NWPath) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for interface in path.availableInterfaces {
            let kind = interfaceKind(interface.type)
            if seen.insert(kind).inserted {
                result.append(kind)
            }
        }
        return result
    }

    static func interfaceKind(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .wiredEthernet: return "wired"
        case .cellular: return "cellular"
        case .loopback, .other: return "other"
        @unknown default: return "other"
        }
    }
}
