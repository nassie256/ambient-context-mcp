import Foundation
import Testing
@testable import AmbientContextCore

@Suite("EngineTransitionEvaluator")
struct EngineTransitionEvaluatorTests {
    // MARK: - presence

    @Test("First_evaluation_emits_no_transition_events")
    func firstEvaluationIsSilent() {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        evaluator.evaluate(EngineInputs(), at: clock.current)

        #expect(evaluator.recentEvents().isEmpty)
    }

    @Test("Presence_active_to_idle_emits_bucket_changed_and_user_became_idle")
    func presenceActiveToIdle() throws {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        var inputs = EngineInputs()
        evaluator.evaluate(inputs, at: clock.current)

        clock.advance(60)
        inputs.presence = PresenceContext(idleSeconds: 30, bucket: "idle")
        evaluator.evaluate(inputs, at: clock.current)

        #expect(evaluator.eventKinds() == ["presence_bucket_changed", "user_became_idle"])
        let bucketChanged = try #require(evaluator.events(named: "presence_bucket_changed").first)
        #expect(bucketChanged.data["from"] == "active")
        #expect(bucketChanged.data["to"] == "idle")
        #expect(bucketChanged.sensitivity == "low")
    }

    @Test("Presence_idle_to_active_emits_user_returned")
    func presenceIdleToActive() {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        var inputs = EngineInputs()
        inputs.presence = PresenceContext(idleSeconds: 30, bucket: "idle")
        evaluator.evaluate(inputs, at: clock.current)

        clock.advance(60)
        inputs.presence = PresenceContext(idleSeconds: 0, bucket: "active")
        evaluator.evaluate(inputs, at: clock.current)

        #expect(evaluator.eventKinds() == ["presence_bucket_changed", "user_returned"])
    }

    @Test("Presence_away_long_to_away_short_emits_only_bucket_changed")
    func presenceAwayTransition() {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        var inputs = EngineInputs()
        inputs.presence = PresenceContext(idleSeconds: 700, bucket: "away_long")
        evaluator.evaluate(inputs, at: clock.current)

        clock.advance(60)
        inputs.presence = PresenceContext(idleSeconds: 200, bucket: "away_short")
        evaluator.evaluate(inputs, at: clock.current)

        #expect(evaluator.eventKinds() == ["presence_bucket_changed"])
    }

    // MARK: - foreground

    @Test("Foreground_changed_only_on_process_or_category_change")
    func foregroundChanged() throws {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        var inputs = EngineInputs()
        inputs.foreground = ForegroundAppContext(
            processName: "Code", appName: "Visual Studio Code", category: "editor")
        evaluator.evaluate(inputs, at: clock.current)

        // 同一プロセス・同一カテゴリなら発火しない。
        clock.advance(60)
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "foreground_changed").isEmpty)

        // カテゴリも変わるケース。
        clock.advance(60)
        inputs.foreground = ForegroundAppContext(
            processName: "Safari", appName: "Safari", category: "browser")
        evaluator.evaluate(inputs, at: clock.current)

        let first = try #require(evaluator.events(named: "foreground_changed").first)
        #expect(first.sensitivity == "medium")
        #expect(first.data["category"] == "browser")
        #expect(first.data["app_name"] == "Safari")
        #expect(first.data["process_name"] == "Safari")
        #expect(first.data["category_changed"] == "true")

        // 同一カテゴリ内でのプロセス変更は category_changed=false。
        clock.advance(60)
        inputs.foreground = ForegroundAppContext(
            processName: "Google Chrome", appName: "Chrome", category: "browser")
        evaluator.evaluate(inputs, at: clock.current)

        let events = evaluator.events(named: "foreground_changed")
        #expect(events.count == 2)
        #expect(events[1].data["category_changed"] == "false")
    }

    @Test("Foreground_title_changed_carries_title_summary_keys")
    func foregroundTitleChanged() throws {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        var inputs = EngineInputs()
        inputs.foreground = ForegroundAppContext(
            processName: "Code",
            appName: "Visual Studio Code",
            category: "editor",
            hasWindowTitle: true,
            rawWindowTitle: "a.swift — proj",
            titleSummary: AmbientTier1Rules.summarizeWindowTitle(
                category: "editor", title: "a.swift — proj", rules: .macOS))
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "foreground_title_changed").isEmpty)

        // 同じタイトルなら発火しない。
        clock.advance(60)
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "foreground_title_changed").isEmpty)

        clock.advance(60)
        inputs.foreground.rawWindowTitle = "b.md — proj"
        inputs.foreground.titleSummary = AmbientTier1Rules.summarizeWindowTitle(
            category: "editor", title: "b.md — proj", rules: .macOS)
        evaluator.evaluate(inputs, at: clock.current)

        let event = try #require(evaluator.events(named: "foreground_title_changed").first)
        #expect(event.sensitivity == "medium")
        #expect(event.data["raw_window_title"] == "b.md — proj")
        #expect(event.data["titleSummary.has_title"] == "true")
        #expect(event.data["titleSummary.file_ext"] == "md")
        // process / category が変わっていないので foreground_changed は出ない。
        #expect(evaluator.events(named: "foreground_changed").isEmpty)
    }

    @Test("Foreground_title_changed_fires_when_only_summary_changes")
    func foregroundTitleSummaryOnly() {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        var inputs = EngineInputs()
        inputs.foreground = ForegroundAppContext(processName: "Code", category: "editor")
        evaluator.evaluate(inputs, at: clock.current)

        clock.advance(60)
        inputs.foreground.titleSummary = CaseInsensitiveDictionary([("has_title", "true")])
        evaluator.evaluate(inputs, at: clock.current)

        #expect(evaluator.events(named: "foreground_title_changed").count == 1)
    }

    // MARK: - battery

    @Test("Battery_threshold_crossings_both_directions")
    func batteryThresholds() throws {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        var inputs = EngineInputs()
        inputs.battery = BatteryContext(present: true, percent: 55, charging: false, bucket: "ok")
        evaluator.evaluate(inputs, at: clock.current)

        clock.advance(60)
        inputs.battery = BatteryContext(present: true, percent: 45, charging: false, bucket: "medium")
        evaluator.evaluate(inputs, at: clock.current)

        let down = try #require(evaluator.events(named: "battery_percent_crossed_threshold").first)
        #expect(down.data["threshold"] == "50")
        #expect(down.data["direction"] == "down")
        #expect(down.data["from"] == "55")
        #expect(down.data["to"] == "45")
        #expect(evaluator.events(named: "battery_medium").count == 1)

        clock.advance(60)
        inputs.battery = BatteryContext(present: true, percent: 60, charging: false, bucket: "ok")
        evaluator.evaluate(inputs, at: clock.current)

        let crossings = evaluator.events(named: "battery_percent_crossed_threshold")
        #expect(crossings.count == 2)
        #expect(crossings[1].data["direction"] == "up")
        #expect(crossings[1].data["threshold"] == "50")
    }

    @Test("Battery_low_and_critical_and_charger_events")
    func batteryLowCriticalCharger() {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        var inputs = EngineInputs()
        inputs.battery = BatteryContext(present: true, percent: 25, charging: false, bucket: "medium")
        evaluator.evaluate(inputs, at: clock.current)
        // 初回は _lastCharging が nil なので charger イベントは出ない。
        #expect(evaluator.events(named: "charger_disconnected").isEmpty)

        clock.advance(60)
        inputs.battery = BatteryContext(present: true, percent: 15, charging: false, bucket: "low")
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "battery_low").count == 1)

        clock.advance(60)
        inputs.battery = BatteryContext(present: true, percent: 5, charging: false, bucket: "critical")
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "battery_critical").count == 1)

        clock.advance(60)
        inputs.battery = BatteryContext(present: true, percent: 5, charging: true, bucket: "charging")
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "charger_connected").count == 1)
        // "charging" は battery_* イベントの対象外。
        #expect(evaluator.events(named: "battery_charging").isEmpty)

        clock.advance(60)
        inputs.battery = BatteryContext(present: true, percent: 5, charging: false, bucket: "critical")
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "charger_disconnected").count == 1)
        #expect(evaluator.events(named: "battery_critical").count == 2)
    }

    // MARK: - media

    @Test("Media_playback_status_events")
    func mediaPlaybackEvents() throws {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        var inputs = EngineInputs()
        inputs.media = MediaContext(
            isAvailable: true, sourceAppUserModelId: "com.spotify.client",
            playbackStatus: "Paused", title: "T", artist: "A", albumTitle: "Al")
        evaluator.evaluate(inputs, at: clock.current)

        let firstSession = try #require(evaluator.events(named: "media_session_changed").first)
        #expect(firstSession.sensitivity == "medium")
        #expect(firstSession.data["source_app"] == "com.spotify.client")
        #expect(firstSession.data["source_kind"] == "music")
        #expect(firstSession.data["playback_status"] == "Paused")
        #expect(firstSession.data["title"] == "T")
        #expect(firstSession.data["artist"] == "A")
        #expect(firstSession.data["album_title"] == "Al")

        clock.advance(60)
        inputs.media.playbackStatus = "Playing"
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "media_playback_started").count == 1)

        clock.advance(60)
        inputs.media.playbackStatus = "Stopped"
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "media_playback_stopped").count == 1)

        clock.advance(60)
        inputs.media.playbackStatus = "Paused"
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "media_playback_paused").count == 1)

        clock.advance(60)
        inputs.media.playbackStatus = "Changing"
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "media_playback_status_changed").count == 1)
    }

    @Test("Media_session_changed_not_emitted_when_unavailable")
    func mediaUnavailable() {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        var inputs = EngineInputs()
        inputs.media = MediaContext(isAvailable: false, playbackStatus: "unknown")
        evaluator.evaluate(inputs, at: clock.current)
        clock.advance(60)
        evaluator.evaluate(inputs, at: clock.current)

        #expect(evaluator.events(named: "media_session_changed").isEmpty)
    }

    // MARK: - network / system / display

    @Test("Network_timezone_and_display_count_transitions")
    func miscTransitions() throws {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        var inputs = EngineInputs()
        evaluator.evaluate(inputs, at: clock.current)

        clock.advance(60)
        inputs.network = NetworkContext(isAvailable: false)
        inputs.system = SystemContext(timeZoneId: "America/Los_Angeles")
        inputs.displays = []
        evaluator.evaluate(inputs, at: clock.current)

        let network = try #require(evaluator.events(named: "network_connectivity_changed").first)
        #expect(network.data["from"] == "online")
        #expect(network.data["to"] == "offline")

        let timezone = try #require(evaluator.events(named: "timezone_changed").first)
        #expect(timezone.sensitivity == "medium")
        #expect(timezone.data["from"] == "Asia/Tokyo")
        #expect(timezone.data["to"] == "America/Los_Angeles")

        let display = try #require(evaluator.events(named: "display_count_changed").first)
        #expect(display.sensitivity == "medium")
        #expect(display.data["from"] == "1")
        #expect(display.data["to"] == "0")
    }

    @Test("System_under_load_fires_on_rising_edge_only")
    func systemUnderLoad() throws {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        var inputs = EngineInputs()
        evaluator.evaluate(inputs, at: clock.current)

        clock.advance(60)
        inputs.systemLoad = SystemLoadContext(cpuPressureBucket: "high", memoryPressureBucket: "low")
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "system_under_load").count == 1)

        // 継続中は再発火しない。
        clock.advance(60)
        inputs.systemLoad = SystemLoadContext(cpuPressureBucket: "critical", memoryPressureBucket: "low")
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "system_under_load").count == 1)

        // 一度下がってから上がると再発火する。
        clock.advance(60)
        inputs.systemLoad = SystemLoadContext(cpuPressureBucket: "moderate", memoryPressureBucket: "low")
        evaluator.evaluate(inputs, at: clock.current)
        clock.advance(60)
        inputs.systemLoad = SystemLoadContext(cpuPressureBucket: "low", memoryPressureBucket: "high")
        evaluator.evaluate(inputs, at: clock.current)

        let events = evaluator.events(named: "system_under_load")
        #expect(events.count == 2)
        #expect(events[1].data["cpu_pressure"] == "low")
        #expect(events[1].data["memory_pressure"] == "high")
    }

    // MARK: - activity / wellness

    @Test("Context_switch_burst_uses_12_8_hysteresis")
    func contextSwitchBurst() throws {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        var inputs = EngineInputs()
        inputs.activity = ActivityContext(contextSwitchesPerMin: 11)
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "context_switch_burst").isEmpty)

        clock.advance(60)
        inputs.activity = ActivityContext(contextSwitchesPerMin: 12)
        evaluator.evaluate(inputs, at: clock.current)
        let burst = try #require(evaluator.events(named: "context_switch_burst").first)
        #expect(burst.sensitivity == "medium")
        #expect(burst.data["switches_per_min"] == "12")

        // 8 以上のあいだは active のままなので再発火しない。
        clock.advance(60)
        inputs.activity = ActivityContext(contextSwitchesPerMin: 20)
        evaluator.evaluate(inputs, at: clock.current)
        clock.advance(60)
        inputs.activity = ActivityContext(contextSwitchesPerMin: 8)
        evaluator.evaluate(inputs, at: clock.current)
        clock.advance(60)
        inputs.activity = ActivityContext(contextSwitchesPerMin: 15)
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "context_switch_burst").count == 1)

        // 8 未満まで落ちるとリセットされ、再び 12 で発火する。
        clock.advance(60)
        inputs.activity = ActivityContext(contextSwitchesPerMin: 7)
        evaluator.evaluate(inputs, at: clock.current)
        clock.advance(60)
        inputs.activity = ActivityContext(contextSwitchesPerMin: 12)
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "context_switch_burst").count == 2)
    }

    @Test("Long_session_warning_at_90_minutes_and_resets_after_break")
    func longSessionWarning() throws {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        var inputs = EngineInputs()
        inputs.wellness = WellnessContext(continuousActiveMinutes: 89, minutesSinceLastBreak: 89)
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "long_session_warning").isEmpty)

        clock.advance(60)
        inputs.wellness = WellnessContext(continuousActiveMinutes: 90, minutesSinceLastBreak: 90)
        evaluator.evaluate(inputs, at: clock.current)
        let warning = try #require(evaluator.events(named: "long_session_warning").first)
        #expect(warning.data["continuous_active_minutes"] == "90")

        // 継続中は再発火しない。
        clock.advance(60)
        inputs.wellness = WellnessContext(continuousActiveMinutes: 120, minutesSinceLastBreak: 120)
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "long_session_warning").count == 1)

        // 休憩でリセットされ、再度 90 分で発火する。
        clock.advance(60)
        inputs.presence = PresenceContext(idleSeconds: 700, bucket: "away_long")
        inputs.wellness = WellnessContext()
        evaluator.evaluate(inputs, at: clock.current)
        clock.advance(60)
        inputs.presence = PresenceContext(idleSeconds: 0, bucket: "active")
        inputs.wellness = WellnessContext(continuousActiveMinutes: 95, minutesSinceLastBreak: 95)
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "long_session_warning").count == 2)
    }

    @Test("Wellness_tracks_continuous_active_and_break")
    func wellnessComputation() {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)
        let active = PresenceContext(idleSeconds: 0, bucket: "active")
        let away = PresenceContext(idleSeconds: 700, bucket: "away_long")

        let first = evaluator.wellness(presence: active, at: EngineTestClock.base)
        #expect(first.continuousActiveMinutes == 0)
        #expect(first.minutesSinceLastBreak == 0)

        let later = evaluator.wellness(
            presence: active, at: EngineTestClock.base.addingTimeInterval(30 * 60 + 45))
        #expect(later.continuousActiveMinutes == 30)
        #expect(later.minutesSinceLastBreak == 30)

        let onBreak = evaluator.wellness(
            presence: away, at: EngineTestClock.base.addingTimeInterval(40 * 60))
        #expect(onBreak.continuousActiveMinutes == 0)
        #expect(onBreak.minutesSinceLastBreak == 0)

        let afterBreak = evaluator.wellness(
            presence: active, at: EngineTestClock.base.addingTimeInterval(60 * 60))
        #expect(afterBreak.continuousActiveMinutes == 0)
        #expect(afterBreak.minutesSinceLastBreak == 0)
    }

    @Test("First_activity_today_fires_once_per_day_and_persists")
    func firstActivityToday() {
        let clock = ManualClock(EngineTestClock.base)
        let persisted = RecordedActivityDates()
        let evaluator = makeEvaluator(clock: clock, lastActivityDate: nil, persist: persisted)

        let inputs = EngineInputs()
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "first_activity_today").count == 1)
        #expect(persisted.dates == [EngineTestClock.baseDay])
        #expect(evaluator.lastActivityDate == EngineTestClock.baseDay)

        // 同日中は再発火しない。
        clock.advance(3600)
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "first_activity_today").count == 1)
        #expect(persisted.dates.count == 1)

        // 翌日で再発火する (24 時間の保持窓から初日のイベントが落ちないよう 20 時間だけ進める)。
        let nextDay = EngineTestClock.base.addingTimeInterval(20 * 3600)
        clock.advance(19 * 3600)
        evaluator.evaluate(inputs, at: nextDay)
        #expect(evaluator.events(named: "first_activity_today").count == 2)
        #expect(persisted.dates.count == 2)
        #expect(persisted.dates[1] == DateOnly(localDate: nextDay))
    }

    @Test("First_activity_today_suppressed_while_on_break")
    func firstActivityDuringBreak() {
        let clock = ManualClock(EngineTestClock.base)
        let persisted = RecordedActivityDates()
        let evaluator = makeEvaluator(clock: clock, lastActivityDate: nil, persist: persisted)

        var inputs = EngineInputs()
        inputs.presence = PresenceContext(idleSeconds: 0, bucket: "locked")
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "first_activity_today").isEmpty)
        #expect(persisted.dates.isEmpty)

        clock.advance(60)
        inputs.presence = PresenceContext(idleSeconds: 0, bucket: "active")
        evaluator.evaluate(inputs, at: clock.current)
        #expect(evaluator.events(named: "first_activity_today").count == 1)
    }

    // MARK: - セッション / 電源通知

    @Test("Session_change_event_names_and_locked_flag")
    func sessionChanges() {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        #expect(evaluator.sessionLocked == false)
        evaluator.recordSessionChange(.locked)
        #expect(evaluator.sessionLocked)
        evaluator.recordSessionChange(.unlocked)
        #expect(evaluator.sessionLocked == false)
        evaluator.recordSessionChange(.logon)
        evaluator.recordSessionChange(.logoff)

        #expect(evaluator.eventKinds() == [
            "session_locked", "session_unlocked", "session_logon", "session_logoff"
        ])
    }

    @Test("Power_broadcast_event_names")
    func powerBroadcasts() {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)

        evaluator.recordPowerBroadcast(.suspend)
        evaluator.recordPowerBroadcast(.resumeUser)
        evaluator.recordPowerBroadcast(.resumeAutomatic)

        #expect(evaluator.eventKinds() == [
            "system_suspend", "system_resume_user", "system_resume_automatic"
        ])
    }

    @Test("Power_setting_initialization_phase_suppresses_events")
    func powerSettingInitialization() throws {
        let clock = ManualClock(EngineTestClock.base)
        var configuration = TransitionEvaluator.Configuration()
        configuration.expectedInitialPowerSettingCount = 3
        let evaluator = makeEvaluator(clock: clock, configuration: configuration)

        evaluator.recordPowerSetting(name: "ac_dc_power_source", value: "ac")
        evaluator.recordPowerSetting(name: "battery_percentage_remaining", value: "80")
        #expect(evaluator.recentEvents().isEmpty)
        #expect(evaluator.power().lastKnownSettings["ac_dc_power_source"] == "ac")

        // 期待件数に達した時点で initializationOnly の完了イベントだけが入る。
        evaluator.recordPowerSetting(name: "lid_switch_state", value: "open")
        let initialized = try #require(evaluator.events(named: "power_settings_initialized").first)
        #expect(initialized.initializationOnly)
        #expect(initialized.data["count"] == "3")
        #expect(evaluator.events(named: "power_setting_changed").isEmpty)

        // 初期化後は通常の変化イベントが出る。
        evaluator.recordPowerSetting(name: "lid_switch_state", value: "closed", extraPayload: [("guid", "g")])
        let changed = try #require(evaluator.events(named: "power_setting_changed").first)
        #expect(changed.data["setting"] == "lid_switch_state")
        #expect(changed.data["value"] == "closed")
        #expect(changed.data["guid"] == "g")
        #expect(evaluator.power().lastPowerSettingEvent?.kind == "power_setting_changed")
        #expect(evaluator.power().lastKnownSettings["lid_switch_state"] == "closed")
    }

    @Test("Power_source_transition_emits_power_source_changed_and_specific_event")
    func powerSourceTransitions() throws {
        let clock = ManualClock(EngineTestClock.base)
        var configuration = TransitionEvaluator.Configuration()
        configuration.expectedInitialPowerSettingCount = 1
        let evaluator = makeEvaluator(clock: clock, configuration: configuration)

        evaluator.recordPowerSetting(name: "ac_dc_power_source", value: "ac")
        #expect(evaluator.events(named: "power_source_changed").isEmpty)

        evaluator.recordPowerSetting(name: "ac_dc_power_source", value: "battery")
        let changed = try #require(evaluator.events(named: "power_source_changed").first)
        #expect(changed.data["from"] == "ac")
        #expect(changed.data["to"] == "battery")
        #expect(evaluator.events(named: "battery_power_active").count == 1)

        evaluator.recordPowerSetting(name: "ac_dc_power_source", value: "ac")
        #expect(evaluator.events(named: "ac_power_connected").count == 1)

        // 同じ値の再通知では遷移イベントを出さない。
        evaluator.recordPowerSetting(name: "ac_dc_power_source", value: "ac")
        #expect(evaluator.events(named: "power_source_changed").count == 2)

        evaluator.recordPowerSetting(name: "ac_dc_power_source", value: "short_term")
        #expect(evaluator.events(named: "short_term_power_active").count == 1)
    }

    @Test("Power_source_transition_from_unknown_uses_unknown_literal")
    func powerSourceFromUnknown() throws {
        let clock = ManualClock(EngineTestClock.base)
        var configuration = TransitionEvaluator.Configuration()
        configuration.expectedInitialPowerSettingCount = 1
        let evaluator = makeEvaluator(clock: clock, configuration: configuration)

        evaluator.recordPowerSetting(name: "power_saving_status", value: "off")
        evaluator.recordPowerSetting(name: "ac_dc_power_source", value: "battery")

        let changed = try #require(evaluator.events(named: "power_source_changed").first)
        #expect(changed.data["from"] == "unknown")
        #expect(changed.data["to"] == "battery")
    }

    // MARK: - foreground activation throttle / activity window

    @Test("Foreground_activation_is_throttled_and_counted_per_minute")
    func foregroundActivationThrottle() {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)
        let base = EngineTestClock.base

        #expect(evaluator.recordForegroundActivation(at: base))
        // 1000 ms 未満は捨てる。
        #expect(evaluator.recordForegroundActivation(at: base.addingTimeInterval(0.5)) == false)
        #expect(evaluator.recordForegroundActivation(at: base.addingTimeInterval(1.5)))

        #expect(evaluator.activity(at: base.addingTimeInterval(2)).contextSwitchesPerMin == 2)
        // 1 分より古い切り替えは窓から外れる。
        #expect(evaluator.activity(at: base.addingTimeInterval(61.4)).contextSwitchesPerMin == 1)
        #expect(evaluator.activity(at: base.addingTimeInterval(120)).contextSwitchesPerMin == 0)
    }

    // MARK: - イベント保持

    @Test("Recent_events_are_trimmed_by_count_and_retention")
    func recentEventTrimming() {
        let clock = ManualClock(EngineTestClock.base)
        var configuration = TransitionEvaluator.Configuration()
        configuration.maxRecentEvents = 3
        let evaluator = makeEvaluator(clock: clock, configuration: configuration)

        for _ in 0..<5 {
            evaluator.recordSessionChange(.logon)
            clock.advance(1)
        }
        #expect(evaluator.recentEvents().count == 3)

        // 24 時間より古いイベントは落ちる。
        clock.advance(24 * 3600 + 1)
        #expect(evaluator.recentEvents().isEmpty)
    }
}
