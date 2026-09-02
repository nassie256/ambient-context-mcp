import Foundation
import MCP

/// Port of `McpAuthenticationMiddleware` (src/windows/AmbientContextMcp.Desktop/Mcp/McpAuthenticationMiddleware.cs).
///
/// Run as a pre-check in the HTTP adapter, *before* the request reaches the MCP
/// transport, so that it applies to every method (including GET/DELETE) and to
/// malformed bodies — matching the ASP.NET middleware ordering. See RESULT.md
/// for why this is not an `HTTPRequestValidator`.
enum McpAuth {
    static let tokenHeader = "X-AmbientContextMcp-Token"

    struct Failure: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    static func check(_ request: HTTPRequest, token: String) -> Failure? {
        guard isAllowedOrigin(request) else {
            return Failure(
                status: 403,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"forbidden_origin"}"#.utf8)
            )
        }
        guard isAuthorized(request, token: token) else {
            return Failure(
                status: 401,
                headers: ["Content-Type": "application/json", "WWW-Authenticate": "Bearer"],
                body: Data(#"{"error":"unauthorized"}"#.utf8)
            )
        }
        return nil
    }

    /// Absent Origin passes (non-browser clients). Present Origin must be an
    /// absolute http/https URL whose host is a loopback name.
    static func isAllowedOrigin(_ request: HTTPRequest) -> Bool {
        guard let origin = request.header("Origin") else { return true }
        // NIO joins repeated headers with ", " — every value must pass.
        for value in origin.components(separatedBy: ",") {
            let candidate = value.trimmingCharacters(in: .whitespaces)
            guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
                scheme == "http" || scheme == "https",
                let host = url.host, isLocalhost(host)
            else { return false }
        }
        return true
    }

    static func isAuthorized(_ request: HTTPRequest, token: String) -> Bool {
        guard !token.trimmingCharacters(in: .whitespaces).isEmpty else { return false }

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
