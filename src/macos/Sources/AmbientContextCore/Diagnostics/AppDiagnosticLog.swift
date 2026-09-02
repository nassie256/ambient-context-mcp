import Foundation

/// トレイ / UI / capture のトラブルシュート用 append-only JSONL 診断ログ。
/// リリースビルドにはコンソールが無いため、このファイルが主な監査証跡になる。
/// `maxFileBytes` を超えたら 1 世代 (.old) だけ残してローテートする。スレッドセーフ。
public final class AppDiagnosticLog: @unchecked Sendable {
    private static let maxFileBytes: UInt64 = 5 * 1024 * 1024

    public static let shared = AppDiagnosticLog()

    private let lock = NSLock()
    private var path: String?

    private init() {}

    public func configure(settingsPath: String) {
        lock.lock()
        defer { lock.unlock() }
        let directory = (settingsPath as NSString).deletingLastPathComponent
        path = directory.isEmpty
            ? "app-diagnostics.jsonl"
            : (directory as NSString).appendingPathComponent("app-diagnostics.jsonl")
    }

    public var logPath: String? {
        lock.lock()
        defer { lock.unlock() }
        return path
    }

    public func log(
        category: String,
        event: String,
        detail: [String: DiagnosticValue]? = nil
    ) {
        lock.lock()
        guard let path, !path.isEmpty else {
            lock.unlock()
            return
        }

        // C# は managed thread id / name を記録する。Swift には安定した thread id が無いため、
        // 現在の Thread の説明文字列 (メインスレッドなら "main") で代替する。
        var entry: [(String, DiagnosticValue)] = [
            ("observedAt", .string(AmbientDateFormat.string(from: Date()))),
            ("category", .string(category)),
            ("event", .string(event)),
            ("thread", .string(Self.currentThreadDescription()))
        ]
        if let detail, !detail.isEmpty {
            entry.append(("detail", .object(detail)))
        }

        let line = DiagnosticValue.orderedObject(entry).jsonText
        appendLineLocked(line, path: path)
        lock.unlock()
    }

    public func logError(
        category: String,
        event: String,
        error: any Error,
        detail: [String: DiagnosticValue]? = nil
    ) {
        var merged = detail ?? [:]
        merged["exceptionType"] = .string(String(describing: type(of: error)))
        merged["exceptionMessage"] = .string(String(describing: error))
        log(category: category, event: event, detail: merged)
    }

    private static func currentThreadDescription() -> String {
        if Thread.isMainThread { return "main" }
        let name = Thread.current.name ?? ""
        return name.isEmpty ? Thread.current.description : name
    }

    private func appendLineLocked(_ line: String, path: String) {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true)
        }

        rotateIfOversized(path: path)

        let payload = Data((line + "\n").utf8)
        if let handle = FileHandle(forWritingAtPath: path) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload)
        } else {
            try? payload.write(to: URL(fileURLWithPath: path))
        }
    }

    private func rotateIfOversized(path: String) {
        guard FileManager.default.fileExists(atPath: path),
              let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attributes[.size] as? NSNumber,
              size.uint64Value >= Self.maxFileBytes else {
            return
        }

        let backupPath = path + ".old"
        try? FileManager.default.removeItem(atPath: backupPath)
        try? FileManager.default.moveItem(atPath: path, toPath: backupPath)
    }
}

/// 診断ログの detail に入れられる値。C# の `object?` 相当を型付きで表現する。
public enum DiagnosticValue: Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null
    case object([String: DiagnosticValue])

    /// 挿入順を保った JSON オブジェクトを組み立てるための内部表現。
    static func orderedObject(_ pairs: [(String, DiagnosticValue)]) -> OrderedObject {
        OrderedObject(pairs: pairs)
    }

    struct OrderedObject {
        var pairs: [(String, DiagnosticValue)]

        var jsonText: String {
            "{" + pairs.map { "\(DiagnosticValue.quote($0.0)):\($0.1.jsonText)" }.joined(separator: ",") + "}"
        }
    }

    var jsonText: String {
        switch self {
        case .string(let value): return Self.quote(value)
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .bool(let value): return value ? "true" : "false"
        case .null: return "null"
        case .object(let value):
            let body = value.keys.sorted()
                .map { "\(Self.quote($0)):\(value[$0]!.jsonText)" }
                .joined(separator: ",")
            return "{" + body + "}"
        }
    }

    static func quote(_ text: String) -> String {
        var result = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if character.value < 0x20 {
                    result += String(format: "\\u%04x", character.value)
                } else {
                    result.unicodeScalars.append(character)
                }
            }
        }
        return result + "\""
    }
}
