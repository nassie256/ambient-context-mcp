import Foundation

/// StdioBridge の純粋ロジック (I/O を伴わない部分)。
///
/// C# 版 `src/windows/AmbientContextMcp.StdioBridge/Program.cs` の
/// `TryReadDiscovery` / `ReadFirstSseDataAsync` / `BuildLocalErrorResponse` に対応する。
/// ここに副作用を持ち込まないことで、Package.swift にテストターゲットを足さずとも
/// 使い捨てパッケージへ symlink して単体検証できる状態を保つ。

// MARK: - discovery ファイル

/// discovery ファイル (`mcp-api.json`) から中継に必要な 3 項目だけを取り出したもの。
struct Discovery: Sendable, Equatable {
    let baseUrl: String
    let mcpUrl: String
    let token: String
}

enum DiscoveryFile {
    /// `kill(pid, 0)` による生存確認。ESRCH のときだけ「居ない」と判定する
    /// (EPERM は別ユーザの生きているプロセス)。
    static func isProcessAlive(_ pid: Int32) -> Bool {
        if kill(pid, 0) == 0 {
            return true
        }
        return errno != ESRCH
    }

    /// discovery ファイルの中身を解釈する。
    ///
    /// C# 版と同じく、baseUrl / mcpUrl / token のいずれかが欠けていれば nil。
    /// `pid` が数値で 1 以上かつそのプロセスが生きていなければ stale とみなして nil。
    static func parse(
        _ json: Data,
        isProcessAlive: (Int32) -> Bool = DiscoveryFile.isProcessAlive
    ) -> Discovery? {
        guard
            let parsed = try? JSONSerialization.jsonObject(with: json),
            let root = parsed as? [String: Any]
        else {
            return nil
        }

        guard
            let baseUrl = root["baseUrl"] as? String, !baseUrl.isEmpty,
            let mcpUrl = root["mcpUrl"] as? String, !mcpUrl.isEmpty,
            let token = root["token"] as? String, !token.isEmpty
        else {
            return nil
        }

        if let pid = integerValue(root["pid"]), pid > 0, pid <= Int64(Int32.max),
            !isProcessAlive(Int32(pid)) {
            return nil
        }

        return Discovery(baseUrl: baseUrl, mcpUrl: mcpUrl, token: token)
    }

    /// パスから読み込む。存在しない / 読めない / 壊れている場合は nil。
    static func read(
        path: String,
        isProcessAlive: (Int32) -> Bool = DiscoveryFile.isProcessAlive
    ) -> Discovery? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }
        return parse(data, isProcessAlive: isProcessAlive)
    }

    /// C# の `%LOCALAPPDATA%\AmbientContextMcp\mcp-api.json` に対応する macOS のパス。
    /// テスト用に `AMBIENT_MCP_DISCOVERY_PATH` で上書きできる。
    static func resolvePath(environment: [String: String] = ProcessInfo.processInfo.environment)
        -> String {
        if let override = environment["AMBIENT_MCP_DISCOVERY_PATH"], !override.isEmpty {
            return override
        }
        let home =
            environment["HOME"].map { $0 as NSString }
            ?? (NSHomeDirectory() as NSString)
        return home
            .appendingPathComponent("Library/Application Support/AmbientContextMcp/mcp-api.json")
    }
}

// MARK: - SSE

enum SseParser {
    /// `text/event-stream` の本文から最初の data ブロックを取り出す。
    ///
    /// 連続する `data:` 行を空行まで連結し、`data:` 直後の空白 1 個だけを取り除く
    /// (C# の `ReadFirstSseDataAsync` と同じ規則)。data が 1 つも無ければ nil。
    static func firstDataBlock(_ text: String) -> String? {
        var buffer = ""
        for line in lines(of: text) {
            if line.isEmpty {
                if !buffer.isEmpty {
                    return buffer
                }
                continue
            }
            if line.hasPrefix("data:") {
                let afterPrefix = line.index(line.startIndex, offsetBy: 5)
                let payloadStart =
                    line[afterPrefix...].first == " "
                    ? line.index(after: afterPrefix)
                    : afterPrefix
                buffer += line[payloadStart...]
            }
        }
        return buffer.isEmpty ? nil : buffer
    }

    /// `StreamReader.ReadLine` と同じ行分割 (CRLF / LF / CR を終端とし、末尾の
    /// 終端記号のあとに空行を作らない)。
    /// Swift では "\r\n" が 1 つの Character (書記素クラスタ) になるので、3 種を並べて判定する。
    static func lines(of text: String) -> [String] {
        var result: [String] = []
        var current = ""

        for character in text {
            if character == "\n" || character == "\r" || character == "\r\n" {
                result.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }

        if !current.isEmpty {
            result.append(current)
        }
        return result
    }
}

// MARK: - ローカルエラー応答

enum LocalErrorResponse {
    /// 上流への中継に失敗したときに、このプロセス自身が返す JSON-RPC エラー。
    ///
    /// id が数値または数値文字列のときだけ応答を作る。id が無い (通知) / 数値でない /
    /// そもそも JSON として壊れている場合は nil = 何も書かない。
    static func make(requestLine: String, message: String) -> Data? {
        guard
            let data = requestLine.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return nil
        }
        guard let root = parsed as? [String: Any], let rawId = root["id"] else {
            return nil
        }

        let id: Int64?
        if let number = integerValue(rawId) {
            id = number
        } else if let text = rawId as? String {
            id = Int64(text)
        } else {
            id = nil
        }
        guard let id else { return nil }

        // JSONEncoder / JSONSerialization はキー順を保存しないので、C# の匿名型と同じ
        // jsonrpc → id → error の並びになるよう組み立てる (文字列のエスケープだけ委譲する)。
        let quoted = jsonQuoted("ambient-mcp-stdio upstream error: \(message)")
        let json = #"{"jsonrpc":"2.0","id":\#(id),"error":{"code":-32000,"message":\#(quoted)}}"#
        return Data(json.utf8)
    }

    /// 文字列を JSON のリテラル (引用符込み) にする。
    private static func jsonQuoted(_ value: String) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [value]),
            let array = String(data: data, encoding: .utf8),
            array.count >= 2
        else {
            return "\"\""
        }
        return String(array.dropFirst().dropLast())
    }
}

// MARK: - 共通ヘルパ

/// JSON の値が「整数の数値」であれば Int64 として返す。
/// true / false は JSON では数値ではないので除外し、1.5 のような非整数も弾く
/// (C# の `TryGetInt64` と同じ判定)。
private func integerValue(_ value: Any?) -> Int64? {
    guard let number = value as? NSNumber else { return nil }
    if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
    let double = number.doubleValue
    guard double == double.rounded(.towardZero),
        double >= Double(Int64.min), double <= Double(Int64.max)
    else {
        return nil
    }
    return number.int64Value
}
