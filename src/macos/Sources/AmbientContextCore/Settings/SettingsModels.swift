import Foundation

public struct AmbientTransmissionSettings: Encodable, Sendable, Hashable {
    public var schemaVersion: Int
    public var pathTransmitOverrides: CaseInsensitiveDictionary<Bool>

    public init(
        schemaVersion: Int = 1,
        pathTransmitOverrides: CaseInsensitiveDictionary<Bool> = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.pathTransmitOverrides = pathTransmitOverrides
    }
}

public struct LocalContextSettings: Encodable, Sendable, Hashable {
    public var schemaVersion: Int
    public var maxEventAgeHours: Int
    public var maxEventCount: Int
    /// 既定 false。true の場合、Hub のイベント履歴を settings.json と同じディレクトリの events.jsonl
    /// に追記し、再起動を跨いで保持期間内の履歴を保つ。送信ポリシーで許可された outbound イベントのみが保存される。
    public var persistEventLog: Bool

    public init(
        schemaVersion: Int = 1,
        maxEventAgeHours: Int = 24,
        maxEventCount: Int = 500,
        persistEventLog: Bool = false
    ) {
        self.schemaVersion = schemaVersion
        self.maxEventAgeHours = maxEventAgeHours
        self.maxEventCount = maxEventCount
        self.persistEventLog = persistEventLog
    }
}

public struct McpServerSettings: Encodable, Sendable, Hashable {
    public var schemaVersion: Int
    public var autoStart: Bool
    public var port: Int
    public var token: String

    public init(
        schemaVersion: Int = 1,
        autoStart: Bool = false,
        port: Int = 37690,
        token: String = ""
    ) {
        self.schemaVersion = schemaVersion
        self.autoStart = autoStart
        self.port = port
        self.token = token
    }
}

public struct SettingsWindowStatus: Encodable, Sendable, Hashable {
    public var schemaVersion: Int
    public var left: Double
    public var top: Double
    public var width: Double
    public var height: Double

    public init(
        schemaVersion: Int = 1,
        left: Double = 0,
        top: Double = 0,
        width: Double = 560,
        height: Double = 460
    ) {
        self.schemaVersion = schemaVersion
        self.left = left
        self.top = top
        self.width = width
        self.height = height
    }
}

public struct UiSettings: Encodable, Sendable, Hashable {
    public var schemaVersion: Int
    /// "" / null = OS の UI 言語を継承。"ja" / "en" = 明示指定。
    /// 起動時にカタログ (`PrivacyClassification.reason` など) とローカライズ文字列の言語を決める。
    public var language: String

    public init(schemaVersion: Int = 1, language: String = "") {
        self.schemaVersion = schemaVersion
        self.language = language
    }
}

/// プロセス再起動を跨いで保持すべき軽量なランタイム状態。ユーザー設定ではなく実行時に
/// サービス自身が読み書きする。意味的には「次の起動時にも記憶しておきたい一時状態」。
public struct TransientStateSettings: Encodable, Sendable, Hashable {
    public var schemaVersion: Int
    /// 最後に `first_activity_today` を発火したローカルカレンダー日。nil は未発火を意味する。
    public var lastActivityDate: DateOnly?

    public init(schemaVersion: Int = 1, lastActivityDate: DateOnly? = nil) {
        self.schemaVersion = schemaVersion
        self.lastActivityDate = lastActivityDate
    }
}

// 出力キーの並びは C# の各 Settings 型のプロパティ順に合わせる。
extension AmbientTransmissionSettings {
    enum CodingKeys: String, CodingKey { case schemaVersion, pathTransmitOverrides }
}

extension LocalContextSettings {
    enum CodingKeys: String, CodingKey { case schemaVersion, maxEventAgeHours, maxEventCount, persistEventLog }
}

extension McpServerSettings {
    enum CodingKeys: String, CodingKey { case schemaVersion, autoStart, port, token }
}

extension SettingsWindowStatus {
    enum CodingKeys: String, CodingKey { case schemaVersion, left, top, width, height }
}

extension UiSettings {
    enum CodingKeys: String, CodingKey { case schemaVersion, language }
}

extension TransientStateSettings {
    enum CodingKeys: String, CodingKey { case schemaVersion, lastActivityDate }

    // C# は null も書き出すため encodeIfPresent を使わない。
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(lastActivityDate, forKey: .lastActivityDate)
    }
}
