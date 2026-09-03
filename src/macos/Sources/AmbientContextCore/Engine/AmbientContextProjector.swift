import Foundation

/// C# 版 `AmbientContextMcp.Desktop/AmbientContext/AmbientContextProjector.cs` の移植。
/// 収集済みの各 Context 値を `states` に、蓄積イベントを送信用 `events` に投影する。
public enum AmbientContextProjector {
    /// 同じ事象について低レベルイベントを抑制する時間窓。
    public static let outboundEventDeduplicationWindow: TimeInterval = 2

    /// 抑制対象イベント名 (小文字) → 「これが近傍にあれば抑制する」上位イベント名。
    private static let higherLevelEventsBySuppressedEvent: [String: [String]] = [
        "presence_bucket_changed": [
            "user_returned",
            "user_became_idle"
        ],
        "power_setting_changed": [
            "power_source_changed",
            "ac_power_connected",
            "battery_power_active",
            "short_term_power_active",
            "battery_percent_crossed_threshold",
            "battery_medium",
            "battery_low",
            "battery_critical"
        ],
        "power_source_changed": [
            "ac_power_connected",
            "battery_power_active",
            "short_term_power_active"
        ]
    ]

    public static func buildStates(
        observedAt: Date,
        presence: PresenceContext,
        foreground: ForegroundAppContext,
        battery: BatteryContext,
        network: NetworkContext,
        media: MediaContext,
        power: PowerContext,
        system: SystemContext,
        systemLoad: SystemLoadContext,
        activity: ActivityContext,
        wellness: WellnessContext,
        displays: [DisplayContext]
    ) -> [AmbientState] {
        var states: [AmbientState] = [
            state(observedAt, "presence.bucket", presence.bucket),
            state(observedAt, "presence.idleSeconds", presence.idleSeconds.map(String.init) ?? "unknown", "medium"),
            state(observedAt, "presence.sessionLocked", boolText(presence.sessionLocked), "medium"),
            state(observedAt, "foregroundApp.category", foreground.category, "medium"),
            state(observedAt, "foregroundApp.appName", foreground.appName, "medium"),
            state(observedAt, "foregroundApp.processName", foreground.processName, "medium"),
            state(observedAt, "battery.bucket", battery.bucket),
            state(observedAt, "battery.percent", battery.percent.map(String.init) ?? "unknown"),
            state(observedAt, "battery.charging", battery.charging.map(boolText) ?? "unknown"),
            state(observedAt, "network.isAvailable", boolText(network.isAvailable)),
            state(observedAt, "media.isAvailable", boolText(media.isAvailable), "medium"),
            state(observedAt, "media.playbackStatus", media.playbackStatus, "medium"),
            state(observedAt, "media.sourceAppUserModelId", media.sourceAppUserModelId, "medium"),
            state(observedAt, "system.timeZoneId", system.timeZoneId, "medium"),
            state(observedAt, "system.uptimeSeconds", String(system.uptimeSeconds)),
            state(observedAt, "system.cpuPressureBucket", systemLoad.cpuPressureBucket),
            state(observedAt, "system.memoryPressureBucket", systemLoad.memoryPressureBucket),
            state(observedAt, "wellness.continuousActiveMinutes", String(wellness.continuousActiveMinutes)),
            state(observedAt, "wellness.minutesSinceLastBreak", String(wellness.minutesSinceLastBreak)),
            state(observedAt, "activity.contextSwitchesPerMin", String(activity.contextSwitchesPerMin), "medium"),
            state(observedAt, "display.count", String(displays.count), "medium")
        ]

        for item in foreground.titleSummary {
            states.append(state(observedAt, "foregroundApp.titleSummary." + item.key, item.value, "medium"))
        }

        if !isBlank(foreground.rawWindowTitle) {
            states.append(state(observedAt, "foregroundApp.rawWindowTitle", foreground.rawWindowTitle, "high"))
        }

        if !isBlank(media.title) {
            states.append(state(observedAt, "media.title", media.title, "high"))
        }

        if !isBlank(media.artist) {
            states.append(state(observedAt, "media.artist", media.artist, "high"))
        }

        if !isBlank(media.albumTitle) {
            states.append(state(observedAt, "media.albumTitle", media.albumTitle, "high"))
        }

        for (index, display) in displays.enumerated() {
            let prefix = "displays." + String(index)
            states.append(state(observedAt, prefix + ".deviceName", display.deviceName, "medium"))
            states.append(state(observedAt, prefix + ".primary", boolText(display.primary), "medium"))
            states.append(state(observedAt, prefix + ".left", String(display.left), "medium"))
            states.append(state(observedAt, prefix + ".top", String(display.top), "medium"))
            states.append(state(observedAt, prefix + ".width", String(display.width), "medium"))
            states.append(state(observedAt, prefix + ".height", String(display.height), "medium"))
        }

        for setting in power.lastKnownSettings {
            states.append(state(observedAt, "power.lastKnownSettings." + setting.key, setting.value))
        }

        return states
    }

    public static func buildEvents(_ events: [AmbientEvent]) -> [AmbientOutboundEvent] {
        let candidates = events.filter { !$0.initializationOnly }
        let deduplicated = deduplicateOutboundEvents(candidates)
        return deduplicated.suffix(10).map { item in
            AmbientOutboundEvent(
                observedAt: item.observedAt,
                name: item.kind,
                value: eventValue(item),
                payload: item.data,
                sensitivity: item.sensitivity)
        }
    }

    private static func deduplicateOutboundEvents(_ events: [AmbientEvent]) -> [AmbientEvent] {
        events.enumerated()
            .filter { !hasNearbyHigherLevelEvent(at: $0.offset, in: events) }
            .map(\.element)
    }

    // C# は ReferenceEquals で自分自身を除外している。Swift の AmbientEvent は値型なので
    // インデックス比較で「自分以外」を表現する (同値のイベントが 2 件あっても挙動は同じ)。
    private static func hasNearbyHigherLevelEvent(at index: Int, in events: [AmbientEvent]) -> Bool {
        let ambientEvent = events[index]
        guard let higherLevelEvents = higherLevelEventsBySuppressedEvent[ambientEvent.kind.lowercased()] else {
            return false
        }

        for (candidateIndex, candidate) in events.enumerated() where candidateIndex != index {
            guard higherLevelEvents.contains(candidate.kind.lowercased()) else { continue }
            if isWithinDeduplicationWindow(ambientEvent.observedAt, candidate.observedAt) {
                return true
            }
        }
        return false
    }

    private static func isWithinDeduplicationWindow(_ left: Date, _ right: Date) -> Bool {
        abs(left.timeIntervalSince(right)) <= outboundEventDeduplicationWindow
    }

    private static func eventValue(_ ambientEvent: AmbientEvent) -> String {
        if let toValue = ambientEvent.data["to"] {
            return toValue
        }
        if let value = ambientEvent.data["value"] {
            return value
        }
        return "true"
    }

    private static func state(
        _ observedAt: Date,
        _ name: String,
        _ value: String,
        _ sensitivity: String = "low"
    ) -> AmbientState {
        AmbientState(observedAt: observedAt, name: name, value: value, sensitivity: sensitivity)
    }

    private static func boolText(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
