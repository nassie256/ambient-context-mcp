import Foundation
import Testing
@testable import AmbientContextCore

@Suite("EngineEventCatalog")
struct EngineEventCatalogTests {
    /// MAINTENANCE: `TransitionEvaluator` が `addEvent` する非 `initializationOnly` イベント名の
    /// 全リスト。C# 側の `AmbientContextCatalog.EventSchemas.cs` 冒頭のコメントに対応する
    /// drift 検出をここで機械化する。イベントを追加したらこの配列と
    /// `AmbientContextCatalog+EventSchemas.swift` の両方を更新すること。
    static let emittedEventNames: Set<String> = [
        // presence / wellness
        "presence_bucket_changed", "user_returned", "user_became_idle",
        "first_activity_today", "long_session_warning",
        // foreground / activity
        "foreground_changed", "foreground_title_changed", "context_switch_burst",
        // battery / power
        "battery_percent_crossed_threshold", "battery_medium", "battery_low", "battery_critical",
        "charger_connected", "charger_disconnected",
        "power_setting_changed", "power_source_changed",
        "ac_power_connected", "battery_power_active", "short_term_power_active",
        // media
        "media_playback_started", "media_playback_paused", "media_playback_stopped",
        "media_playback_status_changed", "media_session_changed",
        // network / system / display
        "network_connectivity_changed", "timezone_changed", "system_under_load",
        "display_count_changed",
        "session_locked", "session_unlocked", "session_logon", "session_logoff",
        "system_suspend", "system_resume_user", "system_resume_automatic"
    ]

    /// カタログに載せない (= 送信対象外) の初期化専用イベント。
    static let initializationOnlyEventNames: Set<String> = [
        "ambient_monitor_attached", "power_settings_initialized"
    ]

    private var catalogNames: Set<String> {
        Set(AmbientContextCatalog.getEventSchemas(language: "en").map(\.name))
    }

    @Test("Emitted_event_names_exist_in_catalog")
    func emittedNamesAreCatalogued() {
        let missing = EngineEventCatalogTests.emittedEventNames.subtracting(catalogNames)
        #expect(missing.isEmpty, "catalog に無いイベント名: \(missing.sorted())")
    }

    @Test("Catalog_has_no_event_without_an_emitter")
    func catalogHasNoOrphans() {
        let orphans = catalogNames.subtracting(EngineEventCatalogTests.emittedEventNames)
        #expect(orphans.isEmpty, "発火元の無い catalog イベント: \(orphans.sorted())")
    }

    @Test("Initialization_only_events_are_intentionally_absent_from_catalog")
    func initializationOnlyEventsAreNotCatalogued() {
        #expect(catalogNames.isDisjoint(with: EngineEventCatalogTests.initializationOnlyEventNames))
    }

    @Test("Events_actually_emitted_by_the_evaluator_are_catalogued")
    func emittedByEvaluatorAreCatalogued() {
        let clock = ManualClock(EngineTestClock.base)
        var configuration = TransitionEvaluator.Configuration()
        configuration.expectedInitialPowerSettingCount = 1
        let evaluator = makeEvaluator(clock: clock, configuration: configuration, lastActivityDate: nil)

        evaluator.recordMonitorsAttached([("session", "registered")])
        evaluator.recordSessionChange(.locked)
        evaluator.recordSessionChange(.unlocked)
        evaluator.recordSessionChange(.logon)
        evaluator.recordSessionChange(.logoff)
        evaluator.recordPowerBroadcast(.suspend)
        evaluator.recordPowerBroadcast(.resumeUser)
        evaluator.recordPowerBroadcast(.resumeAutomatic)
        evaluator.recordPowerSetting(name: "ac_dc_power_source", value: "ac")
        evaluator.recordPowerSetting(name: "ac_dc_power_source", value: "battery")
        evaluator.recordPowerSetting(name: "ac_dc_power_source", value: "short_term")

        var inputs = EngineInputs()
        evaluator.evaluate(inputs, at: clock.current)

        clock.advance(60)
        inputs.presence = PresenceContext(idleSeconds: 30, bucket: "idle")
        inputs.foreground = ForegroundAppContext(
            processName: "Safari", appName: "Safari", category: "browser",
            rawWindowTitle: "GitHub",
            titleSummary: CaseInsensitiveDictionary([("has_title", "true")]))
        inputs.battery = BatteryContext(present: true, percent: 15, charging: true, bucket: "charging")
        inputs.network = NetworkContext(isAvailable: false)
        inputs.media = MediaContext(
            isAvailable: true, sourceAppUserModelId: "com.spotify.client", playbackStatus: "Playing")
        inputs.system = SystemContext(timeZoneId: "UTC")
        inputs.systemLoad = SystemLoadContext(cpuPressureBucket: "critical", memoryPressureBucket: "low")
        inputs.activity = ActivityContext(contextSwitchesPerMin: 20)
        inputs.wellness = WellnessContext(continuousActiveMinutes: 120, minutesSinceLastBreak: 120)
        inputs.displays = []
        evaluator.evaluate(inputs, at: clock.current)

        clock.advance(60)
        inputs.presence = PresenceContext(idleSeconds: 0, bucket: "active")
        inputs.battery = BatteryContext(present: true, percent: 5, charging: false, bucket: "critical")
        inputs.media.playbackStatus = "Paused"
        evaluator.evaluate(inputs, at: clock.current)

        clock.advance(60)
        inputs.media.playbackStatus = "Stopped"
        evaluator.evaluate(inputs, at: clock.current)
        clock.advance(60)
        inputs.media.playbackStatus = "Buffering"
        evaluator.evaluate(inputs, at: clock.current)
        clock.advance(60)
        inputs.battery = BatteryContext(present: true, percent: 25, charging: false, bucket: "medium")
        evaluator.evaluate(inputs, at: clock.current)

        let emitted = evaluator.recentEvents()
        let outbound = Set(emitted.filter { !$0.initializationOnly }.map(\.kind))
        #expect(outbound.subtracting(catalogNames).isEmpty)
        #expect(outbound.isSubset(of: EngineEventCatalogTests.emittedEventNames))

        let initializationOnly = Set(emitted.filter(\.initializationOnly).map(\.kind))
        #expect(initializationOnly == EngineEventCatalogTests.initializationOnlyEventNames)
    }
}
