import Foundation
import MCP
import Testing
@testable import AmbientContextMcpServer

/// `tools/list` の契約検証。C# 版から生成した `src/macos/Fixtures/contract/tools-list.json` が
/// 唯一の正解で、Swift 実装の出力はそれと値が一致していなければならない (設計メモ §3.5 / §5)。
///
/// 比較は 2 段構え:
/// 1. フィクスチャを SDK の `Tool` にデコードし、`AmbientContextTools.all` と `==` で比較する。
///    キー順や `—` 形式のエスケープ差は JSON デコードの時点で消えるので、意味論だけが残る。
/// 2. 実際に HTTP で `tools/list` を叩き、返ってきた JSON を生のフィクスチャ JSON と
///    フィールドごとに深く比較する。1 では見えないシリアライズ側の欠落 (例: `properties: {}` が
///    落ちる、`default: null` が消える) を捕まえる。
@Suite("ToolsListFixture")
struct ToolsListFixtureTests {
    struct FixtureToolsList: Decodable {
        let tools: [Tool]
    }

    static func fixtureData() throws -> Data {
        let directory = try #require(
            Fixtures.contractDirectory,
            "契約フィクスチャのディレクトリが見つからない (mcpb/manifest.json を持つ親を探索した)")
        let url = directory.appendingPathComponent("tools-list.json")
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "tools-list.json が存在しない: \(url.path)")
        return try Data(contentsOf: url)
    }

    // MARK: - 1. デコードした Tool 同士の比較

    @Test("tool_definitions_match_fixture")
    func toolDefinitionsMatchFixture() throws {
        let expected = try JSONDecoder().decode(FixtureToolsList.self, from: Self.fixtureData()).tools
        let actual = AmbientContextTools.all

        #expect(actual.count == expected.count)
        #expect(actual.map(\.name) == expected.map(\.name), "ツールの並びが一致しない")

        for tool in expected {
            let found = try #require(
                actual.first { $0.name == tool.name }, "ツール \(tool.name) が実装側に無い")
            #expect(found.title == tool.title, "\(tool.name): title が一致しない")
            #expect(found.description == tool.description, "\(tool.name): description が一致しない")
            #expect(found.inputSchema == tool.inputSchema, "\(tool.name): inputSchema が一致しない")
            #expect(found.annotations == tool.annotations, "\(tool.name): annotations が一致しない")
        }
    }

    /// 引数なしツールの `properties` は「省略」ではなく「空オブジェクト」でなければならない。
    @Test("parameterless_tools_keep_empty_properties")
    func parameterlessToolsKeepEmptyProperties() throws {
        for tool in [AmbientContextTools.getPolicy, AmbientContextTools.describeEvents] {
            let properties = try #require(
                tool.inputSchema.objectValue?["properties"], "\(tool.name): properties が無い")
            #expect(properties == .object([:]), "\(tool.name): properties が空オブジェクトでない")
        }
    }

    /// nullable な配列引数は C# SDK のリフレクション出力どおり `["array","null"]` + `default: null`。
    @Test("nullable_array_arguments_keep_union_type_and_null_default")
    func nullableArrayArgumentsKeepUnionTypeAndNullDefault() throws {
        let cases: [(Tool, String)] = [
            (AmbientContextTools.getStates, "names"),
            (AmbientContextTools.getStates, "scopes"),
            (AmbientContextTools.pollEvents, "names"),
            (AmbientContextTools.pollEvents, "scopes")
        ]
        for (tool, argument) in cases {
            let schema = try #require(
                tool.inputSchema.objectValue?["properties"]?.objectValue?[argument]?.objectValue,
                "\(tool.name).\(argument) が無い")
            #expect(schema["type"] == .array([.string("array"), .string("null")]))
            #expect(schema["default"] == .null)
            #expect(schema["items"]?.objectValue?["type"]
                == .array([.string("string"), .string("null")]))
        }
    }

    // MARK: - 2. 実 HTTP レスポンスとの深い比較

    @Test("tools_list_over_http_matches_fixture_json")
    func toolsListOverHttpMatchesFixtureJson() async throws {
        let expected = try JSONSerialization.jsonObject(with: Self.fixtureData()) as! [String: Any]
        let expectedTools = expected["tools"] as! [[String: Any]]

        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let response = try await TestHTTP.rpc(
            server.mcpUrl, payload: TestHTTP.toolsListPayload(), token: server.token)
        #expect(response.status == 200)

        let result = try #require(try response.json()["result"] as? [String: Any])
        let actualTools = try #require(result["tools"] as? [[String: Any]])
        #expect(actualTools.map { $0["name"] as? String } == expectedTools.map { $0["name"] as? String })

        for expectedTool in expectedTools {
            let name = expectedTool["name"] as! String
            let actualTool = try #require(
                actualTools.first { $0["name"] as? String == name }, "\(name) が応答に無い")
            for key in ["title", "description"] {
                #expect(
                    actualTool[key] as? String == expectedTool[key] as? String,
                    "\(name): \(key) が一致しない")
            }
            for key in ["inputSchema", "annotations"] {
                let actualValue = actualTool[key] as? NSDictionary
                let expectedValue = expectedTool[key] as? NSDictionary
                #expect(actualValue == expectedValue, "\(name): \(key) が一致しない")
            }
        }
    }
}
