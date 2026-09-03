import Foundation
import MCP

/// C# `McpAuthenticationMiddleware` (src/windows/AmbientContextMcp.Desktop/Mcp/McpAuthenticationMiddleware.cs)
/// の移植。
///
/// **MCP transport に渡す前の事前チェックとして** 走らせること。SDK の validation pipeline は
/// POST かつ JSON-RPC のパースに成功した後にしか走らないため、GET / 壊れたボディが無認証で
/// 応答してしまい ASP.NET のミドルウェア順序と等価にならない (PoC 1 RESULT.md 参照)。
public enum McpAuthentication {
    public static let tokenHeader = "X-AmbientContextMcp-Token"

    public struct Failure: Sendable {
        public let status: Int
        public let headers: [String: String]
        public let body: Data
    }

    /// 認証・Origin 検査。通過したら nil。
    public static func check(_ request: HTTPRequest, token: String) -> Failure? {
        guard isAllowedOrigin(request) else {
            return Failure(
                status: 403,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"forbidden_origin"}"#.utf8))
        }
        guard isAuthorized(request, token: token) else {
            return Failure(
                status: 401,
                headers: ["Content-Type": "application/json", "WWW-Authenticate": "Bearer"],
                body: Data(#"{"error":"unauthorized"}"#.utf8))
        }
        return nil
    }

    /// Origin が無ければ通す (ブラウザ以外のクライアント)。あれば全ての値が
    /// http/https の絶対 URL かつ host がループバック名でなければならない。
    public static func isAllowedOrigin(_ request: HTTPRequest) -> Bool {
        guard let origin = request.header("Origin") else { return true }
        // NIO は同名ヘッダを ", " で連結するので、C# の StringValues と同じく全要素を検査する。
        for value in origin.components(separatedBy: ",") {
            let candidate = value.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: candidate),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host,
                  isLocalhost(host)
            else { return false }
        }
        return true
    }

    /// 設定トークンが空 (または空白のみ) なら常に不許可。
    public static func isAuthorized(_ request: HTTPRequest, token: String) -> Bool {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

        if let headerToken = request.header(tokenHeader), headerToken == token {
            return true
        }
        guard let authorization = request.header("Authorization") else { return false }
        let prefix = "Bearer "
        guard authorization.count >= prefix.count,
              authorization.prefix(prefix.count).caseInsensitiveCompare(prefix) == .orderedSame
        else { return false }
        return authorization.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces) == token
    }

    private static func isLocalhost(_ host: String) -> Bool {
        switch host.lowercased() {
        case "localhost", "127.0.0.1", "::1", "[::1]": return true
        default: return false
        }
    }
}
