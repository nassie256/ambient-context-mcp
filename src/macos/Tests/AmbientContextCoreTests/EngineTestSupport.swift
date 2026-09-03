import Foundation
@testable import AmbientContextCore

/// テストから時刻を進められる時計。`TransitionEvaluator` は自身でロックを持たないので
/// テストも単一スレッドから使う。
final class ManualClock: @unchecked Sendable {
    private(set) var current: Date

    init(_ start: Date) {
        current = start
    }

    func advance(_ seconds: TimeInterval) {
        current = current.addingTimeInterval(seconds)
    }

    var provider: () -> Date {
        { [self] in current }
    }
}

/// `persistLastActivityDate` クロージャの呼び出しを記録する。
final class RecordedActivityDates: @unchecked Sendable {
    private(set) var dates: [DateOnly] = []

    func record(_ date: DateOnly) {
        dates.append(date)
    }
}

/// `evaluate` に渡す 11 個の Context の既定値。テストは必要な項目だけ差し替える。
struct EngineInputs {
    var presence = PresenceContext(idleSeconds: 0, bucket: "active")
    var foreground = ForegroundAppContext()
    var battery = BatteryContext()
    var network = NetworkContext(isAvailable: true)
    var media = MediaContext()
    var power = PowerContext()
    var system = SystemContext(timeZoneId: "Asia/Tokyo")
    var systemLoad = SystemLoadContext(cpuPressureBucket: "low", memoryPressureBucket: "low")
    var activity = ActivityContext()
    var wellness = WellnessContext()
    var displays: [DisplayContext] = [DisplayContext(deviceName: "Built-in", primary: true)]
}

extension TransitionEvaluator {
    func evaluate(_ inputs: EngineInputs, at observedAt: Date) {
        evaluate(
            observedAt: observedAt,
            presence: inputs.presence,
            foreground: inputs.foreground,
            battery: inputs.battery,
            network: inputs.network,
            media: inputs.media,
            power: inputs.power,
            system: inputs.system,
            systemLoad: inputs.systemLoad,
            activity: inputs.activity,
            wellness: inputs.wellness,
            displays: inputs.displays)
    }

    /// 直近評価で追加されたイベント名 (`initializationOnly` を含む) を返すためのヘルパ。
    func eventKinds() -> [String] {
        recentEvents().map(\.kind)
    }

    func events(named name: String) -> [AmbientEvent] {
        recentEvents().filter { $0.kind == name }
    }
}

enum EngineTestClock {
    /// 固定の基準時刻 (ローカル 2026-05-04 10:00:00)。
    static let base: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 4
        components.hour = 10
        return Calendar.current.date(from: components)!
    }()

    static var baseDay: DateOnly { DateOnly(localDate: base) }
}

/// 既定では `first_activity_today` が毎テストの初回 evaluate で発火してノイズになるため、
/// 基準日を「発火済み」として渡す。日付遷移そのものを見るテストだけ nil を渡す。
func makeEvaluator(
    clock: ManualClock,
    configuration: TransitionEvaluator.Configuration = .init(),
    lastActivityDate: DateOnly? = EngineTestClock.baseDay,
    persist: RecordedActivityDates = RecordedActivityDates()
) -> TransitionEvaluator {
    TransitionEvaluator(
        configuration: configuration,
        lastActivityDate: lastActivityDate,
        now: clock.provider,
        persistLastActivityDate: { persist.record($0) })
}
