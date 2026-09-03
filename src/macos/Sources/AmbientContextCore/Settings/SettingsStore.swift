import Foundation

/// C# の `ISettingsStore` 相当。
public protocol SettingsStore: AnyObject, Sendable {
    var settingsPath: String { get }

    func loadAmbientTransmissionSettings() -> AmbientTransmissionSettings
    func saveAmbientTransmissionSettings(_ settings: AmbientTransmissionSettings)

    func loadLocalContextSettings() -> LocalContextSettings
    func saveLocalContextSettings(_ settings: LocalContextSettings)

    func loadMcpServerSettings() -> McpServerSettings
    func saveMcpServerSettings(_ settings: McpServerSettings)

    func loadSettingsWindowStatus() -> SettingsWindowStatus?
    func saveSettingsWindowStatus(_ status: SettingsWindowStatus)

    func loadUiSettings() -> UiSettings
    func saveUiSettings(_ settings: UiSettings)

    func loadTransientStateSettings() -> TransientStateSettings
    func saveTransientStateSettings(_ settings: TransientStateSettings)
}
