import AmbientContextCore
import Foundation
import Testing
@testable import AmbientContextMcpServer

/// stateless 動作とツール呼び出しの検証。
@Suite("McpHttpSession")
struct McpHttpSessionTests {
    /// SDK 既定の initialize ハンドラは 2 回目を "Server is already initialized" で拒否する。
    /// 冪等ハンドラで上書きしてあるので、独立したクライアント 2 つが initialize → tools/list を
    /// 通せなければならない (これを落とすと 2 番目以降のクライアントが全て壊れる)。
    @Test("two_independent_initialize_sequences_both_succeed")
    func twoIndependentInitializeSequencesBothSucceed() async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }
        let url = server.mcpUrl
        let token = server.token

        for round in 1...2 {
            // 接続 (TCP / URLSession のプール) を共有しないよう毎回作り直す。
            let session = URLSession(configuration: .ephemeral)

            let initialize = try await TestHTTP.rpc(
                url, payload: TestHTTP.initializePayload(id: round), token: token, session: session)
            #expect(initialize.status == 200, "round \(round): initialize が 200 でない")
            let result = try #require(
                try initialize.json()["result"] as? [String: Any],
                "round \(round): initialize が result を返さない (\(initialize.text))")
            #expect(result["serverInfo"] as? [String: Any] != nil)

            let list = try await TestHTTP.rpc(
                url, payload: TestHTTP.toolsListPayload(id: round * 10), token: token,
                session: session)
            #expect(list.status == 200, "round \(round): tools/list が 200 でない")
            let tools = try #require(
                (try list.json()["result"] as? [String: Any])?["tools"] as? [[String: Any]])
            #expect(tools.count == 4)

            session.invalidateAndCancel()
        }
    }

    /// `ambient_context_get_policy` は docs/tool-spec.md の形 (C# `LocalContextPolicyResponse`) を返す。
    @Test("tools_call_get_policy_returns_policy_shape")
    func toolsCallGetPolicyReturnsPolicyShape() async throws {
        let payload = try await callTool(name: "ambient_context_get_policy")

        for key in [
            "observedAt", "source", "transmissionPolicy", "privacyClassifications",
            "effectivePolicies", "observedStateCount", "outboundStateCount",
            "internalEventHistoryCount", "outboundEventCandidateCount",
            "retainedOutboundEventCount", "retention"
        ] {
            #expect(payload[key] != nil, "get_policy の応答に \(key) が無い")
        }
        #expect(payload["source"] as? String == "privacyClassifications")
        // まだ snapshot を ingest していない Hub なのでカタログは空配列。型だけ確認する。
        #expect(payload["privacyClassifications"] as? [Any] != nil)
        #expect(payload["effectivePolicies"] as? [Any] != nil)
    }

    /// `ambient_context_get_states` も同じく C# の `LocalContextStateResponse` の形。
    @Test("tools_call_get_states_returns_state_shape")
    func toolsCallGetStatesReturnsStateShape() async throws {
        let payload = try await callTool(
            name: "ambient_context_get_states",
            arguments: ["scopes": ["context.all:read"], "includeMetadata": true])

        for key in ["observedAt", "states", "source", "policyVersion"] {
            #expect(payload[key] != nil, "get_states の応答に \(key) が無い")
        }
        #expect(payload["source"] as? String == "outboundStates")
        #expect(payload["states"] as? [Any] != nil)
    }

    /// 引数が省略されても既定値で動く (C# SDK の引数束縛と同じ)。
    @Test("tools_call_accepts_absent_and_null_arguments")
    func toolsCallAcceptsAbsentAndNullArguments() async throws {
        _ = try await callTool(name: "ambient_context_get_states")
        _ = try await callTool(
            name: "ambient_context_get_states",
            arguments: ["names": NSNull(), "scopes": NSNull(), "includeMetadata": false])
        let events = try await callTool(
            name: "ambient_context_poll_events",
            arguments: ["limit": 10, "includePayload": false, "clientId": "unit-test"])
        #expect(events["nextCursor"] != nil)
        #expect(events["retention"] != nil)
    }

    /// 解析できない `since` は例外ではなく isError の結果として `ContextToolsError` の文言で返す。
    @Test("invalid_since_surfaces_as_tool_error")
    func invalidSinceSurfacesAsToolError() async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let response = try await TestHTTP.rpc(
            server.mcpUrl,
            payload: TestHTTP.toolsCallPayload(
                name: "ambient_context_poll_events", arguments: ["since": "not-a-timestamp"]),
            token: server.token)
        #expect(response.status == 200)

        let result = try #require(try response.json()["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
        let text = try #require(
            ((result["content"] as? [[String: Any]])?.first)?["text"] as? String)
        #expect(text == "'since' must be an ISO 8601 timestamp such as 2026-05-10T00:00:00+09:00.")
    }

    @Test("unknown_tool_is_an_error_result")
    func unknownToolIsAnErrorResult() async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let response = try await TestHTTP.rpc(
            server.mcpUrl,
            payload: TestHTTP.toolsCallPayload(name: "ambient_context_nope"),
            token: server.token)
        let result = try #require(try response.json()["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    // MARK: - ヘルパ

    /// ツールを呼び、単一の text コンテンツを JSON としてパースして返す。
    private func callTool(name: String, arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let response = try await TestHTTP.rpc(
            server.mcpUrl,
            payload: TestHTTP.toolsCallPayload(name: name, arguments: arguments),
            token: server.token)
        #expect(response.status == 200)

        let result = try #require(
            try response.json()["result"] as? [String: Any], "result が無い: \(response.text)")
        #expect(result["isError"] as? Bool == false)
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.count == 1, "text コンテンツは 1 件だけのはず")
        #expect(content[0]["type"] as? String == "text")
        let text = try #require(content[0]["text"] as? String)
        return try #require(
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
            "ツールの戻り値が JSON オブジェクトでない: \(text)")
    }
}
