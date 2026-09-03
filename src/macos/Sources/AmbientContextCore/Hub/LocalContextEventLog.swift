import Foundation

/// イベント履歴の JSONL 永続化。1 行 1 イベントで grep / tail しやすくするため非整形で書き出す。
/// I/O 失敗は握りつぶす (診断用途であり、失敗しても Hub の動作は続行する)。
public final class LocalContextEventLog: @unchecked Sendable {
    private let path: String

    public init(path: String) {
        self.path = path
    }

    public static func resolvePath(settingsPath: String) -> String {
        let directory = (settingsPath as NSString).deletingLastPathComponent
        return directory.isEmpty
            ? "events.jsonl"
            : (directory as NSString).appendingPathComponent("events.jsonl")
    }

    public func load() -> [LocalContextEvent] {
        guard FileManager.default.fileExists(atPath: path),
              let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let decoder = AmbientContextJson.decoder()
        var events: [LocalContextEvent] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            // 1 行壊れていても続行する。
            if let loaded = try? decoder.decode(LocalContextEvent.self, from: Data(trimmed.utf8)) {
                events.append(loaded)
            }
        }
        return events
    }

    public func append(_ events: [LocalContextEvent]) {
        guard !events.isEmpty else { return }
        ensureDirectory()
        let payload = Data(serialize(events).utf8)

        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: URL(fileURLWithPath: path))
        }
    }

    public func rewrite(_ events: [LocalContextEvent]) {
        ensureDirectory()
        let tempPath = path + ".tmp"
        let payload = Data(serialize(events).utf8)
        do {
            try payload.write(to: URL(fileURLWithPath: tempPath), options: .atomic)
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

    public func delete() {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func serialize(_ events: [LocalContextEvent]) -> String {
        events.map { AmbientContextJson.jsonlString($0) + "\n" }.joined()
    }

    private func ensureDirectory() {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        }
    }
}
