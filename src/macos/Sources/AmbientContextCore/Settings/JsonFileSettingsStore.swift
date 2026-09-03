import Foundation

/// 統合 settings.json (`schemaVersion` / `mcpServer` / `ambientTransmission` / `localContext` /
/// `settingsWindow` / `ui` / `transientState`) を読み書きするストア。
///
/// - 読み込みはキーの大文字小文字を無視し、欠損セクションは既定値にフォールバックする
///   (C# の `PropertyNameCaseInsensitive = true` 相当)
/// - 書き込みは temp ファイル + rename でアトミックに行う
/// - 既定パスは `~/Library/Application Support/AmbientContextMcp/settings.json`
///   (Windows 版の `%LOCALAPPDATA%\AmbientContextMcp\settings.json` に対応)
public final class JsonFileSettingsStore: SettingsStore, @unchecked Sendable {
    private let lock = NSLock()
    private let path: String

    public init(path: String? = nil) {
        self.path = path ?? JsonFileSettingsStore.defaultPath
    }

    public var settingsPath: String { path }

    public static var defaultPath: String {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("AmbientContextMcp")
            .appendingPathComponent("settings.json")
            .path
    }

    // MARK: - ambientTransmission

    public func loadAmbientTransmissionSettings() -> AmbientTransmissionSettings {
        load().ambientTransmission ?? AmbientTransmissionSettings()
    }

    public func saveAmbientTransmissionSettings(_ settings: AmbientTransmissionSettings) {
        save { current in
            current.ambientTransmission = AmbientTransmissionSettings(
                schemaVersion: 1,
                pathTransmitOverrides: settings.pathTransmitOverrides)
        }
    }

    // MARK: - localContext

    public func loadLocalContextSettings() -> LocalContextSettings {
        load().localContext ?? LocalContextSettings()
    }

    public func saveLocalContextSettings(_ settings: LocalContextSettings) {
        save { $0.localContext = settings }
    }

    // MARK: - mcpServer

    public func loadMcpServerSettings() -> McpServerSettings {
        let settings = load().mcpServer
        if let settings, !settings.token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return settings
        }

        let port = (settings?.port).flatMap { $0 > 0 && $0 < 65536 ? $0 : nil } ?? 37690
        let created = McpServerSettings(
            schemaVersion: 1,
            autoStart: settings?.autoStart ?? false,
            port: port,
            token: JsonFileSettingsStore.createToken())
        saveMcpServerSettings(created)
        return created
    }

    public func saveMcpServerSettings(_ settings: McpServerSettings) {
        save { $0.mcpServer = settings }
    }

    // MARK: - settingsWindow

    public func loadSettingsWindowStatus() -> SettingsWindowStatus? {
        load().settingsWindow
    }

    public func saveSettingsWindowStatus(_ status: SettingsWindowStatus) {
        save { $0.settingsWindow = status }
    }

    // MARK: - ui

    public func loadUiSettings() -> UiSettings {
        load().ui ?? UiSettings()
    }

    public func saveUiSettings(_ settings: UiSettings) {
        save { $0.ui = settings }
    }

    // MARK: - transientState

    public func loadTransientStateSettings() -> TransientStateSettings {
        load().transientState ?? TransientStateSettings()
    }

    public func saveTransientStateSettings(_ settings: TransientStateSettings) {
        save { $0.transientState = settings }
    }

    // MARK: - internals

    private func load() -> UnifiedSettings {
        lock.lock()
        defer { lock.unlock() }
        return loadUnlocked()
    }

    private func save(_ update: (inout UnifiedSettings) -> Void) {
        lock.lock()
        defer { lock.unlock() }

        var settings = loadUnlocked()
        update(&settings)
        settings.schemaVersion = 1

        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        }

        guard let data = try? AmbientContextJson.encoder().encode(settings) else { return }
        let tempPath = path + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: tempPath), options: .atomic)
            if FileManager.default.fileExists(atPath: path) {
                _ = try FileManager.default.replaceItemAt(
                    URL(fileURLWithPath: path),
                    withItemAt: URL(fileURLWithPath: tempPath))
            } else {
                try FileManager.default.moveItem(atPath: tempPath, toPath: path)
            }
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
        }
    }

    private func loadUnlocked() -> UnifiedSettings {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else {
            return UnifiedSettings()
        }
        return UnifiedSettings(json: JsonObject(root))
    }

    static func createToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: UInt8.min...UInt8.max)
        }
        return Base64Url.encode(Data(bytes))
    }
}

/// キーの大文字小文字を無視して読める JSON オブジェクトのラッパ。
struct JsonObject {
    private let storage: [String: Any]

    init(_ raw: [String: Any]) {
        var normalized: [String: Any] = [:]
        for (key, value) in raw {
            normalized[key.lowercased()] = value
        }
        storage = normalized
    }

    func object(_ key: String) -> JsonObject? {
        guard let value = storage[key.lowercased()] as? [String: Any] else { return nil }
        return JsonObject(value)
    }

    func rawObject(_ key: String) -> [String: Any]? {
        storage[key.lowercased()] as? [String: Any]
    }

    func int(_ key: String) -> Int? {
        if let value = storage[key.lowercased()] as? NSNumber { return value.intValue }
        if let value = storage[key.lowercased()] as? String { return Int(value) }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let value = storage[key.lowercased()] as? NSNumber { return value.doubleValue }
        if let value = storage[key.lowercased()] as? String { return Double(value) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        if let value = storage[key.lowercased()] as? NSNumber { return value.boolValue }
        if let value = storage[key.lowercased()] as? String { return Bool(value) }
        return nil
    }

    func string(_ key: String) -> String? {
        storage[key.lowercased()] as? String
    }

    func has(_ key: String) -> Bool {
        storage[key.lowercased()] != nil
    }
}

/// settings.json のルート構造。出力順は C# の `UnifiedSettings` プロパティ順に合わせる。
struct UnifiedSettings: Encodable {
    var schemaVersion: Int = 1
    var mcpServer: McpServerSettings?
    var ambientTransmission: AmbientTransmissionSettings?
    var localContext: LocalContextSettings?
    var settingsWindow: SettingsWindowStatus?
    var ui: UiSettings?
    var transientState: TransientStateSettings?

    init() {}

    init(json: JsonObject) {
        schemaVersion = json.int("schemaVersion") ?? 1

        if let section = json.object("mcpServer") {
            mcpServer = McpServerSettings(
                schemaVersion: section.int("schemaVersion") ?? 1,
                autoStart: section.bool("autoStart") ?? false,
                port: section.int("port") ?? 37690,
                token: section.string("token") ?? "")
        }

        if let section = json.object("ambientTransmission") {
            var overrides = CaseInsensitiveDictionary<Bool>()
            if let raw = section.rawObject("pathTransmitOverrides") {
                // JSON オブジェクトの順序は保証されないので、キー昇順で安定化する。
                for key in raw.keys.sorted() {
                    if let value = raw[key] as? NSNumber {
                        overrides[key] = value.boolValue
                    } else if let value = raw[key] as? Bool {
                        overrides[key] = value
                    }
                }
            }
            ambientTransmission = AmbientTransmissionSettings(
                schemaVersion: section.int("schemaVersion") ?? 1,
                pathTransmitOverrides: overrides)
        }

        if let section = json.object("localContext") {
            localContext = LocalContextSettings(
                schemaVersion: section.int("schemaVersion") ?? 1,
                maxEventAgeHours: section.int("maxEventAgeHours") ?? 24,
                maxEventCount: section.int("maxEventCount") ?? 500,
                persistEventLog: section.bool("persistEventLog") ?? false)
        }

        if let section = json.object("settingsWindow") {
            settingsWindow = SettingsWindowStatus(
                schemaVersion: section.int("schemaVersion") ?? 1,
                left: section.double("left") ?? 0,
                top: section.double("top") ?? 0,
                width: section.double("width") ?? 560,
                height: section.double("height") ?? 460)
        }

        if let section = json.object("ui") {
            ui = UiSettings(
                schemaVersion: section.int("schemaVersion") ?? 1,
                language: section.string("language") ?? "")
        }

        if let section = json.object("transientState") {
            transientState = TransientStateSettings(
                schemaVersion: section.int("schemaVersion") ?? 1,
                lastActivityDate: section.string("lastActivityDate").flatMap { DateOnly($0) })
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, mcpServer, ambientTransmission, localContext, settingsWindow, ui, transientState
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(mcpServer, forKey: .mcpServer)
        try container.encode(ambientTransmission, forKey: .ambientTransmission)
        try container.encode(localContext, forKey: .localContext)
        try container.encode(settingsWindow, forKey: .settingsWindow)
        try container.encode(ui, forKey: .ui)
        try container.encode(transientState, forKey: .transientState)
    }
}

/// パディング無しの base64url。
public enum Base64Url {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
    }

    public static func decode(_ text: String) -> Data? {
        var padded = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = padded.count % 4
        if remainder > 0 {
            padded += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: padded)
    }
}
