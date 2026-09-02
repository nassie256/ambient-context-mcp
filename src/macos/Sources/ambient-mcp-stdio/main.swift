import Foundation

// Claude Desktop (MCPB) 用の薄い stdio→HTTP シム。
// C# 版 src/windows/AmbientContextMcp.StdioBridge/Program.cs の移植。
//
// ローカルで動いているトレイ (Streamable HTTP: 127.0.0.1:<port>/mcp) に JSON-RPC を
// 中継するだけで、Hub の状態は一切持たない。
// stdout は JSON-RPC 専用。診断は "ambient-mcp-stdio: " 前置きで stderr に出す。

do {
    let discovery = try await Bridge.ensureUpstreamReady()
    await Bridge.proxyLoop(discovery: discovery)
    exit(0)
} catch let error as BridgeStartupError {
    Bridge.logToStderr(error.message)
    exit(1)
} catch {
    Bridge.logToStderr("unexpected error: \(Bridge.errorMessage(error))")
    exit(1)
}
