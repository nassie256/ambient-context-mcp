import Foundation
import Network

import AmbientContextCore

/// C# `WindowsNetworkContextCollector` (`NetworkInterface.GetIsNetworkAvailable`) の macOS 版。
///
/// `NWPathMonitor` は「開始してから最初のパスが届くまで」に僅かなラグがあるため、
/// capture のたびに作り直さず 1 個を常駐させ、最新パスをキャッシュして同期で読む。
/// Windows 版は空だった `interfaceKinds` をここで埋める (設計書 §3.3)。
///
/// **最初のパスを待たないと起動直後の capture が offline になり、次の capture で
/// 嘘の `network_connectivity_changed` (offline→online) が出る。** そのため
/// `waitForFirstPath(timeout:)` で最初の pathUpdateHandler を上限付きで待てるようにする。
/// `start(queue:)` 直後の `monitor.currentPath` でも種を撒くが、実測ではこの時点では
/// まだ未解決を返すことが多く、当てにはできない (待ちの方が本体)。
///
/// `stop()` は monitor を破棄する。`NWPathMonitor` は cancel すると再利用できないので、
/// `start()` は毎回新しい monitor を作る (= start / stop は何度でも往復できる)。
public final class NetworkCollector: @unchecked Sendable {
    /// 起動時に最初のパスを待つ既定の上限。
    public static let defaultFirstPathTimeout: TimeInterval = 0.3

    private let queue = DispatchQueue(label: "ambient-context.network-monitor")
    private let lock = NSLock()
    private var monitor: NWPathMonitor?
    private var latest = NetworkContext()
    /// 「信用できるパスを 1 度観測した」フラグ。`stop()` で false に戻る。
    private var hasResolvedPath = false
    private var pathWaiters: [ResumeOnce] = []

    public init() {}

    /// 監視を開始する。二重呼び出しは無視する。`stop()` 後の再開も可能。
    public func start() {
        let monitor = NWPathMonitor()

        lock.lock()
        if self.monitor != nil {
            lock.unlock()
            return
        }
        self.monitor = monitor
        hasResolvedPath = false
        lock.unlock()

        monitor.pathUpdateHandler = { [weak self] path in
            self?.record(path, fromUpdateHandler: true)
        }
        monitor.start(queue: queue)
        // ベストエフォートの種まき。**実測では `start(queue:)` の直後の `currentPath` は
        // まだ未解決 (status = .unsatisfied, availableInterfaces = []) を返すことが多い**ので、
        // これだけでは足りない。起動直後の offline を防ぐ本体は `waitForFirstPath` の方。
        // satisfied のときだけ「解決済み」に数える (未解決の既定値で待ちを打ち切らないため)。
        record(monitor.currentPath, fromUpdateHandler: false)
    }

    /// 最初のパスが確定するまで `timeout` を上限に待つ。既に確定済みなら即座に返る。
    ///
    /// 待ち切れなかった場合は既定値 (offline) のまま先に進む。Windows 版も
    /// `GetIsNetworkAvailable` が誤ることはあるので、遅延より capture の完了を優先する。
    public func waitForFirstPath(timeout: TimeInterval = NetworkCollector.defaultFirstPathTimeout) async {
        guard needsToWaitForPath() else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let waiter = ResumeOnce(continuation)
            guard enqueue(waiter) else {
                waiter.resume()
                return
            }
            queue.asyncAfter(deadline: .now() + timeout) { waiter.resume() }
        }
    }

    /// NSLock は async 文脈から直接触れないので、ロックを使う判定は同期関数に閉じ込める。
    private func needsToWaitForPath() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !hasResolvedPath && monitor != nil
    }

    /// 待機列に加えられたら true。既に確定済み / 停止済みなら false (呼び出し側が即 resume)。
    private func enqueue(_ waiter: ResumeOnce) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasResolvedPath, monitor != nil else { return false }
        pathWaiters.append(waiter)
        return true
    }

    /// 監視を開始し、最初のパスを上限付きで待つ (起動シーケンス用)。
    public func startAndWaitForFirstPath(
        timeout: TimeInterval = NetworkCollector.defaultFirstPathTimeout
    ) async {
        start()
        await waitForFirstPath(timeout: timeout)
    }

    public func stop() {
        lock.lock()
        let running = monitor
        monitor = nil
        hasResolvedPath = false
        let waiters = pathWaiters
        pathWaiters.removeAll()
        lock.unlock()

        running?.cancel()
        // 待っている呼び出し元を宙吊りにしない。
        for waiter in waiters { waiter.resume() }
    }

    /// 直近に観測したパス。まだ 1 度も届いていなければ既定値 (offline / 空リスト)。
    public func collect() -> NetworkContext {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// 最初のパスを観測済みか (テスト・診断用)。
    public var hasObservedPath: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasResolvedPath
    }

    private func record(_ path: NWPath, fromUpdateHandler: Bool) {
        let context = NetworkContext(
            isAvailable: path.status == .satisfied,
            interfaceKinds: Self.interfaceKinds(of: path))

        var waiters: [ResumeOnce] = []
        lock.lock()
        latest = context
        // pathUpdateHandler の値は常に信用する。currentPath の種は satisfied のときだけ。
        if fromUpdateHandler || context.isAvailable {
            hasResolvedPath = true
            waiters = pathWaiters
            pathWaiters.removeAll()
        }
        lock.unlock()

        for waiter in waiters { waiter.resume() }
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

    /// 継続を高々 1 回だけ再開するラッパ (パス到着とタイムアウトの競合を吸収する)。
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Never>?

        init(_ continuation: CheckedContinuation<Void, Never>) {
            self.continuation = continuation
        }

        func resume() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume()
        }
    }
}
