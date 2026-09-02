import Foundation

/// イベント単位の payload スキーマを記述する。`ambient_context_describe_events` ツール経由で
/// クライアントが「フォアグラウンドアプリ切替 (foreground_changed) の payload には何が入るか」
/// 「media_session_changed の title は高機微か」などを 1 回で参照できるようにする。
public struct EventSchema: Codable, Sendable, Hashable {
    public var name: String
    public var sensitivity: String
    public var description: String
    public var payloadKeys: [EventPayloadKey]

    public init(
        name: String = "",
        sensitivity: String = "low",
        description: String = "",
        payloadKeys: [EventPayloadKey] = []
    ) {
        self.name = name
        self.sensitivity = sensitivity
        self.description = description
        self.payloadKeys = payloadKeys
    }
}

public struct EventPayloadKey: Codable, Sendable, Hashable {
    public var key: String
    public var sensitivity: String
    public var description: String
    public var example: String

    public init(
        key: String = "",
        sensitivity: String = "low",
        description: String = "",
        example: String = ""
    ) {
        self.key = key
        self.sensitivity = sensitivity
        self.description = description
        self.example = example
    }
}
