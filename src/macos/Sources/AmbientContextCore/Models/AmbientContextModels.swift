import Foundation

// C# 版 AmbientContextMcp.Core/Models/AmbientContextModels.cs の 1:1 移植。
// JSON のキー名は Swift のプロパティ名がそのまま camelCase なので、
// keyEncodingStrategy を使わず合成 CodingKeys をそのまま使う (= C# と同一キー)。

public struct AmbientContextSnapshot: Codable, Sendable {
    public var schemaVersion: Int
    public var observedAt: Date
    public var source: String
    public var presence: PresenceContext
    public var foregroundApp: ForegroundAppContext
    public var battery: BatteryContext
    public var network: NetworkContext
    public var media: MediaContext
    public var power: PowerContext
    public var system: SystemContext
    public var systemLoad: SystemLoadContext
    public var activity: ActivityContext
    public var wellness: WellnessContext
    public var displays: [DisplayContext]
    public var recentEvents: [AmbientEvent]
    public var states: [AmbientState]
    public var events: [AmbientOutboundEvent]
    public var outboundStates: [AmbientState]
    public var outboundEvents: [AmbientOutboundEvent]
    public var privacyClassifications: [PrivacyClassification]
    public var transmissionPolicy: AmbientTransmissionPolicySnapshot

    public init(
        schemaVersion: Int = 2,
        observedAt: Date = Date(timeIntervalSince1970: 0),
        source: String = "macos-desktop",
        presence: PresenceContext = .init(),
        foregroundApp: ForegroundAppContext = .init(),
        battery: BatteryContext = .init(),
        network: NetworkContext = .init(),
        media: MediaContext = .init(),
        power: PowerContext = .init(),
        system: SystemContext = .init(),
        systemLoad: SystemLoadContext = .init(),
        activity: ActivityContext = .init(),
        wellness: WellnessContext = .init(),
        displays: [DisplayContext] = [],
        recentEvents: [AmbientEvent] = [],
        states: [AmbientState] = [],
        events: [AmbientOutboundEvent] = [],
        outboundStates: [AmbientState] = [],
        outboundEvents: [AmbientOutboundEvent] = [],
        privacyClassifications: [PrivacyClassification] = [],
        transmissionPolicy: AmbientTransmissionPolicySnapshot = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.observedAt = observedAt
        self.source = source
        self.presence = presence
        self.foregroundApp = foregroundApp
        self.battery = battery
        self.network = network
        self.media = media
        self.power = power
        self.system = system
        self.systemLoad = systemLoad
        self.activity = activity
        self.wellness = wellness
        self.displays = displays
        self.recentEvents = recentEvents
        self.states = states
        self.events = events
        self.outboundStates = outboundStates
        self.outboundEvents = outboundEvents
        self.privacyClassifications = privacyClassifications
        self.transmissionPolicy = transmissionPolicy
    }
}

public struct PresenceContext: Codable, Sendable, Hashable {
    public var idleSeconds: Int?
    public var bucket: String
    public var sessionLocked: Bool

    public init(idleSeconds: Int? = nil, bucket: String = "unknown", sessionLocked: Bool = false) {
        self.idleSeconds = idleSeconds
        self.bucket = bucket
        self.sessionLocked = sessionLocked
    }

    // C# は null も書き出すため encodeIfPresent を使わない。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(idleSeconds, forKey: .idleSeconds)
        try container.encode(bucket, forKey: .bucket)
        try container.encode(sessionLocked, forKey: .sessionLocked)
    }
}

public struct ForegroundAppContext: Codable, Sendable, Hashable {
    public var processName: String
    public var processId: Int?
    public var appName: String
    public var category: String
    public var hasWindowTitle: Bool
    public var rawWindowTitle: String
    public var titleSummary: CaseInsensitiveDictionary<String>

    public init(
        processName: String = "",
        processId: Int? = nil,
        appName: String = "",
        category: String = "",
        hasWindowTitle: Bool = false,
        rawWindowTitle: String = "",
        titleSummary: CaseInsensitiveDictionary<String> = [:]
    ) {
        self.processName = processName
        self.processId = processId
        self.appName = appName
        self.category = category
        self.hasWindowTitle = hasWindowTitle
        self.rawWindowTitle = rawWindowTitle
        self.titleSummary = titleSummary
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(processName, forKey: .processName)
        try container.encode(processId, forKey: .processId)
        try container.encode(appName, forKey: .appName)
        try container.encode(category, forKey: .category)
        try container.encode(hasWindowTitle, forKey: .hasWindowTitle)
        try container.encode(rawWindowTitle, forKey: .rawWindowTitle)
        try container.encode(titleSummary, forKey: .titleSummary)
    }
}

public struct BatteryContext: Codable, Sendable, Hashable {
    public var present: Bool
    public var percent: Int?
    public var charging: Bool?
    public var onAcPower: Bool?
    public var batterySaver: Bool?
    public var bucket: String

    public init(
        present: Bool = false,
        percent: Int? = nil,
        charging: Bool? = nil,
        onAcPower: Bool? = nil,
        batterySaver: Bool? = nil,
        bucket: String = "unknown"
    ) {
        self.present = present
        self.percent = percent
        self.charging = charging
        self.onAcPower = onAcPower
        self.batterySaver = batterySaver
        self.bucket = bucket
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(present, forKey: .present)
        try container.encode(percent, forKey: .percent)
        try container.encode(charging, forKey: .charging)
        try container.encode(onAcPower, forKey: .onAcPower)
        try container.encode(batterySaver, forKey: .batterySaver)
        try container.encode(bucket, forKey: .bucket)
    }
}

public struct NetworkContext: Codable, Sendable, Hashable {
    public var isAvailable: Bool
    public var interfaceKinds: [String]

    public init(isAvailable: Bool = false, interfaceKinds: [String] = []) {
        self.isAvailable = isAvailable
        self.interfaceKinds = interfaceKinds
    }
}

public struct MediaContext: Codable, Sendable, Hashable {
    public var isAvailable: Bool
    public var sourceAppUserModelId: String
    public var playbackStatus: String
    public var isPlaying: Bool?
    public var title: String
    public var artist: String
    public var albumTitle: String
    public var albumArtist: String
    public var trackNumber: Int
    public var genres: [String]
    public var positionMilliseconds: Int64?
    public var startTimeMilliseconds: Int64?
    public var endTimeMilliseconds: Int64?
    public var timelineLastUpdatedAt: Date?
    public var sessions: [MediaSessionContext]
    public var error: String

    public init(
        isAvailable: Bool = false,
        sourceAppUserModelId: String = "",
        playbackStatus: String = "unknown",
        isPlaying: Bool? = nil,
        title: String = "",
        artist: String = "",
        albumTitle: String = "",
        albumArtist: String = "",
        trackNumber: Int = 0,
        genres: [String] = [],
        positionMilliseconds: Int64? = nil,
        startTimeMilliseconds: Int64? = nil,
        endTimeMilliseconds: Int64? = nil,
        timelineLastUpdatedAt: Date? = nil,
        sessions: [MediaSessionContext] = [],
        error: String = ""
    ) {
        self.isAvailable = isAvailable
        self.sourceAppUserModelId = sourceAppUserModelId
        self.playbackStatus = playbackStatus
        self.isPlaying = isPlaying
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.albumArtist = albumArtist
        self.trackNumber = trackNumber
        self.genres = genres
        self.positionMilliseconds = positionMilliseconds
        self.startTimeMilliseconds = startTimeMilliseconds
        self.endTimeMilliseconds = endTimeMilliseconds
        self.timelineLastUpdatedAt = timelineLastUpdatedAt
        self.sessions = sessions
        self.error = error
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isAvailable, forKey: .isAvailable)
        try container.encode(sourceAppUserModelId, forKey: .sourceAppUserModelId)
        try container.encode(playbackStatus, forKey: .playbackStatus)
        try container.encode(isPlaying, forKey: .isPlaying)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(albumTitle, forKey: .albumTitle)
        try container.encode(albumArtist, forKey: .albumArtist)
        try container.encode(trackNumber, forKey: .trackNumber)
        try container.encode(genres, forKey: .genres)
        try container.encode(positionMilliseconds, forKey: .positionMilliseconds)
        try container.encode(startTimeMilliseconds, forKey: .startTimeMilliseconds)
        try container.encode(endTimeMilliseconds, forKey: .endTimeMilliseconds)
        try container.encode(timelineLastUpdatedAt, forKey: .timelineLastUpdatedAt)
        try container.encode(sessions, forKey: .sessions)
        try container.encode(error, forKey: .error)
    }
}

public struct MediaSessionContext: Codable, Sendable, Hashable {
    public var selected: Bool
    public var sourceAppUserModelId: String
    public var playbackStatus: String
    public var isPlaying: Bool
    public var title: String
    public var artist: String
    public var albumTitle: String
    public var positionMilliseconds: Int64?
    public var endTimeMilliseconds: Int64?
    public var error: String

    public init(
        selected: Bool = false,
        sourceAppUserModelId: String = "",
        playbackStatus: String = "unknown",
        isPlaying: Bool = false,
        title: String = "",
        artist: String = "",
        albumTitle: String = "",
        positionMilliseconds: Int64? = nil,
        endTimeMilliseconds: Int64? = nil,
        error: String = ""
    ) {
        self.selected = selected
        self.sourceAppUserModelId = sourceAppUserModelId
        self.playbackStatus = playbackStatus
        self.isPlaying = isPlaying
        self.title = title
        self.artist = artist
        self.albumTitle = albumTitle
        self.positionMilliseconds = positionMilliseconds
        self.endTimeMilliseconds = endTimeMilliseconds
        self.error = error
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selected, forKey: .selected)
        try container.encode(sourceAppUserModelId, forKey: .sourceAppUserModelId)
        try container.encode(playbackStatus, forKey: .playbackStatus)
        try container.encode(isPlaying, forKey: .isPlaying)
        try container.encode(title, forKey: .title)
        try container.encode(artist, forKey: .artist)
        try container.encode(albumTitle, forKey: .albumTitle)
        try container.encode(positionMilliseconds, forKey: .positionMilliseconds)
        try container.encode(endTimeMilliseconds, forKey: .endTimeMilliseconds)
        try container.encode(error, forKey: .error)
    }
}

public struct PowerContext: Codable, Sendable, Hashable {
    public var lastKnownSettings: CaseInsensitiveDictionary<String>
    public var lastPowerSettingEvent: AmbientEvent?

    public init(
        lastKnownSettings: CaseInsensitiveDictionary<String> = [:],
        lastPowerSettingEvent: AmbientEvent? = nil
    ) {
        self.lastKnownSettings = lastKnownSettings
        self.lastPowerSettingEvent = lastPowerSettingEvent
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lastKnownSettings, forKey: .lastKnownSettings)
        try container.encode(lastPowerSettingEvent, forKey: .lastPowerSettingEvent)
    }
}

public struct SystemContext: Codable, Sendable, Hashable {
    public var timeZoneId: String
    public var utcOffsetMinutes: Int
    public var uptimeSeconds: Int64
    public var is64BitOperatingSystem: Bool
    public var processArchitecture: String

    public init(
        timeZoneId: String = "",
        utcOffsetMinutes: Int = 0,
        uptimeSeconds: Int64 = 0,
        is64BitOperatingSystem: Bool = false,
        processArchitecture: String = ""
    ) {
        self.timeZoneId = timeZoneId
        self.utcOffsetMinutes = utcOffsetMinutes
        self.uptimeSeconds = uptimeSeconds
        self.is64BitOperatingSystem = is64BitOperatingSystem
        self.processArchitecture = processArchitecture
    }
}

public struct SystemLoadContext: Codable, Sendable, Hashable {
    public var cpuUsagePercent: Int?
    public var cpuPressureBucket: String
    public var memoryUsedPercent: Int?
    public var memoryPressureBucket: String

    public init(
        cpuUsagePercent: Int? = nil,
        cpuPressureBucket: String = "unknown",
        memoryUsedPercent: Int? = nil,
        memoryPressureBucket: String = "unknown"
    ) {
        self.cpuUsagePercent = cpuUsagePercent
        self.cpuPressureBucket = cpuPressureBucket
        self.memoryUsedPercent = memoryUsedPercent
        self.memoryPressureBucket = memoryPressureBucket
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cpuUsagePercent, forKey: .cpuUsagePercent)
        try container.encode(cpuPressureBucket, forKey: .cpuPressureBucket)
        try container.encode(memoryUsedPercent, forKey: .memoryUsedPercent)
        try container.encode(memoryPressureBucket, forKey: .memoryPressureBucket)
    }
}

public struct ActivityContext: Codable, Sendable, Hashable {
    public var contextSwitchesPerMin: Int

    public init(contextSwitchesPerMin: Int = 0) {
        self.contextSwitchesPerMin = contextSwitchesPerMin
    }
}

public struct WellnessContext: Codable, Sendable, Hashable {
    public var continuousActiveMinutes: Int
    public var minutesSinceLastBreak: Int

    public init(continuousActiveMinutes: Int = 0, minutesSinceLastBreak: Int = 0) {
        self.continuousActiveMinutes = continuousActiveMinutes
        self.minutesSinceLastBreak = minutesSinceLastBreak
    }
}

public struct DisplayContext: Codable, Sendable, Hashable {
    public var deviceName: String
    public var primary: Bool
    public var left: Int
    public var top: Int
    public var width: Int
    public var height: Int
    public var workAreaLeft: Int
    public var workAreaTop: Int
    public var workAreaWidth: Int
    public var workAreaHeight: Int
    public var bitsPerPixel: Int

    public init(
        deviceName: String = "",
        primary: Bool = false,
        left: Int = 0,
        top: Int = 0,
        width: Int = 0,
        height: Int = 0,
        workAreaLeft: Int = 0,
        workAreaTop: Int = 0,
        workAreaWidth: Int = 0,
        workAreaHeight: Int = 0,
        bitsPerPixel: Int = 0
    ) {
        self.deviceName = deviceName
        self.primary = primary
        self.left = left
        self.top = top
        self.width = width
        self.height = height
        self.workAreaLeft = workAreaLeft
        self.workAreaTop = workAreaTop
        self.workAreaWidth = workAreaWidth
        self.workAreaHeight = workAreaHeight
        self.bitsPerPixel = bitsPerPixel
    }
}

public struct AmbientEvent: Codable, Sendable, Hashable {
    public var observedAt: Date
    public var kind: String
    public var sensitivity: String
    public var initializationOnly: Bool
    public var data: CaseInsensitiveDictionary<String>

    public init(
        observedAt: Date = Date(timeIntervalSince1970: 0),
        kind: String = "",
        sensitivity: String = "low",
        initializationOnly: Bool = false,
        data: CaseInsensitiveDictionary<String> = [:]
    ) {
        self.observedAt = observedAt
        self.kind = kind
        self.sensitivity = sensitivity
        self.initializationOnly = initializationOnly
        self.data = data
    }
}

public struct AmbientState: Codable, Sendable, Hashable {
    public var observedAt: Date
    public var name: String
    public var value: String
    public var sensitivity: String

    public init(
        observedAt: Date = Date(timeIntervalSince1970: 0),
        name: String = "",
        value: String = "",
        sensitivity: String = "low"
    ) {
        self.observedAt = observedAt
        self.name = name
        self.value = value
        self.sensitivity = sensitivity
    }
}

public struct AmbientOutboundEvent: Codable, Sendable, Hashable {
    public var observedAt: Date
    public var name: String
    public var value: String
    public var payload: CaseInsensitiveDictionary<String>
    public var sensitivity: String

    public init(
        observedAt: Date = Date(timeIntervalSince1970: 0),
        name: String = "",
        value: String = "",
        payload: CaseInsensitiveDictionary<String> = [:],
        sensitivity: String = "low"
    ) {
        self.observedAt = observedAt
        self.name = name
        self.value = value
        self.payload = payload
        self.sensitivity = sensitivity
    }
}

public struct PrivacyClassification: Codable, Sendable, Hashable {
    public var path: String
    public var sensitivity: String
    public var defaultTransmit: Bool
    public var reason: String

    public init(
        path: String = "",
        sensitivity: String = "low",
        defaultTransmit: Bool = false,
        reason: String = ""
    ) {
        self.path = path
        self.sensitivity = sensitivity
        self.defaultTransmit = defaultTransmit
        self.reason = reason
    }
}

public struct AmbientTransmissionPolicySnapshot: Codable, Sendable, Hashable {
    public var settingsPath: String
    public var explicitOverrideCount: Int
    public var defaultBehavior: String
    public var pathTransmitOverrides: CaseInsensitiveDictionary<Bool>

    public init(
        settingsPath: String = "",
        explicitOverrideCount: Int = 0,
        defaultBehavior: String = "privacyClassifications.defaultTransmit",
        pathTransmitOverrides: CaseInsensitiveDictionary<Bool> = [:]
    ) {
        self.settingsPath = settingsPath
        self.explicitOverrideCount = explicitOverrideCount
        self.defaultBehavior = defaultBehavior
        self.pathTransmitOverrides = pathTransmitOverrides
    }
}
