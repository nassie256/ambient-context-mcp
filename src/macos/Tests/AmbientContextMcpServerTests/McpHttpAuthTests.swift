import Foundation
import Testing
@testable import AmbientContextMcpServer

/// 認証・Origin 検査を実 HTTP で検証する (C# `McpAuthenticationMiddleware` との等価性)。
@Suite("McpHttpAuth")
struct McpHttpAuthTests {
    @Test("missing_token_returns_401_with_challenge")
    func missingTokenReturns401() async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let response = try await TestHTTP.rpc(
            server.mcpUrl, payload: TestHTTP.toolsListPayload(), token: nil)
        #expect(response.status == 401)
        #expect(response.headers["www-authenticate"] == "Bearer")
        #expect(response.text == #"{"error":"unauthorized"}"#)
    }

    @Test("wrong_token_returns_401")
    func wrongTokenReturns401() async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let response = try await TestHTTP.rpc(
            server.mcpUrl, payload: TestHTTP.toolsListPayload(), token: "not-the-token")
        #expect(response.status == 401)
        #expect(response.text == #"{"error":"unauthorized"}"#)
    }

    @Test("bearer_token_is_accepted", arguments: ["Bearer", "bearer", "BEARER"])
    func bearerTokenIsAccepted(prefix: String) async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let response = try await TestHTTP.request(
            server.mcpUrl,
            headers: [
                "Content-Type": "application/json",
                "Accept": "application/json, text/event-stream",
                "Authorization": "\(prefix) \(server.token)"
            ],
            body: try JSONSerialization.data(withJSONObject: TestHTTP.toolsListPayload()))
        #expect(response.status == 200)
    }

    @Test("custom_token_header_is_accepted")
    func customTokenHeaderIsAccepted() async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let response = try await TestHTTP.rpc(
            server.mcpUrl,
            payload: TestHTTP.toolsListPayload(),
            token: server.token,
            tokenHeader: McpAuthentication.tokenHeader)
        #expect(response.status == 200)
    }

    @Test("non_local_origin_returns_403", arguments: [
        "http://evil.example",
        "https://evil.example",
        "file:///etc/passwd",
        "not-a-url"
    ])
    func nonLocalOriginReturns403(origin: String) async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let response = try await TestHTTP.rpc(
            server.mcpUrl,
            payload: TestHTTP.toolsListPayload(),
            token: server.token,
            extraHeaders: ["Origin": origin])
        #expect(response.status == 403)
        #expect(response.text == #"{"error":"forbidden_origin"}"#)
    }

    /// C# は http/https の両方と 4 種のループバック表記を許可する。SDK 既定の
    /// `OriginValidator.localhost()` は https を弾くので使っていない。
    @Test("local_origins_are_allowed", arguments: [
        "http://localhost",
        "http://localhost:1234",
        "https://localhost",
        "http://127.0.0.1:37690",
        "http://[::1]:37690"
    ])
    func localOriginsAreAllowed(origin: String) async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let response = try await TestHTTP.rpc(
            server.mcpUrl,
            payload: TestHTTP.toolsListPayload(),
            token: server.token,
            extraHeaders: ["Origin": origin])
        #expect(response.status == 200)
    }

    /// Origin は 403 が 401 より先。403 の判定はトークン不在でも変わらない。
    @Test("origin_is_checked_before_token")
    func originIsCheckedBeforeToken() async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let response = try await TestHTTP.rpc(
            server.mcpUrl,
            payload: TestHTTP.toolsListPayload(),
            token: nil,
            extraHeaders: ["Origin": "http://evil.example"])
        #expect(response.status == 403)
    }

    /// `GET /mcp` は認証を通ったうえで transport が 405 + `Allow: POST` を返す
    /// (stateless transport は SSE ストリームを開かない)。ボディは JSON-RPC のエラーオブジェクト。
    @Test("authenticated_get_mcp_returns_405")
    func authenticatedGetMcpReturns405() async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let response = try await TestHTTP.request(
            server.mcpUrl,
            method: "GET",
            headers: [
                "Accept": "application/json, text/event-stream",
                "Authorization": "Bearer \(server.token)"
            ])
        #expect(response.status == 405)
        #expect(response.headers["allow"] == "POST")
        let error = try #require(try response.json()["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32600)
        #expect(error["message"] as? String == "Invalid Request: Method Not Allowed")
    }

    /// 認証は transport より前に走るので、未認証の GET は 405 ではなく 401。
    @Test("unauthenticated_get_mcp_returns_401")
    func unauthenticatedGetMcpReturns401() async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let response = try await TestHTTP.request(
            server.mcpUrl,
            method: "GET",
            headers: ["Accept": "application/json, text/event-stream"])
        #expect(response.status == 401)
        #expect(response.text == #"{"error":"unauthorized"}"#)
    }

    /// `/mcp` 配下以外は認証を掛けず 404 (C# の `StartsWithSegments("/mcp")` と同じ範囲)。
    @Test("unknown_path_returns_404_without_auth", arguments: ["/", "/health", "/mcpx"])
    func unknownPathReturns404(path: String) async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let url = URL(string: "http://127.0.0.1:\(server.port)\(path)")!
        let response = try await TestHTTP.request(url, method: "GET")
        #expect(response.status == 404)
        #expect(response.text == #"{"error":"not_found"}"#)
    }

    /// 設定トークンが空なら誰も通さない (C# の `IsNullOrWhiteSpace` 分岐)。
    @Test("empty_configured_token_rejects_everything")
    func emptyConfiguredTokenRejectsEverything() async throws {
        let server = try await TestServer(token: "")
        defer { Task { await server.shutdown() } }

        for header in ["Authorization": "Bearer ", McpAuthentication.tokenHeader: ""] {
            let response = try await TestHTTP.request(
                server.mcpUrl,
                headers: [
                    "Content-Type": "application/json",
                    "Accept": "application/json, text/event-stream",
                    header.key: header.value
                ],
                body: try JSONSerialization.data(withJSONObject: TestHTTP.toolsListPayload()))
            #expect(response.status == 401)
        }
    }
}
