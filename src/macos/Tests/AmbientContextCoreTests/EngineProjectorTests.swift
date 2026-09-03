import Foundation
import Testing
@testable import AmbientContextCore

@Suite("EngineProjector")
struct EngineProjectorTests {
    private func state(_ states: [AmbientState], _ name: String) -> AmbientState? {
        states.first { $0.name == name }
    }

    @Test("BuildStates_formats_values_like_csharp")
    func buildStates() throws {
        let observedAt = EngineTestClock.base
        let states = AmbientContextProjector.buildStates(
            observedAt: observedAt,
            presence: PresenceContext(idleSeconds: 12, bucket: "idle", sessionLocked: true),
            foreground: ForegroundAppContext(
                processName: "Code",
                appName: "Visual Studio Code",
                category: "editor",
                hasWindowTitle: true,
                rawWindowTitle: "a.swift",
                titleSummary: CaseInsensitiveDictionary([("has_title", "true"), ("file_ext", "swift")])),
            battery: BatteryContext(present: true, percent: 42, charging: false, bucket: "medium"),
            network: NetworkContext(isAvailable: true),
            media: MediaContext(
                isAvailable: true, sourceAppUserModelId: "com.spotify.client",
                playbackStatus: "Playing", title: "T", artist: "A", albumTitle: "Al"),
            power: PowerContext(lastKnownSettings: CaseInsensitiveDictionary([("ac_dc_power_source", "ac")])),
            system: SystemContext(timeZoneId: "Asia/Tokyo", uptimeSeconds: 12345),
            systemLoad: SystemLoadContext(cpuPressureBucket: "low", memoryPressureBucket: "moderate"),
            activity: ActivityContext(contextSwitchesPerMin: 3),
            wellness: WellnessContext(continuousActiveMinutes: 25, minutesSinceLastBreak: 25),
            displays: [DisplayContext(
                deviceName: "Built-in", primary: true, left: 0, top: 0, width: 1920, height: 1080)])

        // 先頭 21 件の順序 (C# の初期化リストと同じ)。
        #expect(states.prefix(21).map(\.name) == [
            "presence.bucket", "presence.idleSeconds", "presence.sessionLocked",
            "foregroundApp.category", "foregroundApp.appName", "foregroundApp.processName",
            "battery.bucket", "battery.percent", "battery.charging",
            "network.isAvailable",
            "media.isAvailable", "media.playbackStatus", "media.sourceAppUserModelId",
            "system.timeZoneId", "system.uptimeSeconds",
            "system.cpuPressureBucket", "system.memoryPressureBucket",
            "wellness.continuousActiveMinutes", "wellness.minutesSinceLastBreak",
            "activity.contextSwitchesPerMin", "display.count"
        ])

        #expect(try #require(state(states, "presence.idleSeconds")).value == "12")
        #expect(try #require(state(states, "presence.sessionLocked")).value == "true")
        #expect(try #require(state(states, "presence.sessionLocked")).sensitivity == "medium")
        #expect(try #require(state(states, "battery.charging")).value == "false")
        #expect(try #require(state(states, "network.isAvailable")).sensitivity == "low")
        #expect(try #require(state(states, "system.uptimeSeconds")).value == "12345")
        #expect(try #require(state(states, "display.count")).value == "1")
        #expect(try #require(state(states, "foregroundApp.titleSummary.file_ext")).value == "swift")
        #expect(try #require(state(states, "foregroundApp.rawWindowTitle")).sensitivity == "high")
        #expect(try #require(state(states, "media.title")).sensitivity == "high")
        #expect(try #require(state(states, "displays.0.width")).value == "1920")
        #expect(try #require(state(states, "displays.0.primary")).value == "true")
        #expect(try #require(state(states, "power.lastKnownSettings.ac_dc_power_source")).value == "ac")
        #expect(states.allSatisfy { $0.observedAt == observedAt })
    }

    @Test("BuildStates_uses_unknown_for_missing_numbers")
    func buildStatesUnknown() throws {
        let states = AmbientContextProjector.buildStates(
            observedAt: EngineTestClock.base,
            presence: PresenceContext(),
            foreground: ForegroundAppContext(),
            battery: BatteryContext(),
            network: NetworkContext(),
            media: MediaContext(),
            power: PowerContext(),
            system: SystemContext(),
            systemLoad: SystemLoadContext(),
            activity: ActivityContext(),
            wellness: WellnessContext(),
            displays: [])

        #expect(try #require(state(states, "presence.idleSeconds")).value == "unknown")
        #expect(try #require(state(states, "battery.percent")).value == "unknown")
        #expect(try #require(state(states, "battery.charging")).value == "unknown")
        // 空文字の高機微 state は出さない。
        #expect(state(states, "foregroundApp.rawWindowTitle") == nil)
        #expect(state(states, "media.title") == nil)
        #expect(state(states, "displays.0.deviceName") == nil)
    }

    @Test("BuildEvents_skips_initialization_only_and_maps_value")
    func buildEventsMapping() throws {
        let base = EngineTestClock.base
        let events = AmbientContextProjector.buildEvents([
            AmbientEvent(observedAt: base, kind: "power_settings_initialized", initializationOnly: true),
            AmbientEvent(
                observedAt: base, kind: "presence_bucket_changed",
                data: CaseInsensitiveDictionary([("from", "active"), ("to", "idle")])),
            AmbientEvent(
                observedAt: base.addingTimeInterval(10), kind: "power_setting_changed",
                data: CaseInsensitiveDictionary([("setting", "lid_switch_state"), ("value", "open")])),
            AmbientEvent(observedAt: base.addingTimeInterval(20), kind: "first_activity_today")
        ])

        #expect(events.map(\.name) == [
            "presence_bucket_changed", "power_setting_changed", "first_activity_today"
        ])
        // value は data["to"] → data["value"] → "true" の順。
        #expect(events[0].value == "idle")
        #expect(events[1].value == "open")
        #expect(events[2].value == "true")
        #expect(events[0].payload["from"] == "active")
    }

    @Test("BuildEvents_suppresses_lower_level_event_within_2_seconds")
    func buildEventsDeduplication() {
        let base = EngineTestClock.base

        // power_source_changed と 2 秒以内 → power_setting_changed は落ちる。
        let suppressed = AmbientContextProjector.buildEvents([
            AmbientEvent(
                observedAt: base, kind: "power_setting_changed",
                data: CaseInsensitiveDictionary([("setting", "ac_dc_power_source"), ("value", "battery")])),
            AmbientEvent(
                observedAt: base.addingTimeInterval(1.5), kind: "power_source_changed",
                data: CaseInsensitiveDictionary([("from", "ac"), ("to", "battery")])),
            AmbientEvent(
                observedAt: base.addingTimeInterval(1.5), kind: "battery_power_active",
                data: CaseInsensitiveDictionary([("from", "ac"), ("to", "battery")]))
        ])
        // power_source_changed 自身も battery_power_active に抑制される。
        #expect(suppressed.map(\.name) == ["battery_power_active"])

        // 2 秒を超えると抑制されない。
        let kept = AmbientContextProjector.buildEvents([
            AmbientEvent(
                observedAt: base, kind: "power_setting_changed",
                data: CaseInsensitiveDictionary([("setting", "ac_dc_power_source"), ("value", "battery")])),
            AmbientEvent(
                observedAt: base.addingTimeInterval(2.5), kind: "power_source_changed",
                data: CaseInsensitiveDictionary([("from", "ac"), ("to", "battery")]))
        ])
        #expect(kept.map(\.name) == ["power_setting_changed", "power_source_changed"])

        // presence_bucket_changed は user_became_idle に抑制される。
        let presence = AmbientContextProjector.buildEvents([
            AmbientEvent(observedAt: base, kind: "presence_bucket_changed"),
            AmbientEvent(observedAt: base, kind: "user_became_idle")
        ])
        #expect(presence.map(\.name) == ["user_became_idle"])
    }

    @Test("BuildEvents_takes_last_10")
    func buildEventsTakeLast() {
        let base = EngineTestClock.base
        let source = (0..<12).map { index in
            AmbientEvent(
                observedAt: base.addingTimeInterval(Double(index) * 60),
                kind: "session_logon",
                data: CaseInsensitiveDictionary([("value", String(index))]))
        }

        let events = AmbientContextProjector.buildEvents(source)
        #expect(events.count == 10)
        #expect(events.first?.value == "2")
        #expect(events.last?.value == "11")
    }
}
