import Foundation

/// 設定ダイアログ向けの送信オプション定義。MCP path は `TransmissionUiOptionDefinition.linkedPaths` に束ね、
/// UI では意味単位のチェックボックス 1 つで state + event を同時に opt-in する。
/// `primaryPath` は Load 時のチェック状態判定に使う (共有 path の誤表示を防ぐ)。
/// Save 時は ON オプションの linkedPaths の和集合を書き出す。
extension AmbientContextCatalog {
    public static func getTransmissionUiGroups(
        language: String = AmbientContextCatalog.defaultLanguage
    ) -> [TransmissionUiGroupDefinition] {
        var classifications = CaseInsensitiveDictionary<PrivacyClassification>()
        for item in getPrivacyClassifications(language: language) {
            classifications[item.path] = item
        }

        return [
            TransmissionUiGroupDefinition(id: "foregroundApp", options: [
                option("foreground.identity", "foregroundApp.category",
                       ["foregroundApp.category", "foregroundApp.appName", "foregroundApp.processName", "events.foreground_changed"],
                       classifications),
                option("foreground.titleSummary", "foregroundApp.titleSummary",
                       ["foregroundApp.titleSummary", "events.foreground_title_changed", "events.foreground_title_changed.titleSummary"],
                       classifications),
                option("foreground.rawTitle", "foregroundApp.rawWindowTitle",
                       ["foregroundApp.rawWindowTitle", "events.foreground_title_changed", "events.foreground_title_changed.raw_window_title"],
                       classifications)
            ]),
            TransmissionUiGroupDefinition(id: "activity", options: [
                option("activity.switchRate", "activity.contextSwitchesPerMin",
                       ["activity.contextSwitchesPerMin"], classifications),
                option("activity.switchBurst", "events.context_switch_burst",
                       ["events.context_switch_burst"], classifications)
            ]),
            TransmissionUiGroupDefinition(id: "media", options: [
                option("media.overview", "media.isAvailable",
                       ["media.isAvailable", "media.playbackStatus", "media.sourceAppUserModelId", "events.media_playback_started", "events.media_playback_paused", "events.media_session_changed"],
                       classifications),
                option("media.title", "media.title",
                       ["media.title", "events.media_session_changed", "events.media_session_changed.title"],
                       classifications),
                option("media.artist", "media.artist",
                       ["media.artist", "events.media_session_changed", "events.media_session_changed.artist"],
                       classifications),
                option("media.album", "media.albumTitle",
                       ["media.albumTitle", "events.media_session_changed", "events.media_session_changed.album_title"],
                       classifications)
            ]),
            TransmissionUiGroupDefinition(id: "environment", options: [
                option("environment.timezone", "system.timeZoneId",
                       ["system.timeZoneId", "events.timezone_changed"], classifications),
                option("environment.displays", "displays",
                       ["display.count", "displays", "events.display_count_changed"], classifications)
            ])
        ]
    }

    /// UI 定義から distinct な path 一覧をフラット化する。主にテストで
    /// linkedPaths が privacy catalog と整合していることを検証するために使う。
    public static func getTransmissionOptions(
        language: String = AmbientContextCatalog.defaultLanguage
    ) -> [TransmissionOptionDefinition] {
        var classifications = CaseInsensitiveDictionary<PrivacyClassification>()
        for item in getPrivacyClassifications(language: language) {
            classifications[item.path] = item
        }

        var seen = Set<String>()
        var result: [TransmissionOptionDefinition] = []
        for group in getTransmissionUiGroups(language: language) {
            for option in group.options {
                for path in option.linkedPaths where seen.insert(path.lowercased()).inserted {
                    guard let classification = classifications[path] else { continue }
                    result.append(TransmissionOptionDefinition(
                        path: classification.path,
                        sensitivity: classification.sensitivity))
                }
            }
        }
        return result
    }

    private static func option(
        _ id: String,
        _ primaryPath: String,
        _ linkedPaths: [String],
        _ classifications: CaseInsensitiveDictionary<PrivacyClassification>
    ) -> TransmissionUiOptionDefinition {
        precondition(
            linkedPaths.contains { $0.lowercased() == primaryPath.lowercased() },
            "PrimaryPath '\(primaryPath)' must be included in LinkedPaths for option '\(id)'.")

        return TransmissionUiOptionDefinition(
            id: id,
            primaryPath: primaryPath,
            sensitivity: resolveMaxSensitivity(linkedPaths, classifications),
            linkedPaths: linkedPaths)
    }

    private static func resolveMaxSensitivity(
        _ linkedPaths: [String],
        _ classifications: CaseInsensitiveDictionary<PrivacyClassification>
    ) -> String {
        var maxLevel = 0
        var result = "low"
        for path in linkedPaths {
            guard let sensitivity = classifications[path]?.sensitivity else { continue }
            let level = sensitivityLevel(sensitivity)
            if level > maxLevel {
                maxLevel = level
                result = sensitivity
            }
        }
        return result
    }

    private static func sensitivityLevel(_ sensitivity: String) -> Int {
        switch sensitivity.lowercased() {
        case "high": return 3
        case "medium": return 2
        default: return 1
        }
    }
}

public struct TransmissionUiGroupDefinition: Codable, Sendable, Hashable {
    public var id: String
    public var options: [TransmissionUiOptionDefinition]

    public init(id: String = "", options: [TransmissionUiOptionDefinition] = []) {
        self.id = id
        self.options = options
    }
}

public struct TransmissionUiOptionDefinition: Codable, Sendable, Hashable {
    public var id: String
    public var primaryPath: String
    public var sensitivity: String
    public var linkedPaths: [String]

    public init(
        id: String = "",
        primaryPath: String = "",
        sensitivity: String = "medium",
        linkedPaths: [String] = []
    ) {
        self.id = id
        self.primaryPath = primaryPath
        self.sensitivity = sensitivity
        self.linkedPaths = linkedPaths
    }
}
