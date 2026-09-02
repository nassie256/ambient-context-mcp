import AppKit
import Foundation
import IOKit
import IOKit.ps

import AmbientContextCore

/// C# の `RegisterPowerSettingNotification` 8 GUID + `WindowsPowerSettingReader` に相当する
/// macOS 版 (設計書 §3.3 の `power.lastKnownSettings` 表)。
///
/// 設計上の違い:
/// - Windows は OS が個々の設定変更を push してくるが、macOS には等価な単一 API が無い。
///   そこで **「変化通知 → capture 要求」と「capture 時に全設定値を読み直して差分を取る」**
///   の 2 段構えにする。差分の検出とイベント発火は `TransitionEvaluator.recordPowerSetting`
///   が行うので、Windows と同じ `power_setting_changed` payload になる。
/// - `console_display_state` / `session_display_status` / `monitor_power_on` は
///   `NSWorkspace.screensDidSleep` / `screensDidWake` という単一ソースから導出するため常に同値。
public final class PowerSettingsMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var screensAsleep = false
    private var observers: [NSObjectProtocol] = []
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var changeHandler: (@Sendable () -> Void)?
    private var started = false

    public init() {}

    // MARK: - 監視

    /// メインスレッドで通知を購読する。`onChange` は「電源系の何かが変わった」ことだけを伝え、
    /// 具体的な差分は次の capture で `readAll` の結果から求める。
    @MainActor
    public func start(onChange: @escaping @Sendable () -> Void) {
        lock.lock()
        if started {
            lock.unlock()
            return
        }
        started = true
        changeHandler = onChange
        lock.unlock()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setScreensAsleep(true)
        })
        observers.append(workspaceCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.setScreensAsleep(false)
        })

        // 低電力モードの切り替え。
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notifyChanged()
        })

        // AC / バッテリの切り替えとバッテリ残量。IOKit のランループソースをメインに載せる。
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ pointer in
            guard let pointer else { return }
            let monitor = Unmanaged<PowerSettingsMonitor>.fromOpaque(pointer).takeUnretainedValue()
            monitor.notifyChanged()
        }, context)?.takeRetainedValue() {
            powerSourceRunLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        }
    }

    @MainActor
    public func stop() {
        lock.lock()
        started = false
        changeHandler = nil
        lock.unlock()

        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()

        if let source = powerSourceRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSourceRunLoopSource = nil
        }
    }

    /// 購読しているソースの数 = 初期化フェーズで観測できる setting 名の数。
    /// `TransitionEvaluator.Configuration.expectedInitialPowerSettingCount` に渡す。
    public var expectedInitialSettingCount: Int { settingNames.count }

    /// この環境で報告する setting 名。`lid_switch_state` はクラムシェルを持つ機種だけ。
    public var settingNames: [String] {
        var names = [
            PowerSettingValues.acDcPowerSource,
            PowerSettingValues.batteryPercentageRemaining,
            PowerSettingValues.consoleDisplayState,
            PowerSettingValues.sessionDisplayStatus,
            PowerSettingValues.monitorPowerOn,
            PowerSettingValues.powerSavingStatus,
            PowerSettingValues.globalUserPresence
        ]
        if Self.readClamshellClosed() != nil {
            names.append(PowerSettingValues.lidSwitchState)
        }
        return names
    }

    // MARK: - 読み出し

    /// 現在の全設定値を Windows 互換の (名前, 値) で返す。例外を投げず、読めない項目は
    /// `unknown` になる。actor / 任意スレッドから安全に呼べる。
    public func readAll(idleSeconds: Int?) -> [(String, String)] {
        let battery = BatteryCollector.readPowerSources()
        let displayValue = PowerSettingValues.displayState(asleep: isScreensAsleep())

        var readings: [(String, String)] = [
            (PowerSettingValues.acDcPowerSource,
             PowerSettingValues.powerSource(providingType: battery.providingPowerSourceType)),
            (PowerSettingValues.batteryPercentageRemaining,
             PowerSettingValues.batteryPercentage(battery.percent)),
            (PowerSettingValues.consoleDisplayState, displayValue),
            (PowerSettingValues.sessionDisplayStatus, displayValue),
            (PowerSettingValues.monitorPowerOn, displayValue),
            (PowerSettingValues.powerSavingStatus,
             PowerSettingValues.powerSavingStatus(
                lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled)),
            (PowerSettingValues.globalUserPresence,
             PowerSettingValues.globalUserPresence(idleSeconds: idleSeconds))
        ]

        if let closed = Self.readClamshellClosed() {
            readings.append((
                PowerSettingValues.lidSwitchState,
                PowerSettingValues.lidSwitchState(clamshellClosed: closed)))
        }

        return readings
    }

    /// IORegistry の `IOPMrootDomain` から `AppleClamshellState` を読む。
    /// クラムシェルを持たない機種 (Mac mini / Studio 等) では nil。
    public static func readClamshellClosed() -> Bool? {
        let entry = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPMrootDomain"))
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }

        guard let value = IORegistryEntryCreateCFProperty(
            entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool else {
            return nil
        }
        return value
    }

    // MARK: - 内部

    private func setScreensAsleep(_ asleep: Bool) {
        lock.lock()
        let changed = screensAsleep != asleep
        screensAsleep = asleep
        let handler = changeHandler
        lock.unlock()
        if changed {
            handler?()
        }
    }

    private func isScreensAsleep() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return screensAsleep
    }

    private func notifyChanged() {
        lock.lock()
        let handler = changeHandler
        lock.unlock()
        handler?()
    }
}
