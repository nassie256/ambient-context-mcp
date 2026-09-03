import Foundation

/// C# 版の `Dictionary<string, T>(StringComparer.OrdinalIgnoreCase)` 相当。
/// - キー照合は大文字小文字を無視する
/// - 出力時は最初に登録されたキーの綴りをそのまま保つ
/// - 反復・シリアライズ順は挿入順 (C# Dictionary の実挙動に合わせる)
public struct CaseInsensitiveDictionary<Value: Sendable & Hashable>: Sendable {
    private var order: [String] = []
    private var originalKeys: [String: String] = [:]
    private var storage: [String: Value] = [:]

    public init() {}

    public init(_ pairs: [(String, Value)]) {
        for pair in pairs {
            self[pair.0] = pair.1
        }
    }

    public init(_ other: CaseInsensitiveDictionary<Value>) {
        self = other
    }

    /// 大文字小文字無視の正規化キー。C# の OrdinalIgnoreCase は不変カルチャの単純な大小変換なので
    /// Swift 側も `lowercased()` で近似する (ASCII の path/payload キーでは等価)。
    private static func normalize(_ key: String) -> String {
        key.lowercased()
    }

    public subscript(key: String) -> Value? {
        get { storage[Self.normalize(key)] }
        set {
            let normalized = Self.normalize(key)
            if let newValue {
                if storage[normalized] == nil {
                    order.append(normalized)
                    originalKeys[normalized] = key
                }
                storage[normalized] = newValue
            } else {
                if storage.removeValue(forKey: normalized) != nil {
                    originalKeys.removeValue(forKey: normalized)
                    order.removeAll { $0 == normalized }
                }
            }
        }
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> Value? {
        let normalized = Self.normalize(key)
        guard let existing = storage.removeValue(forKey: normalized) else { return nil }
        originalKeys.removeValue(forKey: normalized)
        order.removeAll { $0 == normalized }
        return existing
    }

    public func contains(_ key: String) -> Bool {
        storage[Self.normalize(key)] != nil
    }

    /// 元の綴りを保持したキー一覧 (挿入順)。
    public var keys: [String] {
        order.map { originalKeys[$0] ?? $0 }
    }

    public var values: [Value] {
        order.compactMap { storage[$0] }
    }

    public var count: Int { order.count }

    public var isEmpty: Bool { order.isEmpty }

    /// 挿入順の (キー, 値) ペア。
    public var pairs: [(key: String, value: Value)] {
        order.compactMap { normalized in
            guard let value = storage[normalized] else { return nil }
            return (originalKeys[normalized] ?? normalized, value)
        }
    }

    /// キーの昇順 (大文字小文字無視) で並べたペア。ハッシュ計算などの決定的な走査に使う。
    public var sortedPairs: [(key: String, value: Value)] {
        pairs.sorted { $0.key.lowercased() < $1.key.lowercased() }
    }
}

extension CaseInsensitiveDictionary: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, Value)...) {
        self.init(elements)
    }
}

extension CaseInsensitiveDictionary: Sequence {
    public func makeIterator() -> AnyIterator<(key: String, value: Value)> {
        var iterator = pairs.makeIterator()
        return AnyIterator { iterator.next() }
    }
}

extension CaseInsensitiveDictionary: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storage == rhs.storage
    }
}

extension CaseInsensitiveDictionary: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(storage)
    }
}

/// 動的なキーを扱うための CodingKey。
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }

    init(_ key: String) {
        self.stringValue = key
        self.intValue = nil
    }
}

extension CaseInsensitiveDictionary: Encodable where Value: Encodable {
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: DynamicCodingKey.self)
        for pair in pairs {
            try container.encode(pair.value, forKey: DynamicCodingKey(pair.key))
        }
    }
}

extension CaseInsensitiveDictionary: Decodable where Value: Decodable {
    public init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        for key in container.allKeys {
            self[key.stringValue] = try container.decode(Value.self, forKey: key)
        }
    }
}
