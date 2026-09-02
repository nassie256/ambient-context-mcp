import Foundation

/// path 単位の送信可否を決めるポリシー。設定の override → classification の defaultTransmit の順で判定する。
public struct AmbientTransmissionPolicy: Sendable {
    private let settings: AmbientTransmissionSettings
    private let settingsPathValue: String

    private init(settings: AmbientTransmissionSettings, settingsPath: String) {
        self.settings = settings
        self.settingsPathValue = settingsPath
    }

    public var snapshot: AmbientTransmissionPolicySnapshot {
        AmbientTransmissionPolicySnapshot(
            settingsPath: settingsPathValue,
            explicitOverrideCount: settings.pathTransmitOverrides.count,
            pathTransmitOverrides: settings.pathTransmitOverrides)
    }

    public static func load(
        store: any SettingsStore,
        privacyClassifications: [PrivacyClassification]
    ) -> AmbientTransmissionPolicy {
        let raw = store.loadAmbientTransmissionSettings()
        let cleansed = AmbientTransmissionSettings(
            schemaVersion: raw.schemaVersion,
            pathTransmitOverrides: cleanseOverrides(raw.pathTransmitOverrides, privacyClassifications))
        return AmbientTransmissionPolicy(settings: cleansed, settingsPath: store.settingsPath)
    }

    public static func save(
        store: any SettingsStore,
        settings: AmbientTransmissionSettings,
        privacyClassifications: [PrivacyClassification]
    ) {
        store.saveAmbientTransmissionSettings(AmbientTransmissionSettings(
            schemaVersion: 1,
            pathTransmitOverrides: cleanseOverrides(settings.pathTransmitOverrides, privacyClassifications)))
    }

    public func filterStates(
        _ states: [AmbientState],
        privacyClassifications: [PrivacyClassification]
    ) -> [AmbientState] {
        states.filter { isAllowed($0.name, privacyClassifications) }
    }

    public func filterEvents(
        _ events: [AmbientOutboundEvent],
        privacyClassifications: [PrivacyClassification]
    ) -> [AmbientOutboundEvent] {
        var result: [AmbientOutboundEvent] = []
        for item in events {
            let eventPath = "events." + item.name
            guard isAllowed(eventPath, privacyClassifications) else { continue }

            // event 本体が許可されたら、payload キーを 1 つずつフィルタする。
            // 高機微キー (例: events.media_session_changed.title) は親 event を ON にしただけでは流さず、
            // 個別の opt-in を要求する設計。
            var filtered = CaseInsensitiveDictionary<String>()
            for pair in item.payload {
                let keyPath = "\(eventPath).\(pair.key)"
                if isPayloadKeyAllowed(keyPath, privacyClassifications) {
                    filtered[pair.key] = pair.value
                }
            }

            result.append(AmbientOutboundEvent(
                observedAt: item.observedAt,
                name: item.name,
                value: item.value,
                payload: filtered,
                sensitivity: item.sensitivity))
        }
        return result
    }

    private func isAllowed(_ path: String, _ privacyClassifications: [PrivacyClassification]) -> Bool {
        if let allowed = tryGetOverride(path) {
            return allowed
        }
        return Self.findClassification(path, privacyClassifications)?.defaultTransmit ?? false
    }

    /// payload キーの送信可否を判定する。
    /// 1. 自身に明示 override があれば最優先 (親 event の override を継承させない)。
    /// 2. 自身に明示 classification があれば defaultTransmit を採用する。
    ///    高機微 payload (例: events.media_session_changed.title) はここで弾かれる。
    /// 3. それ以外は親 event の許可状態を継承する。
    ///    source_app / playback_status のような平常 payload キーは event を ON にしただけで流れる。
    private func isPayloadKeyAllowed(
        _ path: String,
        _ privacyClassifications: [PrivacyClassification]
    ) -> Bool {
        if let explicitOverride = settings.pathTransmitOverrides[path] {
            return explicitOverride
        }

        if let explicitClass = privacyClassifications.first(where: {
            $0.path.lowercased() == path.lowercased()
        }) {
            return explicitClass.defaultTransmit
        }

        guard let lastDot = path.lastIndex(of: ".") else { return false }
        return isAllowed(String(path[path.startIndex..<lastDot]), privacyClassifications)
    }

    private func tryGetOverride(_ path: String) -> Bool? {
        var current = path
        while !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let allowed = settings.pathTransmitOverrides[current] {
                return allowed
            }
            guard let lastDot = current.lastIndex(of: ".") else { break }
            current = String(current[current.startIndex..<lastDot])
        }
        return nil
    }

    private static func findClassification(
        _ path: String,
        _ privacyClassifications: [PrivacyClassification]
    ) -> PrivacyClassification? {
        // C# の OrderByDescending は安定ソートなので、同じ長さの path は元の並び順を保つ。
        privacyClassifications
            .enumerated()
            .sorted { lhs, rhs in
                lhs.element.path.count == rhs.element.path.count
                    ? lhs.offset < rhs.offset
                    : lhs.element.path.count > rhs.element.path.count
            }
            .map(\.element)
            .first {
                path.lowercased() == $0.path.lowercased() ||
                path.lowercased().hasPrefix(($0.path + ".").lowercased())
            }
    }

    /// 既知の `PrivacyClassification` path に一致しない override を捨てる。
    ///
    /// 例えば `"events"` のような親キー一括許可を弾く目的。override 解決は親方向に階層遡上して
    /// 一致を返すため、もし `"events" = true` が紛れ込むと全イベントが暗黙的に許可されてしまう。
    /// save / load 双方でこの cleanse を通すことで、手編集や旧スキーマからのアップグレードでも
    /// 不正 override が永続化されない。
    static func cleanseOverrides(
        _ overrides: CaseInsensitiveDictionary<Bool>,
        _ privacyClassifications: [PrivacyClassification]
    ) -> CaseInsensitiveDictionary<Bool> {
        let validPaths = Set(privacyClassifications.map { $0.path.lowercased() })
        var result = CaseInsensitiveDictionary<Bool>()
        for pair in overrides where validPaths.contains(pair.key.lowercased()) {
            result[pair.key] = pair.value
        }
        return result
    }
}
