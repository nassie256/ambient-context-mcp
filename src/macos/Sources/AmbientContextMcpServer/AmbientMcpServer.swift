import AmbientContextCore
import Foundation
import MCP

/// swift-sdk の `Server` を組み立てて transport に載せるファクトリ。
///
/// Windows 版の `Program.cs` (`AddMcpServer().WithHttpTransport().WithTools<ContextTools>()`) に対応する。
public enum AmbientMcpServer {
    /// `serverInfo.version`。リリース時は mcpb/manifest.json と揃える。
    public static let version = "0.7.1"

    public static let info = Server.Info(name: "ambient-context-mcp", version: version)

    public static let capabilities = Server.Capabilities(tools: .init(listChanged: false))

    /// stateless transport。SDK 既定の validation pipeline には `OriginValidator.localhost()` が
    /// 含まれるが、これは Windows 版より厳しく (`https://localhost` を 403、非ループバック `Host` を 421)
    /// 契約が変わるため使わない。Origin は `McpAuthentication` が C# と同一ロジックで検査する。
    public static func makeTransport() -> StatelessHTTPServerTransport {
        StatelessHTTPServerTransport(
            validationPipeline: StandardValidationPipeline(validators: [
                AcceptHeaderValidator(mode: .jsonOnly),
                ContentTypeValidator(),
                ProtocolVersionValidator()
            ]))
    }

    /// `Server` を作り、transport に接続し、ハンドラを登録して返す。
    ///
    /// `Server.start(transport:)` は **その中で** 既定ハンドラを (再) 登録するため、
    /// `withMethodHandler` による上書きは必ず `start()` の後で行うこと (PoC 1 の落とし穴 1)。
    @discardableResult
    public static func makeAndStart(
        transport: StatelessHTTPServerTransport,
        hub: LocalContextHub
    ) async throws -> Server {
        let server = Server(name: info.name, version: info.version, capabilities: capabilities)
        try await server.start(transport: transport)
        await registerHandlers(on: server, hub: hub)
        return server
    }

    public static func registerHandlers(on server: Server, hub: LocalContextHub) async {
        // SDK 既定の initialize ハンドラは 2 回目以降を "Server is already initialized" (-32600) で
        // 拒否する。stateless では 1 個の長命な Server がクライアントごとに initialize を受けるので、
        // そのままだと 2 番目以降のクライアントが全て壊れる。冪等なハンドラで上書きする。
        // `Version.negotiate` は internal なので交渉は自前 2 行。
        await server.withMethodHandler(Initialize.self) { params in
            let negotiated = Version.supported.contains(params.protocolVersion)
                ? params.protocolVersion
                : Version.latest
            return Initialize.Result(
                protocolVersion: negotiated,
                capabilities: capabilities,
                serverInfo: info)
        }

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: AmbientContextTools.all)
        }

        await server.withMethodHandler(CallTool.self) { params in
            AmbientContextToolDispatch.call(name: params.name, arguments: params.arguments, hub: hub)
                ?? AmbientContextToolDispatch.errorText("Unknown tool: \(params.name)")
        }
    }
}
