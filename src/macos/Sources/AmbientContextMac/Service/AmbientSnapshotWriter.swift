import Foundation

import AmbientContextCore

/// C# `AmbientContextMcp.Desktop/AmbientContext/AmbientSnapshotWriter` の移植。
///
/// C# 側は `\uXXXX` エスケープを後段の正規表現で戻して「人が読める JSON」にしていたが、
/// Swift の `JSONEncoder` は既定で生 UTF-8 を出力するので整形出力だけで同じ結果になる
/// (Phase 1 で承認済みの意図的な逸脱)。書き込みは tmp → move の原子的置換。
public struct AmbientSnapshotWriter: Sendable {
    private let path: String

    public init(path: String) {
        self.path = path
    }

    public var snapshotPath: String { path }

    /// 失敗時は例外を投げず false を返す (capture ループを止めないため)。
    @discardableResult
    public func write(_ snapshot: AmbientContextSnapshot) -> Bool {
        let directory = (path as NSString).deletingLastPathComponent
        if !directory.isEmpty {
            try? FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true)
        }

        guard let data = try? AmbientContextJson.encoder().encode(snapshot) else {
            return false
        }

        let temporaryPath = path + ".tmp"
        do {
            try data.write(to: URL(fileURLWithPath: temporaryPath), options: .atomic)
            // C# の File.Move(overwrite: true) 相当。既存があれば置換する。
            _ = try FileManager.default.replaceItemAt(
                URL(fileURLWithPath: path),
                withItemAt: URL(fileURLWithPath: temporaryPath))
            return true
        } catch {
            // replaceItemAt は宛先が存在しないと失敗するので、その場合は単純移動で救済する。
            if !FileManager.default.fileExists(atPath: path),
               (try? FileManager.default.moveItem(atPath: temporaryPath, toPath: path)) != nil {
                return true
            }
            try? FileManager.default.removeItem(atPath: temporaryPath)
            return false
        }
    }
}
