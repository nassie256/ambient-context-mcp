import Foundation

/// C# の `DateTimeOffset` と互換な ISO 8601 表記の生成・解析。
///
/// 出力例: `2026-05-04T10:15:00.123+09:00`
/// C# (System.Text.Json) は小数部の桁数が可変 (末尾 0 を落とし、0 なら小数部ごと省略) だが、
/// Swift 側は常にミリ秒 3 桁を出力する。詳細は macos-port 設計メモの deviation 一覧を参照。
public enum AmbientDateFormat {
    /// ローカルオフセット付き ISO 8601 文字列にする。
    public static func string(from date: Date) -> String {
        string(from: date, timeZone: .current)
    }

    public static func string(from date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date)

        // 丸め誤差でミリ秒が 1000 に到達しないよう、秒未満は切り捨てる。
        let milliseconds = min(999, Int((Double(parts.nanosecond ?? 0) / 1_000_000.0).rounded(.down)))
        let offsetSeconds = timeZone.secondsFromGMT(for: date)
        let sign = offsetSeconds < 0 ? "-" : "+"
        let absOffset = abs(offsetSeconds)

        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03d%@%02d:%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0,
            milliseconds,
            sign,
            absOffset / 3600,
            (absOffset % 3600) / 60)
    }

    /// UTC 基準の `yyyyMMddHHmmssfff` 表記 (イベント ID 用)。
    public static func compactUtcStamp(from date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second, .nanosecond],
            from: date)
        let milliseconds = min(999, Int((Double(parts.nanosecond ?? 0) / 1_000_000.0).rounded(.down)))
        return String(
            format: "%04d%02d%02d%02d%02d%02d%03d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0,
            milliseconds)
    }

    /// ISO 8601 文字列を解析する。オフセットが無い場合はローカル時刻とみなす
    /// (C# の `DateTimeStyles.AssumeLocal` と同じ)。
    public static func parse(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var scanner = Cursor(trimmed)
        guard let year = scanner.readDigits(4) else { return nil }
        guard scanner.consume("-"), let month = scanner.readDigits(2) else { return nil }
        guard scanner.consume("-"), let day = scanner.readDigits(2) else { return nil }

        var hour = 0
        var minute = 0
        var second = 0
        var nanosecond = 0

        if scanner.consume("T") || scanner.consume("t") || scanner.consume(" ") {
            guard let h = scanner.readDigits(2) else { return nil }
            guard scanner.consume(":"), let m = scanner.readDigits(2) else { return nil }
            hour = h
            minute = m
            if scanner.consume(":") {
                guard let s = scanner.readDigits(2) else { return nil }
                second = s
            }
            if scanner.consume(".") || scanner.consume(",") {
                let fraction = scanner.readAllDigits()
                guard !fraction.isEmpty else { return nil }
                let padded = String((fraction + "000000000").prefix(9))
                nanosecond = Int(padded) ?? 0
            }
        }

        var offsetSeconds: Int?
        if scanner.consume("Z") || scanner.consume("z") {
            offsetSeconds = 0
        } else if scanner.peek() == "+" || scanner.peek() == "-" {
            let negative = scanner.peek() == "-"
            _ = scanner.next()
            guard let oh = scanner.readDigits(2) else { return nil }
            _ = scanner.consume(":")
            let om = scanner.readDigits(2) ?? 0
            let total = oh * 3600 + om * 60
            offsetSeconds = negative ? -total : total
        }

        guard scanner.isAtEnd else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanosecond

        var calendar = Calendar(identifier: .gregorian)
        if let offsetSeconds {
            guard let zone = TimeZone(secondsFromGMT: offsetSeconds) else { return nil }
            calendar.timeZone = zone
        } else {
            calendar.timeZone = .current
        }
        return calendar.date(from: components)
    }

    private struct Cursor {
        private let characters: [Character]
        private var index = 0

        init(_ text: String) {
            characters = Array(text)
        }

        var isAtEnd: Bool { index >= characters.count }

        func peek() -> Character? {
            index < characters.count ? characters[index] : nil
        }

        mutating func next() -> Character? {
            guard index < characters.count else { return nil }
            defer { index += 1 }
            return characters[index]
        }

        mutating func consume(_ character: Character) -> Bool {
            guard peek() == character else { return false }
            index += 1
            return true
        }

        mutating func readDigits(_ count: Int) -> Int? {
            guard index + count <= characters.count else { return nil }
            var value = 0
            for offset in 0..<count {
                guard let digit = characters[index + offset].wholeNumberValue,
                      characters[index + offset].isNumber else { return nil }
                value = value * 10 + digit
            }
            index += count
            return value
        }

        mutating func readAllDigits() -> String {
            var result = ""
            while let character = peek(), character.isNumber {
                result.append(character)
                index += 1
            }
            return result
        }
    }
}

/// C# の `DateOnly` に相当する日付のみの値。JSON では `yyyy-MM-dd`。
public struct DateOnly: Hashable, Sendable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public init?(_ text: String) {
        let parts = text.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        self.init(year, month, day)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let parsed = DateOnly(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid DateOnly: \(text)")
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
