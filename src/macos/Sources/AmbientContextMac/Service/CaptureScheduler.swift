import Foundation

/// C# `AmbientContextHostedService` (`PeriodicTimer` 60 秒) の Swift 版。
/// `Task` のスリープループから `MacAmbientContextService.requestPeriodicCapture()` を呼ぶ。
public final class CaptureScheduler: @unchecked Sendable {
    private let intervalSeconds: Int
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(intervalSeconds: Int) {
        self.intervalSeconds = intervalSeconds
    }

    /// 既に動いていれば何もしない。
    public func start(_ tick: @escaping @Sendable () async -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard task == nil else { return }

        let interval = UInt64(max(1, intervalSeconds)) * 1_000_000_000
        task = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: interval)
                } catch {
                    return // キャンセル (通常のシャットダウン)
                }
                if Task.isCancelled { return }
                await tick()
            }
        }
    }

    public func stop() {
        lock.lock()
        let running = task
        task = nil
        lock.unlock()
        running?.cancel()
    }
}
