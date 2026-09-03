import Foundation

/// C# の `DateOnly.FromDateTime(dateTimeOffset.DateTime)` 相当 (ローカル暦日)。
extension DateOnly {
    public init(localDate date: Date, calendar: Calendar = .current) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

/// C# 版 `WindowsAmbientContextService.Transitions.cs` +
/// `WindowsAmbientContextService.cs` の非 Win32 部分 (イベント蓄積 / activity / wellness /
/// power / セッション・電源通知のイベント名写像) を切り出した状態機械。
///
/// **スレッド安全ではない。** C# 版は message-only window スレッド + `_eventLock` で直列化して
/// いた。Swift 版は呼び出し側 (Phase 3b の `MacAmbientContextService` actor) が直列化する前提で、
/// この型自身はロックを持たない。
public final class TransitionEvaluator {
    /// C# の `const` 群に対応する調整値。既定値は Windows 版と同値。
    public struct Configuration: Sendable, Hashable {
        public var maxRecentEvents: Int
        public var recentEventRetention: TimeInterval
        public var contextSwitchBurstThresholdPerMinute: Int
        public var contextSwitchBurstResetThresholdPerMinute: Int
        public var longSessionWarningMinutes: Int
        public var foregroundCaptureThrottleMilliseconds: Int
        /// 初期化フェーズの終了判定に使う電源設定通知の期待件数。
        /// C# は `Math.Min(ExpectedInitialPowerSettingCount, 登録できたハンドル数)` を使うため、
        /// 呼び出し側が同じ計算をした結果を注入する (テストからも差し替えられる)。
        public var expectedInitialPowerSettingCount: Int

        public init(
            maxRecentEvents: Int = 500,
            recentEventRetention: TimeInterval = 24 * 60 * 60,
            contextSwitchBurstThresholdPerMinute: Int = 12,
            contextSwitchBurstResetThresholdPerMinute: Int = 8,
            longSessionWarningMinutes: Int = 90,
            foregroundCaptureThrottleMilliseconds: Int = 1000,
            expectedInitialPowerSettingCount: Int = 8
        ) {
            self.maxRecentEvents = maxRecentEvents
            self.recentEventRetention = recentEventRetention
            self.contextSwitchBurstThresholdPerMinute = contextSwitchBurstThresholdPerMinute
            self.contextSwitchBurstResetThresholdPerMinute = contextSwitchBurstResetThresholdPerMinute
            self.longSessionWarningMinutes = longSessionWarningMinutes
            self.foregroundCaptureThrottleMilliseconds = foregroundCaptureThrottleMilliseconds
            self.expectedInitialPowerSettingCount = expectedInitialPowerSettingCount
        }
    }

    /// Windows の `WM_WTSSESSION_CHANGE`、macOS の `com.apple.screenIsLocked` /
    /// `NSWorkspace.sessionDidBecomeActive` などに対応する。
    public enum SessionChange: Sendable, Hashable {
        case locked
        case unlocked
        case logon
        case logoff
    }

    /// Windows の `WM_POWERBROADCAST`、macOS の `NSWorkspace.willSleep` / `didWake` に対応する。
    /// macOS では dark wake がユーザプロセスに届かないため `.resumeAutomatic` は通常使わない
    /// (設計書 §3.3 の既知の差分)。
    public enum PowerBroadcast: Sendable, Hashable {
        case suspend
        case resumeUser
        case resumeAutomatic
    }

    private let configuration: Configuration
    private let now: () -> Date
    private let calendar: Calendar
    private let persistLastActivityDate: (DateOnly) -> Void

    private var recentEventStore: [AmbientEvent] = []
    private var foregroundSwitchTimes: [Date] = []
    private var lastPowerSettings = CaseInsensitiveDictionary<String>()

    private var lastForegroundActivation: Date?
    private var powerSettingsInitialized = false
    private var initialPowerSettingsSeen = 0
    private var lastPresenceBucket = ""
    private var lastForegroundCategory = ""
    private var lastForegroundProcessName = ""
    private var foregroundCategoryInitialized = false
    private var lastForegroundRawWindowTitle = ""
    private var lastForegroundTitleSummaryKey = ""
    private var foregroundTitleInitialized = false
    private var lastBatteryBucket = "unknown"
    private var lastBatteryPercent: Int?
    private var lastCharging: Bool?
    private var lastPowerSource = ""
    private var lastNetworkAvailable: Bool?
    private var lastMediaKey = ""
    private var lastMediaPlaybackStatus = ""
    private var lastTimeZoneId = ""
    private var lastDisplayCount = -1
    private var systemUnderLoadActive = false
    private var contextSwitchBurstActive = false
    private var continuousActiveStartedAt: Date?
    private var lastBreakEndedAt: Date?
    private var wasInBreak = true
    private var longSessionWarningActive = false

    /// セッションがロック中か。`PresenceContext.bucket` を組む Collector 側が参照する。
    public private(set) var sessionLocked = false

    /// 最後に `first_activity_today` を発火したローカル暦日。
    public private(set) var lastActivityDate: DateOnly?

    /// - Parameters:
    ///   - lastActivityDate: 永続化済みの値 (`SettingsStore.loadTransientStateSettings()`)。
    ///   - persistLastActivityDate: 新しい日付を保存するクロージャ。Core は具体的なストアに
    ///     依存しないため注入で受ける。失敗しても発火自体は止めない best-effort 契約なので、
    ///     例外を投げない実装 (呼び出し側で握り潰す) を渡すこと。
    ///   - now: 時刻取得。イベントの `observedAt` とスロットル判定に使う (テストで差し替える)。
    public init(
        configuration: Configuration = Configuration(),
        lastActivityDate: DateOnly? = nil,
        calendar: Calendar = .current,
        now: @escaping () -> Date = { Date() },
        persistLastActivityDate: @escaping (DateOnly) -> Void = { _ in }
    ) {
        self.configuration = configuration
        self.lastActivityDate = lastActivityDate
        self.calendar = calendar
        self.now = now
        self.persistLastActivityDate = persistLastActivityDate
    }

    // MARK: - 外部イベントの取り込み

    public func recordSessionChange(_ change: SessionChange) {
        switch change {
        case .locked:
            sessionLocked = true
            addEvent("session_locked")
        case .unlocked:
            sessionLocked = false
            addEvent("session_unlocked")
        case .logon:
            addEvent("session_logon")
        case .logoff:
            addEvent("session_logoff")
        }
    }

    public func recordPowerBroadcast(_ change: PowerBroadcast) {
        switch change {
        case .suspend: addEvent("system_suspend")
        case .resumeUser: addEvent("system_resume_user")
        case .resumeAutomatic: addEvent("system_resume_automatic")
        }
    }

    /// 電源設定の変化を取り込む。起動直後は OS が現在値をまとめて通知してくるため、
    /// 期待件数に達するまでは「初期化フェーズ」として `power_setting_changed` を発火せず
    /// `lastKnownSettings` の充填だけ行う (C# の `InitializePowerSetting` と同じ)。
    ///
    /// - Parameter extraPayload: `setting` / `value` 以外に載せる payload
    ///   (Windows は `guid` / `raw_value` / `data_length`)。
    public func recordPowerSetting(
        name: String,
        value: String,
        extraPayload: [(String, String)] = []
    ) {
        if !powerSettingsInitialized {
            initializePowerSetting(name: name, value: value)
            return
        }

        var data = CaseInsensitiveDictionary<String>()
        data["setting"] = name
        data["value"] = value
        for pair in extraPayload {
            data[pair.0] = pair.1
        }
        addEvent("power_setting_changed", data)

        if name.lowercased() == "ac_dc_power_source" {
            addPowerSourceTransitionEvents(previous: lastPowerSource, current: value)
            lastPowerSource = value
        }

        lastPowerSettings[name] = value
    }

    /// 監視の登録完了を記録する (`initializationOnly` なので送信対象にはならない)。
    public func recordMonitorsAttached(_ data: [(String, String)]) {
        addEvent("ambient_monitor_attached", CaseInsensitiveDictionary(data), initializationOnly: true)
    }

    /// フォアグラウンドアプリの切り替え通知。スロットル (既定 1000 ms) を通過したときだけ
    /// context switch としてカウントし `true` を返す。呼び出し側は `true` のときに capture する。
    ///
    /// `foreground_changed` の唯一の emit 点は `evaluate` 側なので、ここではイベントを出さない。
    @discardableResult
    public func recordForegroundActivation(at date: Date) -> Bool {
        let throttle = TimeInterval(configuration.foregroundCaptureThrottleMilliseconds) / 1000
        if let lastForegroundActivation, date.timeIntervalSince(lastForegroundActivation) < throttle {
            return false
        }

        lastForegroundActivation = date
        foregroundSwitchTimes.append(date)
        trimForegroundSwitchTimes(date)
        return true
    }

    // MARK: - 派生コンテキスト

    public func activity(at observedAt: Date) -> ActivityContext {
        trimForegroundSwitchTimes(observedAt)
        return ActivityContext(contextSwitchesPerMin: foregroundSwitchTimes.count)
    }

    /// 連続稼働・休憩からの経過を更新して返す。**副作用がある** ので capture 1 回につき
    /// 1 度だけ、`evaluate` より前に呼ぶこと (C# の `CaptureAsync` と同じ順序)。
    public func wellness(presence: PresenceContext, at observedAt: Date) -> WellnessContext {
        if Self.isBreakPresence(presence.bucket) {
            continuousActiveStartedAt = nil
            wasInBreak = true
            longSessionWarningActive = false
            return WellnessContext()
        }

        if continuousActiveStartedAt == nil {
            continuousActiveStartedAt = observedAt
        }
        if wasInBreak || lastBreakEndedAt == nil {
            lastBreakEndedAt = observedAt
        }

        wasInBreak = false
        return WellnessContext(
            continuousActiveMinutes: Self.wholeMinutes(observedAt.timeIntervalSince(continuousActiveStartedAt ?? observedAt)),
            minutesSinceLastBreak: Self.wholeMinutes(observedAt.timeIntervalSince(lastBreakEndedAt ?? observedAt)))
    }

    public func power() -> PowerContext {
        let lastPowerEvent = recentEventStore.last { $0.kind.lowercased() == "power_setting_changed" }
        return PowerContext(
            lastKnownSettings: CaseInsensitiveDictionary(lastPowerSettings),
            lastPowerSettingEvent: lastPowerEvent)
    }

    public func recentEvents() -> [AmbientEvent] {
        trimRecentEvents(now())
        return recentEventStore
    }

    // MARK: - 遷移評価

    /// C# `CaptureAsync` の `Evaluate*Transitions` 呼び出しと同じ順序で全遷移を評価する。
    public func evaluate(
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
    ) {
        _ = power // power は状態を持たないので評価対象外 (C# も同じ)
        evaluatePresenceTransitions(presence)
        evaluateForegroundTransitions(foreground)
        evaluateForegroundTitleTransitions(foreground)
        evaluateBatteryTransitions(battery)
        evaluateMediaTransitions(media)
        evaluateNetworkTransitions(network)
        evaluateSystemTransitions(system)
        evaluateSystemLoadTransitions(systemLoad)
        evaluateActivityTransitions(activity)
        evaluateWellnessTransitions(wellness, presence: presence, observedAt: observedAt)
        evaluateDisplayTransitions(displays)
    }

    private func evaluatePresenceTransitions(_ presence: PresenceContext) {
        if Self.isBlank(lastPresenceBucket) {
            lastPresenceBucket = presence.bucket
            return
        }

        if presence.bucket.lowercased() == lastPresenceBucket.lowercased() {
            return
        }

        let data = Self.transitionData(previous: lastPresenceBucket, current: presence.bucket)
        addEvent("presence_bucket_changed", data)

        let previousLower = lastPresenceBucket.lowercased()
        if presence.bucket.lowercased() == "active",
           ["idle", "away_short", "away_long", "locked"].contains(previousLower) {
            addEvent("user_returned", data)
        } else if presence.bucket.lowercased() == "idle", previousLower == "active" {
            addEvent("user_became_idle", data)
        }

        lastPresenceBucket = presence.bucket
    }

    /// `foreground_changed` の唯一の emit 点。process_name または category が直近 emit と
    /// 異なるときに発火し、payload に `category_changed` フラグを含める。
    private func evaluateForegroundTransitions(_ foreground: ForegroundAppContext) {
        // category="" / processName="" は「該当データなし」の正規値なので、
        // 初期化フラグで「まだ何も emit していない」状態と通常遷移を分ける。
        if !foregroundCategoryInitialized {
            lastForegroundCategory = foreground.category
            lastForegroundProcessName = foreground.processName
            foregroundCategoryInitialized = true
            return
        }

        let processChanged = foreground.processName.lowercased() != lastForegroundProcessName.lowercased()
        let categoryChanged = foreground.category.lowercased() != lastForegroundCategory.lowercased()
        if !processChanged && !categoryChanged {
            return
        }

        var data = CaseInsensitiveDictionary<String>()
        data["category"] = foreground.category
        data["app_name"] = foreground.appName
        data["process_name"] = foreground.processName
        data["category_changed"] = categoryChanged ? "true" : "false"
        addEvent("foreground_changed", data, sensitivity: "medium")

        lastForegroundCategory = foreground.category
        lastForegroundProcessName = foreground.processName
    }

    /// タイトル (原文 / 要約) が直近 emit と変わった瞬間に `foreground_title_changed` を発火する。
    /// 高機微な `raw_window_title` は payload キー単位の opt-in でフィルタされる。
    private func evaluateForegroundTitleTransitions(_ foreground: ForegroundAppContext) {
        let rawTitle = foreground.rawWindowTitle
        let summaryKey = Self.serializeTitleSummary(foreground.titleSummary)

        if !foregroundTitleInitialized {
            lastForegroundRawWindowTitle = rawTitle
            lastForegroundTitleSummaryKey = summaryKey
            foregroundTitleInitialized = true
            return
        }

        if rawTitle == lastForegroundRawWindowTitle && summaryKey == lastForegroundTitleSummaryKey {
            return
        }

        var data = CaseInsensitiveDictionary<String>()
        data["category"] = foreground.category
        data["app_name"] = foreground.appName
        data["process_name"] = foreground.processName
        data["raw_window_title"] = rawTitle
        for item in foreground.titleSummary {
            data["titleSummary." + item.key] = item.value
        }

        addEvent("foreground_title_changed", data, sensitivity: "medium")

        lastForegroundRawWindowTitle = rawTitle
        lastForegroundTitleSummaryKey = summaryKey
    }

    private func evaluateBatteryTransitions(_ battery: BatteryContext) {
        evaluateBatteryThresholds(battery.percent)

        if battery.bucket != lastBatteryBucket {
            if ["medium", "low", "critical"].contains(battery.bucket) {
                var data = CaseInsensitiveDictionary<String>()
                data["percent"] = battery.percent.map(String.init) ?? "unknown"
                addEvent("battery_" + battery.bucket, data)
            }
            lastBatteryBucket = battery.bucket
        }

        if lastCharging != nil && battery.charging != lastCharging {
            addEvent(battery.charging == true ? "charger_connected" : "charger_disconnected")
        }

        lastCharging = battery.charging
    }

    private func evaluateBatteryThresholds(_ currentPercent: Int?) {
        guard let previous = lastBatteryPercent else {
            lastBatteryPercent = currentPercent
            return
        }

        guard let current = currentPercent else {
            lastBatteryPercent = nil
            return
        }

        for threshold in AmbientTier1Rules.batteryPercentThresholds {
            if previous > threshold && current <= threshold {
                addEvent("battery_percent_crossed_threshold", CaseInsensitiveDictionary([
                    ("threshold", String(threshold)),
                    ("direction", "down"),
                    ("from", String(previous)),
                    ("to", String(current))
                ]))
            } else if previous < threshold && current >= threshold {
                addEvent("battery_percent_crossed_threshold", CaseInsensitiveDictionary([
                    ("threshold", String(threshold)),
                    ("direction", "up"),
                    ("from", String(previous)),
                    ("to", String(current))
                ]))
            }
        }

        lastBatteryPercent = current
    }

    private func evaluateMediaTransitions(_ media: MediaContext) {
        if !Self.isBlank(lastMediaPlaybackStatus),
           media.playbackStatus.lowercased() != lastMediaPlaybackStatus.lowercased() {
            let data = Self.transitionData(previous: lastMediaPlaybackStatus, current: media.playbackStatus)
            let eventName: String
            switch media.playbackStatus {
            case "Playing": eventName = "media_playback_started"
            case "Paused": eventName = "media_playback_paused"
            case "Stopped": eventName = "media_playback_stopped"
            default: eventName = "media_playback_status_changed"
            }
            addEvent(eventName, data, sensitivity: "medium")
        }

        lastMediaPlaybackStatus = media.playbackStatus

        let key = media.isAvailable
            ? [media.sourceAppUserModelId, media.playbackStatus, media.title, media.artist, media.albumTitle]
                .joined(separator: "|")
            : ""

        if key == lastMediaKey {
            return
        }

        if !Self.isBlank(key) {
            // event 本体は medium (タイミング信号 + 再生元アプリ程度)。
            // title / artist は AmbientTransmissionPolicy の payload key 単位フィルタで個別判定される。
            addEvent("media_session_changed", CaseInsensitiveDictionary([
                ("source_app", media.sourceAppUserModelId),
                ("source_kind", MediaSourceKindClassifier.classify(media.sourceAppUserModelId)),
                ("playback_status", media.playbackStatus),
                ("title", media.title),
                ("artist", media.artist),
                ("album_title", media.albumTitle)
            ]), sensitivity: "medium")
        }

        lastMediaKey = key
    }

    private func evaluateNetworkTransitions(_ network: NetworkContext) {
        guard let previous = lastNetworkAvailable else {
            lastNetworkAvailable = network.isAvailable
            return
        }

        if previous == network.isAvailable {
            return
        }

        addEvent("network_connectivity_changed", CaseInsensitiveDictionary([
            ("from", previous ? "online" : "offline"),
            ("to", network.isAvailable ? "online" : "offline")
        ]))
        lastNetworkAvailable = network.isAvailable
    }

    private func evaluateSystemTransitions(_ system: SystemContext) {
        if Self.isBlank(lastTimeZoneId) {
            lastTimeZoneId = system.timeZoneId
            return
        }

        if system.timeZoneId.lowercased() == lastTimeZoneId.lowercased() {
            return
        }

        addEvent(
            "timezone_changed",
            Self.transitionData(previous: lastTimeZoneId, current: system.timeZoneId),
            sensitivity: "medium")
        lastTimeZoneId = system.timeZoneId
    }

    private func evaluateSystemLoadTransitions(_ systemLoad: SystemLoadContext) {
        let underLoad = Self.isHighPressureBucket(systemLoad.cpuPressureBucket) ||
            Self.isHighPressureBucket(systemLoad.memoryPressureBucket)
        if underLoad && !systemUnderLoadActive {
            addEvent("system_under_load", CaseInsensitiveDictionary([
                ("cpu_pressure", systemLoad.cpuPressureBucket),
                ("memory_pressure", systemLoad.memoryPressureBucket)
            ]))
        }

        systemUnderLoadActive = underLoad
    }

    private func evaluateActivityTransitions(_ activity: ActivityContext) {
        if activity.contextSwitchesPerMin >= configuration.contextSwitchBurstThresholdPerMinute
            && !contextSwitchBurstActive {
            addEvent(
                "context_switch_burst",
                CaseInsensitiveDictionary([("switches_per_min", String(activity.contextSwitchesPerMin))]),
                sensitivity: "medium")
            contextSwitchBurstActive = true
        } else if activity.contextSwitchesPerMin < configuration.contextSwitchBurstResetThresholdPerMinute {
            contextSwitchBurstActive = false
        }
    }

    private func evaluateWellnessTransitions(
        _ wellness: WellnessContext,
        presence: PresenceContext,
        observedAt: Date
    ) {
        let today = DateOnly(localDate: observedAt, calendar: calendar)
        if !Self.isBreakPresence(presence.bucket) && lastActivityDate != today {
            lastActivityDate = today
            // 永続化に失敗してもイベント発火自体は止めない (best-effort)。
            persistLastActivityDate(today)
            addEvent("first_activity_today")
        }

        if wellness.continuousActiveMinutes >= configuration.longSessionWarningMinutes
            && !longSessionWarningActive {
            addEvent("long_session_warning", CaseInsensitiveDictionary([
                ("continuous_active_minutes", String(wellness.continuousActiveMinutes))
            ]))
            longSessionWarningActive = true
        } else if wellness.continuousActiveMinutes < configuration.longSessionWarningMinutes {
            longSessionWarningActive = false
        }
    }

    private func evaluateDisplayTransitions(_ displays: [DisplayContext]) {
        if lastDisplayCount < 0 {
            lastDisplayCount = displays.count
            return
        }

        if lastDisplayCount == displays.count {
            return
        }

        addEvent("display_count_changed", CaseInsensitiveDictionary([
            ("from", String(lastDisplayCount)),
            ("to", String(displays.count))
        ]), sensitivity: "medium")
        lastDisplayCount = displays.count
    }

    // MARK: - 内部

    private func initializePowerSetting(name: String, value: String) {
        if !lastPowerSettings.contains(name) {
            initialPowerSettingsSeen += 1
        }

        lastPowerSettings[name] = value
        if name.lowercased() == "ac_dc_power_source" {
            lastPowerSource = value
        }

        if initialPowerSettingsSeen >= configuration.expectedInitialPowerSettingCount {
            powerSettingsInitialized = true
            addEvent(
                "power_settings_initialized",
                CaseInsensitiveDictionary([("count", String(initialPowerSettingsSeen))]),
                initializationOnly: true)
        }
    }

    private func addPowerSourceTransitionEvents(previous: String, current: String) {
        if Self.isBlank(current) || previous.lowercased() == current.lowercased() {
            return
        }

        let data = CaseInsensitiveDictionary([
            ("from", Self.isBlank(previous) ? "unknown" : previous),
            ("to", current)
        ])
        addEvent("power_source_changed", data)

        let eventName: String
        switch current {
        case "ac": eventName = "ac_power_connected"
        case "battery": eventName = "battery_power_active"
        case "short_term": eventName = "short_term_power_active"
        default: eventName = ""
        }

        if !Self.isBlank(eventName) {
            addEvent(eventName, data)
        }
    }

    private func addEvent(
        _ kind: String,
        _ data: CaseInsensitiveDictionary<String> = [:],
        sensitivity: String = "low",
        initializationOnly: Bool = false
    ) {
        let timestamp = now()
        recentEventStore.append(AmbientEvent(
            observedAt: timestamp,
            kind: kind,
            sensitivity: sensitivity,
            initializationOnly: initializationOnly,
            data: data))
        trimRecentEvents(timestamp)
    }

    private func trimRecentEvents(_ moment: Date) {
        let cutoff = moment.addingTimeInterval(-configuration.recentEventRetention)
        recentEventStore.removeAll { $0.observedAt < cutoff }

        if recentEventStore.count > configuration.maxRecentEvents {
            recentEventStore.removeFirst(recentEventStore.count - configuration.maxRecentEvents)
        }
    }

    private func trimForegroundSwitchTimes(_ moment: Date) {
        let cutoff = moment.addingTimeInterval(-60)
        foregroundSwitchTimes.removeAll { $0 < cutoff }
    }

    private static func serializeTitleSummary(_ summary: CaseInsensitiveDictionary<String>) -> String {
        if summary.isEmpty {
            return ""
        }

        return summary.sortedPairs
            .map { $0.key + "=" + $0.value }
            .joined(separator: "|")
    }

    /// 「該当データなし」は空文字でそのまま返す (`AmbientTier1Rules.classifyApp` と同じ整合)。
    private static func transitionData(previous: String, current: String) -> CaseInsensitiveDictionary<String> {
        CaseInsensitiveDictionary([("from", previous), ("to", current)])
    }

    private static func isHighPressureBucket(_ bucket: String) -> Bool {
        let lower = bucket.lowercased()
        return lower == "high" || lower == "critical"
    }

    static func isBreakPresence(_ bucket: String) -> Bool {
        let lower = bucket.lowercased()
        return lower == "away_short" || lower == "away_long" || lower == "locked"
    }

    static func wholeMinutes(_ seconds: TimeInterval) -> Int {
        max(0, Int((seconds / 60).rounded(.down)))
    }

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
