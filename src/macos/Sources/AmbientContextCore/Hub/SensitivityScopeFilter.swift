import Foundation

public enum SensitivityScopeFilter {
    public static func isSensitivityAllowed(_ sensitivity: String, scopes: [String]) -> Bool {
        getSensitivityLevel(sensitivity) <= getAllowedLevel(scopes)
    }

    public static func normalizeSensitivity(_ sensitivity: String) -> String {
        switch sensitivity.lowercased() {
        case "high": return "high"
        case "medium": return "medium"
        default: return "low"
        }
    }

    /// `events.<eventName>.<payloadKey>` の完全一致を探し、無ければ最長一致の親 path を、
    /// それも無ければ event-level の fallback を返す。
    public static func lookupPayloadFieldSensitivity(
        eventName: String,
        payloadKey: String,
        classifications: [PrivacyClassification],
        fallbackSensitivity: String
    ) -> String {
        let keyPath = "events.\(eventName).\(payloadKey)"

        for item in classifications where item.path.lowercased() == keyPath.lowercased() {
            return normalizeSensitivity(item.sensitivity)
        }

        var bestParent: PrivacyClassification?
        for item in classifications {
            let prefix = (item.path + ".").lowercased()
            if keyPath.lowercased().hasPrefix(prefix),
               bestParent == nil || item.path.count > bestParent!.path.count {
                bestParent = item
            }
        }

        if let bestParent {
            return normalizeSensitivity(bestParent.sensitivity)
        }
        return normalizeSensitivity(fallbackSensitivity)
    }

    public static func computePayloadSensitivity(
        eventName: String,
        payload: CaseInsensitiveDictionary<String>,
        classifications: [PrivacyClassification],
        eventSensitivity: String
    ) -> (perKey: CaseInsensitiveDictionary<String>, max: String) {
        var perKey = CaseInsensitiveDictionary<String>()
        var maxLevel = getSensitivityLevel(eventSensitivity)

        for key in payload.keys {
            let fieldSensitivity = lookupPayloadFieldSensitivity(
                eventName: eventName,
                payloadKey: key,
                classifications: classifications,
                fallbackSensitivity: eventSensitivity)
            perKey[key] = fieldSensitivity

            let level = getSensitivityLevel(fieldSensitivity)
            if level > maxLevel {
                maxLevel = level
            }
        }

        return (perKey, levelToSensitivity(maxLevel))
    }

    /// scope に収まらないイベントは nil、payload キー単位で超過するものだけ落としたイベントを返す。
    public static func filterEventForScope(
        _ event: LocalContextEvent,
        scopes: [String]
    ) -> LocalContextEvent? {
        let allowedLevel = getAllowedLevel(scopes)

        if getSensitivityLevel(event.sensitivity) > allowedLevel {
            return nil
        }

        if event.maxFieldSensitivity.isEmpty ||
            getSensitivityLevel(event.maxFieldSensitivity) <= allowedLevel {
            return event
        }

        var filteredPayload = CaseInsensitiveDictionary<String>()
        var filteredSensitivity = CaseInsensitiveDictionary<String>()
        var maxLevel = getSensitivityLevel(event.sensitivity)

        for pair in event.payload {
            let fieldSensitivity = event.payloadSensitivity[pair.key] ?? event.sensitivity
            if getSensitivityLevel(fieldSensitivity) > allowedLevel {
                continue
            }

            filteredPayload[pair.key] = pair.value
            filteredSensitivity[pair.key] = fieldSensitivity
            let level = getSensitivityLevel(fieldSensitivity)
            if level > maxLevel {
                maxLevel = level
            }
        }

        return LocalContextEvent(
            id: event.id,
            sequence: event.sequence,
            observedAt: event.observedAt,
            name: event.name,
            value: event.value,
            payload: filteredPayload,
            sensitivity: event.sensitivity,
            payloadSensitivity: filteredSensitivity,
            maxFieldSensitivity: levelToSensitivity(maxLevel))
    }

    private static func getSensitivityLevel(_ sensitivity: String) -> Int {
        switch normalizeSensitivity(sensitivity) {
        case "high": return 3
        case "medium": return 2
        default: return 1
        }
    }

    private static func levelToSensitivity(_ level: Int) -> String {
        switch level {
        case 3: return "high"
        case 2: return "medium"
        default: return "low"
        }
    }

    private static func getAllowedLevel(_ scopes: [String]) -> Int {
        let normalized = scopes.map { $0.lowercased() }
        if normalized.contains("context.high:read") || normalized.contains("context.all:read") {
            return 3
        }
        if normalized.contains("context.medium:read") {
            return 2
        }
        return 1
    }
}
