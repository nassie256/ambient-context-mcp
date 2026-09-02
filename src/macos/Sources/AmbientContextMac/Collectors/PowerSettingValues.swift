import Foundation

import AmbientContextCore

/// `power.lastKnownSettings.*` の **Windows 互換の setting 名と値** を作る純関数群
/// (設計書 §3.3 の対応表)。OS API に触れないのでユニットテスト可能。
///
/// 値の語彙は `WindowsPowerSettingReader.FormatPowerSettingValue` と 1:1 で一致させる:
/// - `ac_dc_power_source`: `ac` / `battery` / `short_term`
/// - `console_display_state` / `session_display_status`: `off` / `on` / `dimmed`
/// - `global_user_presence`: `present` / `inactive`
/// - `lid_switch_state` / `monitor_power_on` / `power_saving_status`: `off` / `on`
/// - `battery_percentage_remaining`: 10 進整数 (不明時は `unknown`)
public enum PowerSettingValues {
    public static let acDcPowerSource = "ac_dc_power_source"
    public static let batteryPercentageRemaining = "battery_percentage_remaining"
    public static let consoleDisplayState = "console_display_state"
    public static let sessionDisplayStatus = "session_display_status"
    public static let monitorPowerOn = "monitor_power_on"
    public static let lidSwitchState = "lid_switch_state"
    public static let powerSavingStatus = "power_saving_status"
    public static let globalUserPresence = "global_user_presence"

    /// `IOPSGetProvidingPowerSourceType` の生文字列を Windows の語彙へ写像する。
    /// UPS は Windows の `short_term` (= 2) に対応させる (設計書 §3.3)。
    public static func powerSource(providingType: String) -> String {
        switch providingType {
        case "AC Power": return "ac"
        case "Battery Power": return "battery"
        case "UPS Power": return "short_term"
        default: return "unknown"
        }
    }

    public static func batteryPercentage(_ percent: Int?) -> String {
        percent.map(String.init) ?? "unknown"
    }

    /// ディスプレイのスリープ状態。`NSWorkspace.screensDidSleep` → off、`screensDidWake` → on。
    /// Windows の `console_display_state` / `session_display_status` / `monitor_power_on` は
    /// macOS では同じ 1 つのソースから導出するため、3 つとも同値になる。
    public static func displayState(asleep: Bool) -> String {
        asleep ? "off" : "on"
    }

    /// クラムシェル (ふた) の状態。
    ///
    /// **写像の根拠**: Windows の `GUID_LIDSWITCH_STATE_CHANGE` は 0 = ふた閉、1 = ふた開で、
    /// `WindowsPowerSettingReader` はそれを `0 → "off"` / それ以外 `→ "on"` に整形する。
    /// つまり Windows 側の `"on"` は**ふたが開いている**ことを意味する。
    /// IORegistry の `AppleClamshellState` は true = **閉**なので、反転して写像する。
    public static func lidSwitchState(clamshellClosed: Bool) -> String {
        clamshellClosed ? "off" : "on"
    }

    /// 低電力モード。Windows の `power_saving_status` は 0 → off / 1 → on。
    public static func powerSavingStatus(lowPowerModeEnabled: Bool) -> String {
        lowPowerModeEnabled ? "on" : "off"
    }

    /// アイドル秒数から `present` / `inactive` を導出する。
    /// しきい値は presence bucket と同一 (`active` のときだけ present)。
    public static func globalUserPresence(idleSeconds: Int?) -> String {
        AmbientTier1Rules.getPresenceBucket(idleSeconds) == "active" ? "present" : "inactive"
    }
}
