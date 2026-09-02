import Foundation

public struct LocalContextStateRequest: Sendable {
    public var names: [String]
    public var scopes: [String]
    public var includeMetadata: Bool

    public init(names: [String] = [], scopes: [String] = [], includeMetadata: Bool = true) {
        self.names = names
        self.scopes = scopes
        self.includeMetadata = includeMetadata
    }
}

public struct LocalContextStateResponse: Codable, Sendable {
    public var observedAt: Date
    public var states: [LocalContextState]
    public var source: String
    /// クライアントが get_policy を再取得すべきかを判定するための短いハッシュ。
    /// privacyClassifications と pathTransmitOverrides の合成から導出され、
    /// ポリシーに変化があった場合にのみ値が変わる。
    public var policyVersion: String

    public init(
        observedAt: Date = Date(timeIntervalSince1970: 0),
        states: [LocalContextState] = [],
        source: String = "outboundStates",
        policyVersion: String = ""
    ) {
        self.observedAt = observedAt
        self.states = states
        self.source = source
        self.policyVersion = policyVersion
    }
}

public struct LocalContextState: Codable, Sendable, Hashable {
    /// includeMetadata = false のときは JSON から省略される (C# の JsonIgnoreCondition.WhenWritingNull)。
    public var observedAt: Date?
    public var name: String
    public var value: String
    public var sensitivity: String?

    public init(
        observedAt: Date? = nil,
        name: String = "",
        value: String = "",
        sensitivity: String? = nil
    ) {
        self.observedAt = observedAt
        self.name = name
        self.value = value
        self.sensitivity = sensitivity
    }
}

public struct LocalContextPollRequest: Sendable {
    public var clientId: String
    public var cursor: String
    public var names: [String]
    public var scopes: [String]
    public var limit: Int
    /// 指定すると observedAt >= since のイベントのみを返す。
    /// since または until のいずれかが指定された呼び出しは history query 扱いとなり、
    /// クライアント位置 (cursor の暗黙進行) は更新されない。
    public var since: Date?
    /// 指定すると observedAt <= until のイベントのみを返す。
    public var until: Date?
    /// false の場合、各イベントから payload / payloadSensitivity を取り除いた要約形式で返す。
    public var includePayload: Bool

    public init(
        clientId: String = "",
        cursor: String = "",
        names: [String] = [],
        scopes: [String] = [],
        limit: Int = 50,
        since: Date? = nil,
        until: Date? = nil,
        includePayload: Bool = true
    ) {
        self.clientId = clientId
        self.cursor = cursor
        self.names = names
        self.scopes = scopes
        self.limit = limit
        self.since = since
        self.until = until
        self.includePayload = includePayload
    }
}

public struct LocalContextPollResponse: Codable, Sendable {
    public var events: [LocalContextEvent]
    public var nextCursor: String
    public var hasMore: Bool
    public var cursorExpired: Bool
    public var retention: LocalContextRetentionInfo
    /// LocalContextStateResponse.policyVersion と同一値。
    public var policyVersion: String

    public init(
        events: [LocalContextEvent] = [],
        nextCursor: String = "",
        hasMore: Bool = false,
        cursorExpired: Bool = false,
        retention: LocalContextRetentionInfo = .init(),
        policyVersion: String = ""
    ) {
        self.events = events
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.cursorExpired = cursorExpired
        self.retention = retention
        self.policyVersion = policyVersion
    }
}

public struct LocalContextPolicyResponse: Codable, Sendable {
    public var observedAt: Date
    public var source: String
    public var transmissionPolicy: AmbientTransmissionPolicySnapshot
    public var privacyClassifications: [PrivacyClassification]
    public var effectivePolicies: [LocalContextEffectivePolicy]
    public var observedStateCount: Int
    public var outboundStateCount: Int
    public var internalEventHistoryCount: Int
    public var outboundEventCandidateCount: Int
    public var retainedOutboundEventCount: Int
    public var retention: LocalContextRetentionInfo

    public init(
        observedAt: Date = Date(timeIntervalSince1970: 0),
        source: String = "privacyClassifications",
        transmissionPolicy: AmbientTransmissionPolicySnapshot = .init(),
        privacyClassifications: [PrivacyClassification] = [],
        effectivePolicies: [LocalContextEffectivePolicy] = [],
        observedStateCount: Int = 0,
        outboundStateCount: Int = 0,
        internalEventHistoryCount: Int = 0,
        outboundEventCandidateCount: Int = 0,
        retainedOutboundEventCount: Int = 0,
        retention: LocalContextRetentionInfo = .init()
    ) {
        self.observedAt = observedAt
        self.source = source
        self.transmissionPolicy = transmissionPolicy
        self.privacyClassifications = privacyClassifications
        self.effectivePolicies = effectivePolicies
        self.observedStateCount = observedStateCount
        self.outboundStateCount = outboundStateCount
        self.internalEventHistoryCount = internalEventHistoryCount
        self.outboundEventCandidateCount = outboundEventCandidateCount
        self.retainedOutboundEventCount = retainedOutboundEventCount
        self.retention = retention
    }
}

public struct LocalContextEffectivePolicy: Codable, Sendable, Hashable {
    public var path: String
    public var sensitivity: String
    public var requiredScope: String
    public var defaultTransmit: Bool
    public var effectiveTransmit: Bool
    public var hasOverride: Bool
    public var overridePath: String
    public var overrideTransmit: Bool?
    public var reason: String

    public init(
        path: String = "",
        sensitivity: String = "low",
        requiredScope: String = "context.low:read",
        defaultTransmit: Bool = false,
        effectiveTransmit: Bool = false,
        hasOverride: Bool = false,
        overridePath: String = "",
        overrideTransmit: Bool? = nil,
        reason: String = ""
    ) {
        self.path = path
        self.sensitivity = sensitivity
        self.requiredScope = requiredScope
        self.defaultTransmit = defaultTransmit
        self.effectiveTransmit = effectiveTransmit
        self.hasOverride = hasOverride
        self.overridePath = overridePath
        self.overrideTransmit = overrideTransmit
        self.reason = reason
    }

    // C# は null も書き出すため encodeIfPresent を使わない。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(sensitivity, forKey: .sensitivity)
        try container.encode(requiredScope, forKey: .requiredScope)
        try container.encode(defaultTransmit, forKey: .defaultTransmit)
        try container.encode(effectiveTransmit, forKey: .effectiveTransmit)
        try container.encode(hasOverride, forKey: .hasOverride)
        try container.encode(overridePath, forKey: .overridePath)
        try container.encode(overrideTransmit, forKey: .overrideTransmit)
        try container.encode(reason, forKey: .reason)
    }
}

public struct LocalContextEvent: Codable, Sendable, Hashable {
    public var id: String
    public var sequence: Int64
    public var observedAt: Date
    public var name: String
    public var value: String
    public var payload: CaseInsensitiveDictionary<String>
    public var sensitivity: String
    /// payload キーごとの機微度。ingest 時に privacyClassifications から導出される。
    /// 該当 classification が無いキーは event-level sensitivity を継承する。
    /// 古い events.jsonl から復元した場合は空になり、フィルタは event-level にフォールバックする。
    public var payloadSensitivity: CaseInsensitiveDictionary<String>
    /// event-level sensitivity と payload キー機微度のうち最も高いもの。
    /// 空文字列の場合は sensitivity を参照する。
    public var maxFieldSensitivity: String

    public init(
        id: String = "",
        sequence: Int64 = 0,
        observedAt: Date = Date(timeIntervalSince1970: 0),
        name: String = "",
        value: String = "",
        payload: CaseInsensitiveDictionary<String> = [:],
        sensitivity: String = "low",
        payloadSensitivity: CaseInsensitiveDictionary<String> = [:],
        maxFieldSensitivity: String = ""
    ) {
        self.id = id
        self.sequence = sequence
        self.observedAt = observedAt
        self.name = name
        self.value = value
        self.payload = payload
        self.sensitivity = sensitivity
        self.payloadSensitivity = payloadSensitivity
        self.maxFieldSensitivity = maxFieldSensitivity
    }

    // 旧スキーマの events.jsonl (payloadSensitivity / maxFieldSensitivity なし) も読めるようにする。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        sequence = try container.decodeIfPresent(Int64.self, forKey: .sequence) ?? 0
        observedAt = try container.decodeIfPresent(Date.self, forKey: .observedAt)
            ?? Date(timeIntervalSince1970: 0)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        payload = try container.decodeIfPresent(CaseInsensitiveDictionary<String>.self, forKey: .payload) ?? [:]
        sensitivity = try container.decodeIfPresent(String.self, forKey: .sensitivity) ?? "low"
        payloadSensitivity = try container.decodeIfPresent(
            CaseInsensitiveDictionary<String>.self, forKey: .payloadSensitivity) ?? [:]
        maxFieldSensitivity = try container.decodeIfPresent(String.self, forKey: .maxFieldSensitivity) ?? ""
    }
}

public struct LocalContextRetentionInfo: Codable, Sendable, Hashable {
    public var maxAgeHours: Int
    public var maxEvents: Int

    public init(maxAgeHours: Int = 24, maxEvents: Int = 500) {
        self.maxAgeHours = maxAgeHours
        self.maxEvents = maxEvents
    }
}

public struct LocalContextEventSchemasResponse: Codable, Sendable {
    public var source: String
    public var events: [EventSchema]

    public init(source: String = "eventSchemaCatalog", events: [EventSchema] = []) {
        self.source = source
        self.events = events
    }
}
