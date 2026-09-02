import Foundation
@testable import AmbientContextCore

/// C# `LocalContextHubTestFactory` の移植。
enum LocalContextHubTestFactory {
    static func createInMemory() -> LocalContextHub {
        LocalContextHub(settingsStore: InMemorySettingsStore(persistEventLog: false), language: "en")
    }

    static func createWithPersistentLog(settingsPath: String) -> LocalContextHub {
        LocalContextHub(
            settingsStore: InMemorySettingsStore(
                persistEventLog: true, overrideSettingsPath: settingsPath),
            language: "en")
    }
}

final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private let persistEventLog: Bool
    private let transmissionSettings: AmbientTransmissionSettings

    let settingsPath: String

    init(
        persistEventLog: Bool,
        overrideSettingsPath: String? = nil,
        transmissionSettings: AmbientTransmissionSettings = .init()
    ) {
        self.persistEventLog = persistEventLog
        self.transmissionSettings = transmissionSettings
        self.settingsPath = overrideSettingsPath ?? TempPaths.uniqueSettingsPath()
    }

    func loadAmbientTransmissionSettings() -> AmbientTransmissionSettings { transmissionSettings }
    func saveAmbientTransmissionSettings(_ settings: AmbientTransmissionSettings) {}

    func loadLocalContextSettings() -> LocalContextSettings {
        LocalContextSettings(persistEventLog: persistEventLog)
    }
    func saveLocalContextSettings(_ settings: LocalContextSettings) {}

    func loadMcpServerSettings() -> McpServerSettings { McpServerSettings() }
    func saveMcpServerSettings(_ settings: McpServerSettings) {}

    func loadSettingsWindowStatus() -> SettingsWindowStatus? { nil }
    func saveSettingsWindowStatus(_ status: SettingsWindowStatus) {}

    func loadUiSettings() -> UiSettings { UiSettings() }
    func saveUiSettings(_ settings: UiSettings) {}

    func loadTransientStateSettings() -> TransientStateSettings { TransientStateSettings() }
    func saveTransientStateSettings(_ settings: TransientStateSettings) {}
}

enum TempPaths {
    static func uniqueSettingsPath() -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ambient-context-mcp-test/\(UUID().uuidString).json")
    }
}

/// テストごとに固有の一時ディレクトリを作り、破棄時に消す。
final class TempDirectory {
    let path: String

    init() {
        path = (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("ambient-context-mcp-test/\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    deinit {
        // テストの後片付けで失敗してもアサーション結果には影響させない
        try? FileManager.default.removeItem(atPath: path)
    }

    func file(_ name: String) -> String {
        (path as NSString).appendingPathComponent(name)
    }
}

extension CaseInsensitiveDictionary where Value == String {
    static func from(_ pairs: [(String, String)]) -> CaseInsensitiveDictionary<String> {
        CaseInsensitiveDictionary(pairs)
    }
}
