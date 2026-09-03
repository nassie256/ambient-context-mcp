import Foundation

import AmbientContextCore

/// C# `WindowsSystemContextCollector.GetSystem` の macOS 版。
///
/// `timeZoneId` は Windows の `Tokyo Standard Time` 形式ではなく IANA ID (`Asia/Tokyo`) になる。
/// これは設計書 §3.3 で承認済みの差分。
public struct SystemCollector: Sendable {
    public init() {}

    public func collect(now: Date = Date()) -> SystemContext {
        let zone = TimeZone.current
        return SystemContext(
            timeZoneId: zone.identifier,
            utcOffsetMinutes: zone.secondsFromGMT(for: now) / 60,
            uptimeSeconds: Int64(ProcessInfo.processInfo.systemUptime),
            // macOS 14+ は 64bit 専用 (Apple Silicon / Intel の 64bit のみ)。
            is64BitOperatingSystem: true,
            processArchitecture: Self.processArchitecture)
    }

    /// C# の `RuntimeInformation.ProcessArchitecture.ToString()` に対応する値。
    /// Windows 版は `X64` / `Arm64` を返すが、macOS では OS 慣用の `arm64` / `x86_64` を使う。
    public static let processArchitecture: String = {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }()
}
