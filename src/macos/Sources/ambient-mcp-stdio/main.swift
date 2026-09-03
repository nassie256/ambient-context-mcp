import Foundation

// Claude Desktop (MCPB) 用の薄い stdio→HTTP シム。
// C# 版 src/windows/AmbientContextMcp.StdioBridge/Program.cs の移植。
//
// ローカルで動いているトレイ (Streamable HTTP: 127.0.0.1:<port>/mcp) に JSON-RPC を
// 中継するだけで、Hub の状態は一切持たない。
// stdout は JSON-RPC 専用。診断は "ambient-mcp-stdio: " 前置きで stderr に出す。

// クライアント (Claude Desktop) が先に落ちて stdout の読み手が消えたとき、既定の SIGPIPE では
// 診断を一切残さずシグナル死 (シェルから見ると exit 141) する。無視して write の EPIPE を
// 受け取り、stderr に理由を書いてから 1 で終わる (C# の "unexpected error" → return 1 と同じ扱い)。
signal(SIGPIPE, SIG_IGN)

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
