import Foundation

/// ClientId ごとの cursor 位置を保持する。
/// 位置を永久蓄積するとリークになるので、一定期間アクセスのない entry は落とす。
/// MCP クライアントは通常 1 ホスト数個だが、UUID で毎回名乗る misbehaving client がいた場合に
/// dict が無制限に膨らむのを防ぐ。
public final class LocalContextCursorTracker {
    public static let defaultStaleClientTtl: TimeInterval = 7 * 24 * 60 * 60

    public struct CursorResult: Sendable, Hashable {
        public var sequence: Int64
        public var expired: Bool

        public init(sequence: Int64, expired: Bool) {
            self.sequence = sequence
            self.expired = expired
        }
    }

    private struct Entry {
        var sequence: Int64
        var lastSeen: Date
    }

    /// キーは正規化 (大文字小文字無視) 済み clientId。
    private var clientPositions: [String: Entry] = [:]

    public init() {}

    public func resolve(
        clientId: String,
        cursor: String,
        isHistoryQuery: Bool,
        firstSequence: Int64,
        latestSequence: Int64,
        now: Date
    ) -> CursorResult {
        if let cursorSequence = Self.decode(cursor) {
            return CursorResult(
                sequence: Self.clampExpired(cursorSequence, firstSequence),
                expired: Self.isExpired(cursorSequence, firstSequence))
        }

        if isHistoryQuery {
            return CursorResult(
                sequence: firstSequence == 0 ? 0 : max(0, firstSequence - 1),
                expired: false)
        }

        let key = Self.normalizeClientId(clientId).lowercased()
        if var entry = clientPositions[key] {
            // touch: 読み出しでも lastSeen を更新しないと、subscribe しっぱなしで
            // advance だけ呼ばれないパス (= 取得 0 件で位置が進まない) が TTL で落ちる。
            entry.lastSeen = now
            clientPositions[key] = entry
            return CursorResult(
                sequence: Self.clampExpired(entry.sequence, firstSequence),
                expired: Self.isExpired(entry.sequence, firstSequence))
        }

        clientPositions[key] = Entry(sequence: latestSequence, lastSeen: now)
        return CursorResult(sequence: latestSequence, expired: false)
    }

    public func advance(clientId: String, sequence: Int64, now: Date) {
        clientPositions[Self.normalizeClientId(clientId).lowercased()] =
            Entry(sequence: sequence, lastSeen: now)
    }

    /// 最終アクセスから ttl 経過した client entry を削除する。戻り値は削除件数。
    @discardableResult
    public func pruneStale(now: Date, ttl: TimeInterval? = nil) -> Int {
        let threshold = now.addingTimeInterval(-(ttl ?? Self.defaultStaleClientTtl))
        let stale = clientPositions.filter { $0.value.lastSeen < threshold }.map(\.key)
        for key in stale {
            clientPositions.removeValue(forKey: key)
        }
        return stale.count
    }

    public var trackedClientCount: Int { clientPositions.count }

    public static func encode(_ sequence: Int64) -> String {
        Base64Url.encode(Data("seq:\(sequence)".utf8))
    }

    private static func clampExpired(_ sequence: Int64, _ firstSequence: Int64) -> Int64 {
        isExpired(sequence, firstSequence) ? max(0, firstSequence - 1) : sequence
    }

    private static func isExpired(_ sequence: Int64, _ firstSequence: Int64) -> Bool {
        firstSequence > 0 && sequence < firstSequence - 1
    }

    private static func normalizeClientId(_ clientId: String) -> String {
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "anonymous" : trimmed
    }

    static func decode(_ cursor: String) -> Int64? {
        guard !cursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = Base64Url.decode(cursor),
              let text = String(data: data, encoding: .utf8),
              text.lowercased().hasPrefix("seq:") else {
            return nil
        }
        return Int64(text.dropFirst(4))
    }
}
