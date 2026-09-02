import Darwin
import Foundation

import AmbientContextCore

/// C# `WindowsSystemContextCollector.GetSystemLoad` の macOS 版。
///
/// CPU は `host_statistics(HOST_CPU_LOAD_INFO)` の 2 サンプル差分 (Windows の `GetSystemTimes`
/// と同じ意味論: **初回は nil**)。メモリは `host_statistics64(HOST_VM_INFO64)` から
/// (active + wired + compressed) / 物理メモリ。
///
/// 差分状態を持つため値型ではなく参照型。actor から呼ばれる前提で内部をロックする。
public final class SystemLoadCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var lastIdleTicks: UInt64?
    private var lastTotalTicks: UInt64?

    public init() {}

    public func collect() -> SystemLoadContext {
        let cpu = cpuUsagePercent()
        let memory = Self.memoryUsedPercent()
        return SystemLoadContext(
            cpuUsagePercent: cpu,
            cpuPressureBucket: AmbientTier1Rules.getCpuPressureBucket(cpu),
            memoryUsedPercent: memory,
            memoryPressureBucket: AmbientTier1Rules.getMemoryPressureBucket(memory))
    }

    /// 初回・巻き戻り・差分 0 のときは nil (C# の `GetCpuUsagePercent` と同じ分岐)。
    public func cpuUsagePercent() -> Int? {
        guard let ticks = Self.readCpuTicks() else { return nil }

        lock.lock()
        defer { lock.unlock() }

        guard let previousIdle = lastIdleTicks,
              let previousTotal = lastTotalTicks,
              ticks.total > previousTotal,
              ticks.idle >= previousIdle else {
            lastIdleTicks = ticks.idle
            lastTotalTicks = ticks.total
            return nil
        }

        let idleDelta = ticks.idle - previousIdle
        let totalDelta = ticks.total - previousTotal
        lastIdleTicks = ticks.idle
        lastTotalTicks = ticks.total
        if totalDelta == 0 { return nil }

        let usage = 100.0 * Double(totalDelta - idleDelta) / Double(totalDelta)
        return Self.clampPercent(usage)
    }

    /// `host_statistics(HOST_CPU_LOAD_INFO)` の累積 tick。読めなければ nil。
    static func readCpuTicks() -> (idle: UInt64, total: UInt64)? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let user = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle = UInt64(info.cpu_ticks.2)
        let nice = UInt64(info.cpu_ticks.3)
        return (idle: idle, total: user + system + idle + nice)
    }

    /// (active + wired + compressed) / 物理メモリ。読めなければ nil。
    public static func memoryUsedPercent() -> Int? {
        var info = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        // `vm_kernel_page_size` はグローバル var なので Swift 6 の strict concurrency に
        // 引っかかる。host_page_size() で同じ値を取得する。
        var hostPageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &hostPageSize) == KERN_SUCCESS, hostPageSize > 0 else {
            return nil
        }
        let pageSize = UInt64(hostPageSize)
        let usedBytes = (UInt64(info.active_count)
            + UInt64(info.wire_count)
            + UInt64(info.compressor_page_count)) * pageSize
        let totalBytes = ProcessInfo.processInfo.physicalMemory
        guard totalBytes > 0 else { return nil }

        return clampPercent(100.0 * Double(usedBytes) / Double(totalBytes))
    }

    /// C# の `Math.Clamp(Math.Round(usage), 0, 100)` 相当。
    static func clampPercent(_ value: Double) -> Int {
        min(100, max(0, Int(value.rounded())))
    }
}
