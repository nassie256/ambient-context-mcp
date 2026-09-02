import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

/// `StatelessHTTPServerTransport` の前に置く SwiftNIO の HTTP/1.1 アダプタ。
///
/// Hummingbird は不要 (PoC 1)。`configureHTTPServerPipeline()` が keep-alive / chunked body /
/// `Expect: 100-continue` を面倒見てくれる。ここでやることは
/// NIO ↔ `MCP.HTTPRequest`/`HTTPResponse` の変換と、認証の事前チェックだけ。
public actor McpHttpServer {
    /// C# の `MapMcp("/mcp")` + `StartsWithSegments("/mcp")` に対応するパス接頭辞。
    public static let endpointPrefix = "/mcp"

    public enum StartError: Error, CustomStringConvertible {
        /// bind に失敗 (ポート使用中など)。Windows 版は致命エラーダイアログにポート番号を出す。
        case bindFailed(host: String, port: Int, underlying: any Error)
        case alreadyRunning

        public var description: String {
            switch self {
            case .bindFailed(let host, let port, let underlying):
                return "Failed to listen on \(host):\(port): \(underlying)"
            case .alreadyRunning:
                return "The MCP HTTP server is already running."
            }
        }
    }

    private let transport: StatelessHTTPServerTransport
    private let tokenProvider: @Sendable () -> String

    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    /// - Parameters:
    ///   - transport: `AmbientMcpServer.makeTransport()` で作った stateless transport。
    ///   - tokenProvider: リクエストごとに現在のトークンを取る。設定画面での再生成に追従するため
    ///     値ではなくクロージャで受ける (`McpServerHost.reloadSettings()` 後も有効)。
    public init(
        transport: StatelessHTTPServerTransport,
        tokenProvider: @escaping @Sendable () -> String
    ) {
        self.transport = transport
        self.tokenProvider = tokenProvider
    }

    /// 実際に bind したポート (port: 0 を渡した場合の解決用)。
    public private(set) var boundPort: Int = 0

    public func start(host: String = "127.0.0.1", port: Int) async throws {
        guard channel == nil else { throw StartError.alreadyRunning }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(McpHttpHandler(server: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        do {
            let channel = try await bootstrap.bind(host: host, port: port).get()
            self.group = group
            self.channel = channel
            self.boundPort = channel.localAddress?.port ?? port
        } catch {
            try? await group.shutdownGracefully()
            throw StartError.bindFailed(host: host, port: port, underlying: error)
        }
    }

    public func stop() async {
        if let channel {
            try? await channel.close()
            self.channel = nil
        }
        if let group {
            try? await group.shutdownGracefully()
            self.group = nil
        }
        boundPort = 0
    }

    /// リクエスト 1 件の処理。`/mcp` 配下のみ認証を掛け、それ以外は 404 (C# の
    /// `StartsWithSegments("/mcp")` と同じ範囲)。
    func handle(_ request: HTTPRequest) async -> RawHTTPResponse {
        guard isMcpPath(request.path ?? "") else {
            return RawHTTPResponse(
                status: 404,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"not_found"}"#.utf8))
        }
        if let failure = McpAuthentication.check(request, token: tokenProvider()) {
            return RawHTTPResponse(
                status: failure.status, headers: failure.headers, body: failure.body)
        }
        return RawHTTPResponse(await transport.handleRequest(request))
    }

    /// `/mcp` / `/mcp/` / `/mcp/foo` は該当、`/mcpx` は非該当 (`PathString.StartsWithSegments` と同じ)。
    private func isMcpPath(_ path: String) -> Bool {
        guard path.hasPrefix(Self.endpointPrefix) else { return false }
        let rest = path.dropFirst(Self.endpointPrefix.count)
        return rest.isEmpty || rest.hasPrefix("/")
    }
}

/// NIO に書き戻す最小のレスポンス表現。
struct RawHTTPResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data?

    init(status: Int, headers: [String: String], body: Data?) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// stateless transport は `.stream` を返さないので `bodyData` だけで足りる。
    init(_ response: HTTPResponse) {
        self.status = response.statusCode
        self.headers = response.headers
        self.body = response.bodyData
    }
}

private final class McpHttpHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: McpHttpServer
    private var head: HTTPRequestHead?
    private var body: ByteBuffer?

    init(server: McpHttpServer) {
        self.server = server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            self.body = context.channel.allocator.buffer(capacity: 0)
        case .body(var buffer):
            self.body?.writeBuffer(&buffer)
        case .end:
            guard let head = self.head, let body = self.body else { return }
            self.head = nil
            self.body = nil

            let request = Self.makeRequest(head: head, body: body)
            let version = head.version
            // ChannelHandlerContext は EventLoop 外に持ち出せないので、書き戻しは必ず
            // ctx.eventLoop.execute の中で行う (PoC 1 の落とし穴 4)。
            nonisolated(unsafe) let ctx = context
            Task {
                let response = await self.server.handle(request)
                ctx.eventLoop.execute { self.write(response, version: version, context: ctx) }
            }
        }
    }

    private static func makeRequest(head: HTTPRequestHead, body: ByteBuffer) -> HTTPRequest {
        var headers: [String: String] = [:]
        for (name, value) in head.headers {
            headers[name] = headers[name].map { $0 + ", " + value } ?? value
        }
        let path = String(head.uri.split(separator: "?").first ?? Substring(head.uri))
        let data = body.readableBytes > 0
            ? Data(body.getBytes(at: 0, length: body.readableBytes) ?? [])
            : nil
        return HTTPRequest(method: head.method.rawValue, headers: headers, body: data, path: path)
    }

    private func write(_ response: RawHTTPResponse, version: HTTPVersion, context: ChannelHandlerContext) {
        var head = HTTPResponseHead(
            version: version, status: HTTPResponseStatus(statusCode: response.status))
        for (name, value) in response.headers {
            head.headers.add(name: name, value: value)
        }
        // SDK の HTTPResponse には Content-Length が入っていない。付けないと keep-alive がハングする。
        head.headers.replaceOrAdd(name: "Content-Length", value: String(response.body?.count ?? 0))
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if let data = response.body, !data.isEmpty {
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
