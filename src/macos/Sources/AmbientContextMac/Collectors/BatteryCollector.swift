import Foundation
import IOKit.ps

import AmbientContextCore

/// C# `WindowsBatteryContextCollector` (`GetSystemPowerStatus`) の macOS 版。
/// IOKit の IOPowerSources を使う (設計書 §3.3)。`batterySaver` は低電力モード。
public struct BatteryCollector: Sendable {
    public init() {}

    public func collect() -> BatteryContext {
        let reading = Self.readPowerSources()
        let batterySaver = ProcessInfo.processInfo.isLowPowerModeEnabled

        return BatteryContext(
            present: reading.present,
            percent: reading.percent,
            charging: reading.charging,
            onAcPower: reading.onAcPower,
            batterySaver: batterySaver,
            bucket: AmbientTier1Rules.getBatteryBucket(
                percent: reading.percent,
                charging: reading.charging))
    }

    /// IOPS から読み出した生の値。読めなかった項目は nil。
    public struct PowerSourceReading: Sendable, Hashable {
        public var present = false
        public var percent: Int?
        public var charging: Bool?
        public var onAcPower: Bool?
        /// `IOPSGetProvidingPowerSourceType` の生文字列 (`AC Power` / `Battery Power` / `UPS Power`)。
        public var providingPowerSourceType = ""

        public init() {}
    }

    /// 例外を投げず、値が取れなければ既定値のまま返す。
    public static func readPowerSources() -> PowerSourceReading {
        var reading = PowerSourceReading()

        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else {
            return reading
        }

        reading.providingPowerSourceType =
            IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String? ?? ""
        if !reading.providingPowerSourceType.isEmpty {
            reading.onAcPower = reading.providingPowerSourceType == kIOPMACPowerKey
        }

        guard let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else {
            return reading
        }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let type = description[kIOPSTypeKey] as? String ?? ""
            // 内蔵バッテリのみを battery.* に写像する (UPS は power source type 側で扱う)。
            guard type == kIOPSInternalBatteryType else { continue }

            reading.present = true
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let maximum = description[kIOPSMaxCapacityKey] as? Int,
               maximum > 0 {
                reading.percent = min(100, max(0, Int((Double(current) / Double(maximum) * 100).rounded())))
            }
            if let charging = description[kIOPSIsChargingKey] as? Bool {
                reading.charging = charging
            }
            if let state = description[kIOPSPowerSourceStateKey] as? String {
                reading.onAcPower = state == kIOPSACPowerValue
            }
            break
        }

        return reading
    }
}
