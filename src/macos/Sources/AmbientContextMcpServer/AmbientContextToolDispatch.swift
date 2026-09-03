import AmbientContextCore
import Foundation
import MCP

/// `tools/call` の引数デコードと `ContextToolsCore` への振り分け。
///
/// C# 版は MCP SDK が属性付きメソッドの引数を型に合わせて束縛するため、クライアントは
/// 「省略」「null」「配列」「数値」といった素直な JSON 形を送ってくる。ここではその全ての形を
/// 受けられるようにしている (数値を送るべき箇所に文字列が来た場合も救済する)。
public enum AmbientContextToolDispatch {
    /// ツール名が未知なら nil。エラーは `CallTool.Result(isError: true)` として返す。
    public static func call(
        name: String,
        arguments: [String: Value]?,
        hub: LocalContextHub
    ) -> CallTool.Result? {
        switch name {
        case AmbientContextTools.getPolicy.name:
            return text(ContextToolsCore.getPolicy(hub: hub))

        case AmbientContextTools.describeEvents.name:
            return text(ContextToolsCore.describeEvents(hub: hub))

        case AmbientContextTools.getStates.name:
            return text(ContextToolsCore.getStates(
                hub: hub,
                names: stringArray(arguments?["names"]),
                scopes: stringArray(arguments?["scopes"]),
                includeMetadata: bool(arguments?["includeMetadata"]) ?? true))

        case AmbientContextTools.pollEvents.name:
            do {
                return text(try ContextToolsCore.pollEvents(
                    hub: hub,
                    clientId: string(arguments?["clientId"]) ?? "ambient-context-mcp",
                    cursor: string(arguments?["cursor"]) ?? "",
                    names: stringArray(arguments?["names"]),
                    scopes: stringArray(arguments?["scopes"]),
                    limit: int(arguments?["limit"]) ?? 50,
                    since: string(arguments?["since"]) ?? "",
                    until: string(arguments?["until"]) ?? "",
                    includePayload: bool(arguments?["includePayload"]) ?? true))
            } catch let error as ContextToolsError {
                // C# の ArgumentException 相当。MCP としては例外ではなく isError の結果で返す。
                return errorText(error.description)
            } catch {
                return errorText("\(error)")
            }

        default:
            return nil
        }
    }

    // MARK: - 結果組み立て

    static func text(_ value: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: value, annotations: nil, _meta: nil)],
            isError: false)
    }

    static func errorText(_ message: String) -> CallTool.Result {
        CallTool.Result(
            content: [.text(text: message, annotations: nil, _meta: nil)],
            isError: true)
    }

    // MARK: - 引数デコード

    /// 配列 (要素は文字列) / null / 省略を受ける。null と空配列はどちらも「未指定」扱い。
    /// 単一の文字列が来た場合は 1 要素の配列とみなす (寛容側に倒す)。
    static func stringArray(_ value: Value?) -> [String]? {
        guard let value, value != .null else { return nil }
        if let array = value.arrayValue {
            return array.compactMap { $0.stringValue }
        }
        if let single = value.stringValue {
            return [single]
        }
        return nil
    }

    static func string(_ value: Value?) -> String? {
        guard let value, value != .null else { return nil }
        return value.stringValue
    }

    static func bool(_ value: Value?) -> Bool? {
        guard let value, value != .null else { return nil }
        if let flag = value.boolValue { return flag }
        // "true" / "false" の文字列で来ることがある。
        switch value.stringValue?.lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }

    static func int(_ value: Value?) -> Int? {
        guard let value, value != .null else { return nil }
        if let number = value.intValue { return number }
        if let number = value.doubleValue { return Int(number) }
        if let text = value.stringValue { return Int(text) }
        return nil
    }
}
