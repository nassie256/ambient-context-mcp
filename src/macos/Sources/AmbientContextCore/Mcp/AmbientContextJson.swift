import Foundation

/// C# の `AmbientContextJson.Options` に対応する JSON エンコーダ/デコーダのファクトリ。
///
/// - キーは各型の合成 CodingKeys (= Swift のプロパティ名) をそのまま使う。
///   Swift 側のプロパティ名は元から camelCase なので、keyEncodingStrategy を挟まずに
///   C# の `JsonNamingPolicy.CamelCase` と同一のキーになる。
/// - 日付は ISO 8601 (ローカル UTC オフセット付き, ミリ秒 3 桁)。
/// - 整形出力 (`prettyPrinted`) で、キーのソートは行わない (宣言順を保つ)。
/// - `/` はエスケープしない。
public enum AmbientContextJson {
    public static func encoder(prettyPrinted: Bool = true) -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.withoutEscapingSlashes]
        if prettyPrinted {
            formatting.insert(.prettyPrinted)
        }
        encoder.outputFormatting = formatting
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(AmbientDateFormat.string(from: date))
        }
        return encoder
    }

    /// JSONL 用 (1 行 1 レコード) の非整形エンコーダ。
    public static func jsonlEncoder() -> JSONEncoder {
        encoder(prettyPrinted: false)
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = AmbientDateFormat.parse(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Invalid ISO 8601 timestamp: \(text)")
            }
            return date
        }
        return decoder
    }

    /// 値を整形済み JSON 文字列にする。失敗時は空の JSON オブジェクトを返す。
    public static func string<T: Encodable>(_ value: T) -> String {
        guard let data = try? encoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    public static func jsonlString<T: Encodable>(_ value: T) -> String {
        guard let data = try? jsonlEncoder().encode(value),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
