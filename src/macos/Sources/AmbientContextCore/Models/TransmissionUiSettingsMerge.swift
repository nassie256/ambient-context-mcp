import Foundation

public enum TransmissionUiSettingsMerge {
    /// UI で ON のオプションが持つ LinkedPaths の和集合を override に反映する。
    /// UI が管理していない path (手編集の legacy override 等) はそのまま残す。
    public static func mergeOverrides(
        existingOverrides: CaseInsensitiveDictionary<Bool>,
        options: [TransmissionUiOptionDefinition],
        enabledOptionIds: Set<String>
    ) -> CaseInsensitiveDictionary<Bool> {
        var overrides = existingOverrides

        var managedPaths: [String] = []
        var seen = Set<String>()
        for option in options {
            for path in option.linkedPaths where seen.insert(path.lowercased()).inserted {
                managedPaths.append(path)
            }
        }

        let normalizedEnabledIds = Set(enabledOptionIds.map { $0.lowercased() })
        var allowedPaths = Set<String>()
        for option in options where normalizedEnabledIds.contains(option.id.lowercased()) {
            for path in option.linkedPaths {
                allowedPaths.insert(path.lowercased())
            }
        }

        for path in managedPaths {
            if allowedPaths.contains(path.lowercased()) {
                overrides[path] = true
            } else {
                overrides.removeValue(forKey: path)
            }
        }

        return overrides
    }

    public static func isOptionEnabled(
        primaryPath: String,
        overrides: CaseInsensitiveDictionary<Bool>
    ) -> Bool {
        overrides[primaryPath] == true
    }

    public static func isOptionEnabled(
        option: TransmissionUiOptionDefinition,
        overrides: CaseInsensitiveDictionary<Bool>
    ) -> Bool {
        isOptionEnabled(primaryPath: option.primaryPath, overrides: overrides)
    }
}
