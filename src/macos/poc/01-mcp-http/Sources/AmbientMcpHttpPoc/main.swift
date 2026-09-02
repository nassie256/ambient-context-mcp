import Foundation
import MCP

let environment = ProcessInfo.processInfo.environment
let port = environment["AMBIENT_PORT"].flatMap(Int.init) ?? 37690
let token = environment["AMBIENT_TOKEN"] ?? "poc-token"

// The SDK's default pipeline includes `OriginValidator.localhost()`, which is
// stricter than the Windows middleware (it rejects `https://localhost` origins
// and 421s on a non-loopback `Host`). Origin is enforced by `McpAuth` instead,
// so drop it here and keep only the spec validators.
let transport = StatelessHTTPServerTransport(
    validationPipeline: StandardValidationPipeline(validators: [
        AcceptHeaderValidator(mode: .jsonOnly),
        ContentTypeValidator(),
        ProtocolVersionValidator(),
    ])
)
let server = makeServer()
// `Server.start` (re-)registers the SDK's default `initialize`/`ping` handlers,
// so our overrides must be installed AFTER it. No client can reach the server
// yet — the HTTP listener is bound below.
try await server.start(transport: transport)
await registerHandlers(on: server)

let httpServer = PocHTTPServer(
    host: "127.0.0.1",
    port: port,
    endpoint: "/mcp",
    token: token,
    transport: transport
)
try await httpServer.run()
