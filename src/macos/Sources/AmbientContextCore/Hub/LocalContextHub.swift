import Foundation

/// C# 版 `LocalContextHub` の移植。
/// C# は `lock (_lock)` で保護していたので、Swift では `NSLock` を持つ `final class` にし、
/// `@unchecked Sendable` を付けて公開 API (ingest / getContextStates / pollEvents /
/// getEventSchemas / getPolicy / reloadSettings / eventPublished) をそのまま保つ。
public final class LocalContextHub: @unchecked Sendable {
    private static let defaultMaxEventAgeHours = 24
    private static let defaultMaxEventCount = 500
    private static let minMaxEventAgeHours = 1
    private static let maxMaxEventAgeHours = 168
    private static let minMaxEventCount = 100
    private static let maxMaxEventCount = 5000
    private static let defaultPollLimit = 50
    private static let maxPollLimit = 1000

    private let lock = NSLock()
    private var events: [LocalContextEvent] = []
    private var eventFingerprints = Set<String>()
    private let cursorTracker = LocalContextCursorTracker()
    private let settingsStore: any SettingsStore
    private let eventLog: LocalContextEventLog
    private let language: String

    private var latestStates: [AmbientState] = []
    private var privacyClassifications: [PrivacyClassification] = []
    private var transmissionPolicy = AmbientTransmissionPolicySnapshot()
    private var latestObservedAt = Date(timeIntervalSince1970: 0)
    private var observedStateCount = 0
    private var outboundStateCount = 0
    private var internalEventHistoryCount = 0
    private var outboundEventCandidateCount = 0
    private var maxEventAgeHours = LocalContextHub.defaultMaxEventAgeHours
    private var maxEventCount = LocalContextHub.defaultMaxEventCount
    private var persistEventLog = false
    private var nextSequence: Int64 = 0
    private var policyVersion = ""

    /// C# の `event EventHandler<LocalContextEvent> EventPublished` 相当。
    public var eventPublished: (@Sendable (LocalContextEvent) -> Void)?

    public init(settingsStore: any SettingsStore, language: String = AmbientContextCatalog.defaultLanguage) {
        self.settingsStore = settingsStore
        self.language = language
        self.eventLog = LocalContextEventLog(
            path: LocalContextEventLog.resolvePath(settingsPath: settingsStore.settingsPath))
        applySettings(initialLoad: true)
        if persistEventLog {
            loadPersistedEventLog()
        }
    }

    public func ingest(_ snapshot: AmbientContextSnapshot) {
        var publishedEvents: [LocalContextEvent] = []
        lock.lock()

        latestObservedAt = snapshot.observedAt
        latestStates = snapshot.outboundStates
        privacyClassifications = snapshot.privacyClassifications
        transmissionPolicy = snapshot.transmissionPolicy
        policyVersion = PolicyVersionService.computePolicyVersion(
            classifications: privacyClassifications,
            overrides: transmissionPolicy.pathTransmitOverrides)

        // events.jsonl から復元した旧スキーマのイベントは payloadSensitivity が空のまま
        // events に乗っているため、scope フィルタが event-level だけにフォールバックして
        // 高機微 payload キーが意図せず流れ続ける。最初に classifications を持つ snapshot が
        // 来たタイミングで一度だけ backfill する (以降は一致するエントリが無く no-op)。
        let backfilled = backfillLegacyPayloadSensitivity()
        observedStateCount = snapshot.states.count
        outboundStateCount = snapshot.outboundStates.count
        internalEventHistoryCount = snapshot.events.count
        outboundEventCandidateCount = snapshot.outboundEvents.count

        for outboundEvent in snapshot.outboundEvents {
            let fingerprint = Self.fingerprint(
                observedAt: outboundEvent.observedAt,
                name: outboundEvent.name,
                value: outboundEvent.value,
                payload: outboundEvent.payload)
            if eventFingerprints.contains(fingerprint) { continue }
            eventFingerprints.insert(fingerprint)

            nextSequence += 1
            let sequence = nextSequence
            let computed = SensitivityScopeFilter.computePayloadSensitivity(
                eventName: outboundEvent.name,
                payload: outboundEvent.payload,
                classifications: privacyClassifications,
                eventSensitivity: outboundEvent.sensitivity)
            let localEvent = LocalContextEvent(
                id: Self.createEventId(observedAt: outboundEvent.observedAt, sequence: sequence),
                sequence: sequence,
                observedAt: outboundEvent.observedAt,
                name: outboundEvent.name,
                value: outboundEvent.value,
                payload: outboundEvent.payload,
                sensitivity: outboundEvent.sensitivity,
                payloadSensitivity: computed.perKey,
                maxFieldSensitivity: computed.max)
            events.append(localEvent)
            publishedEvents.append(localEvent)
        }

        let trimmedAny = trimEvents(now: Date())

        if persistEventLog {
            if trimmedAny || backfilled {
                // 古いイベントが落ちたか、または旧スキーマの backfill が走ったので
                // JSONL を events から書き直す (compaction)。
                // 同一トランザクションの新規イベントもこの 1 回の書き出しに含まれる。
                eventLog.rewrite(events)
            } else if !publishedEvents.isEmpty {
                eventLog.append(publishedEvents)
            }
        }

        lock.unlock()

        for localEvent in publishedEvents {
            eventPublished?(localEvent)
        }
    }

    public func getContextStates(_ request: LocalContextStateRequest) -> LocalContextStateResponse {
        lock.lock()
        defer { lock.unlock() }

        let states = latestStates
            .filter { Self.isNameIncluded($0.name, request.names) }
            .filter { SensitivityScopeFilter.isSensitivityAllowed($0.sensitivity, scopes: request.scopes) }
            .map { Self.toLocalContextState($0, includeMetadata: request.includeMetadata) }

        return LocalContextStateResponse(
            observedAt: latestObservedAt,
            states: states,
            policyVersion: policyVersion)
    }

    public func pollEvents(_ request: LocalContextPollRequest) -> LocalContextPollResponse {
        lock.lock()
        defer { lock.unlock() }

        let now = Date()
        _ = trimEvents(now: now)
        cursorTracker.pruneStale(now: now)

        let limit = Self.normalizeLimit(request.limit)
        let isHistoryQuery = request.since != nil || request.until != nil
        let cursorResult = cursorTracker.resolve(
            clientId: request.clientId,
            cursor: request.cursor,
            isHistoryQuery: isHistoryQuery,
            firstSequence: firstSequence(),
            latestSequence: latestSequence(),
            now: now)

        var matchingEvents: [LocalContextEvent] = []
        for item in events {
            guard item.sequence > cursorResult.sequence else { continue }
            if let since = request.since, item.observedAt < since { continue }
            if let until = request.until, item.observedAt > until { continue }
            guard Self.isNameIncluded(item.name, request.names) else { continue }
            guard let filtered = SensitivityScopeFilter.filterEventForScope(item, scopes: request.scopes) else {
                continue
            }
            matchingEvents.append(request.includePayload ? filtered : Self.stripPayload(filtered))
            if matchingEvents.count > limit { break }
        }

        let returnedEvents = Array(matchingEvents.prefix(limit))
        let lastSequence = returnedEvents.last?.sequence ?? cursorResult.sequence

        // history query (since/until 指定) は副作用なしの stateless 取得。
        // クライアント位置を進めない (= 同じ範囲で再取得しても結果が消えない)。
        // pagination は呼び出し側が nextCursor を渡すことで行う。
        if !isHistoryQuery {
            cursorTracker.advance(clientId: request.clientId, sequence: lastSequence, now: now)
        }

        return LocalContextPollResponse(
            events: returnedEvents,
            nextCursor: LocalContextCursorTracker.encode(lastSequence),
            hasMore: matchingEvents.count > limit,
            cursorExpired: cursorResult.expired,
            retention: LocalContextRetentionInfo(
                maxAgeHours: maxEventAgeHours,
                maxEvents: maxEventCount),
            policyVersion: policyVersion)
    }

    public func getEventSchemas() -> LocalContextEventSchemasResponse {
        LocalContextEventSchemasResponse(
            events: AmbientContextCatalog.getEventSchemas(language: language))
    }

    public func getPolicy() -> LocalContextPolicyResponse {
        lock.lock()
        defer { lock.unlock() }

        return LocalContextPolicyResponse(
            observedAt: latestObservedAt,
            transmissionPolicy: transmissionPolicy,
            privacyClassifications: privacyClassifications,
            effectivePolicies: privacyClassifications.map {
                Self.buildEffectivePolicy($0, transmissionPolicy: transmissionPolicy)
            },
            observedStateCount: observedStateCount,
            outboundStateCount: outboundStateCount,
            internalEventHistoryCount: internalEventHistoryCount,
            outboundEventCandidateCount: outboundEventCandidateCount,
            retainedOutboundEventCount: events.count,
            retention: LocalContextRetentionInfo(
                maxAgeHours: maxEventAgeHours,
                maxEvents: maxEventCount))
    }

    public func reloadSettings() {
        applySettings(initialLoad: false)
    }

    /// 設定の読み込みと、永続化フラグ遷移に応じたファイル操作を一箇所にまとめる。
    /// initialLoad = true (= イニシャライザからの初回呼び出し) の場合、
    /// 「OFF→ON / ON→OFF 同期」分岐を**意図的にスキップ**する。
    /// 初回時点で persistEventLog は false で初期化されているため、ユーザーが永続化を ON にした
    /// 保存設定をロードすると false→true に見えてしまうが、それを「ユーザーが ON に切替えた」と
    /// 誤認して空の events をファイルに書き戻すと、既存の events.jsonl を消してしまう。
    /// 初回の events.jsonl 復元は `loadPersistedEventLog` に任せる。
    private func applySettings(initialLoad: Bool) {
        let settings = settingsStore.loadLocalContextSettings()
        lock.lock()
        defer { lock.unlock() }

        let previousPersist = persistEventLog
        maxEventAgeHours = Self.normalizeMaxEventAgeHours(settings.maxEventAgeHours)
        maxEventCount = Self.normalizeMaxEventCount(settings.maxEventCount)
        persistEventLog = settings.persistEventLog
        let trimmed = trimEvents(now: Date())

        if initialLoad {
            return
        }

        if persistEventLog {
            if !previousPersist || trimmed {
                // OFF → ON: 在席中の opt-in。in-memory の events をファイルに同期する。
                // trimmed: 古いイベントが落ちたので compaction する。
                eventLog.rewrite(events)
            }
        } else if previousPersist {
            // ON → OFF: ユーザーが明示的に opt-out したのでファイルを削除する。
            eventLog.delete()
        }
    }

    /// payloadSensitivity / maxFieldSensitivity が空のままの events エントリを
    /// 現在の privacyClassifications から再計算して詰め直す。返り値は 1 件以上書き換えたかどうか。
    private func backfillLegacyPayloadSensitivity() -> Bool {
        var backfilled = false
        for index in events.indices {
            let current = events[index]
            if !current.maxFieldSensitivity.isEmpty { continue }

            let computed = SensitivityScopeFilter.computePayloadSensitivity(
                eventName: current.name,
                payload: current.payload,
                classifications: privacyClassifications,
                eventSensitivity: current.sensitivity)
            events[index] = LocalContextEvent(
                id: current.id,
                sequence: current.sequence,
                observedAt: current.observedAt,
                name: current.name,
                value: current.value,
                payload: current.payload,
                sensitivity: current.sensitivity,
                payloadSensitivity: computed.perKey,
                maxFieldSensitivity: computed.max)
            backfilled = true
        }
        return backfilled
    }

    /// 戻り値は「実際にイベントを 1 件以上落としたか」。永続化が ON の場合、
    /// 呼び出し側はこのフラグを見て events.jsonl を rewrite するか判定する。
    private func trimEvents(now: Date) -> Bool {
        var trimmed = false
        let cutoff = now.addingTimeInterval(-Double(maxEventAgeHours) * 3600)
        while let first = events.first, first.observedAt < cutoff {
            eventFingerprints.remove(Self.fingerprint(
                observedAt: first.observedAt,
                name: first.name,
                value: first.value,
                payload: first.payload))
            events.removeFirst()
            trimmed = true
        }

        while events.count > maxEventCount {
            let first = events[0]
            eventFingerprints.remove(Self.fingerprint(
                observedAt: first.observedAt,
                name: first.name,
                value: first.value,
                payload: first.payload))
            events.removeFirst()
            trimmed = true
        }

        return trimmed
    }

    /// 起動時に既存 events.jsonl を読み込んで events / eventFingerprints / nextSequence を再構築する。
    /// 読み込み後、現在の age/count 制限で trim する。
    private func loadPersistedEventLog() {
        lock.lock()
        defer { lock.unlock() }

        for loaded in eventLog.load() {
            let fingerprint = Self.fingerprint(
                observedAt: loaded.observedAt,
                name: loaded.name,
                value: loaded.value,
                payload: loaded.payload)
            if eventFingerprints.contains(fingerprint) { continue }
            eventFingerprints.insert(fingerprint)

            events.append(loaded)
            if loaded.sequence > nextSequence {
                nextSequence = loaded.sequence
            }
        }

        events.sort { $0.sequence < $1.sequence }

        if trimEvents(now: Date()) {
            eventLog.rewrite(events)
        }
    }

    public static func normalizeMaxEventAgeHours(_ hours: Int) -> Int {
        if hours <= 0 { return defaultMaxEventAgeHours }
        return min(max(hours, minMaxEventAgeHours), maxMaxEventAgeHours)
    }

    public static func normalizeMaxEventCount(_ count: Int) -> Int {
        if count <= 0 { return defaultMaxEventCount }
        return min(max(count, minMaxEventCount), maxMaxEventCount)
    }

    private func firstSequence() -> Int64 {
        events.first?.sequence ?? 0
    }

    private func latestSequence() -> Int64 {
        events.last?.sequence ?? 0
    }

    private static func normalizeLimit(_ limit: Int) -> Int {
        if limit <= 0 { return defaultPollLimit }
        return min(limit, maxPollLimit)
    }

    private static func isNameIncluded(_ name: String, _ names: [String]) -> Bool {
        names.isEmpty || names.contains { $0.lowercased() == name.lowercased() }
    }

    private static func toLocalContextState(_ state: AmbientState, includeMetadata: Bool) -> LocalContextState {
        LocalContextState(
            observedAt: includeMetadata ? state.observedAt : nil,
            name: state.name,
            value: state.value,
            sensitivity: includeMetadata ? state.sensitivity : nil)
    }

    static func buildEffectivePolicy(
        _ classification: PrivacyClassification,
        transmissionPolicy: AmbientTransmissionPolicySnapshot
    ) -> LocalContextEffectivePolicy {
        let resolved = tryGetOverride(
            path: classification.path,
            overrides: transmissionPolicy.pathTransmitOverrides)

        return LocalContextEffectivePolicy(
            path: classification.path,
            sensitivity: classification.sensitivity,
            requiredScope: "context." +
                SensitivityScopeFilter.normalizeSensitivity(classification.sensitivity) + ":read",
            defaultTransmit: classification.defaultTransmit,
            effectiveTransmit: resolved?.allowed ?? classification.defaultTransmit,
            hasOverride: resolved != nil,
            overridePath: resolved?.path ?? "",
            overrideTransmit: resolved?.allowed,
            reason: classification.reason)
    }

    /// path から `.` 区切りで親方向に遡り、最初に見つかった override を返す。
    static func tryGetOverride(
        path: String,
        overrides: CaseInsensitiveDictionary<Bool>
    ) -> (path: String, allowed: Bool)? {
        var current = path
        while !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let allowed = overrides[current] {
                return (current, allowed)
            }
            guard let lastDot = current.lastIndex(of: ".") else { break }
            current = String(current[current.startIndex..<lastDot])
        }
        return nil
    }

    /// 要約モードで返すために payload と payloadSensitivity を空にした複製を作る。
    /// id / sequence / observedAt / name / value / sensitivity / maxFieldSensitivity は保持する。
    private static func stripPayload(_ event: LocalContextEvent) -> LocalContextEvent {
        LocalContextEvent(
            id: event.id,
            sequence: event.sequence,
            observedAt: event.observedAt,
            name: event.name,
            value: event.value,
            sensitivity: event.sensitivity,
            maxFieldSensitivity: event.maxFieldSensitivity)
    }

    static func createEventId(observedAt: Date, sequence: Int64) -> String {
        "evt_\(AmbientDateFormat.compactUtcStamp(from: observedAt))_"
            + String(format: "%06lld", sequence)
    }

    private static func fingerprint(
        observedAt: Date,
        name: String,
        value: String,
        payload: CaseInsensitiveDictionary<String>
    ) -> String {
        let unixMilliseconds = Int64((observedAt.timeIntervalSince1970 * 1000).rounded(.down))
        let payloadFingerprint = payload.sortedPairs
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
        return [String(unixMilliseconds), name, value, payloadFingerprint].joined(separator: "|")
    }
}
