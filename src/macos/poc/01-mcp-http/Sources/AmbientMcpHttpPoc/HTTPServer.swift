import Foundation
import MCP
@preconcurrency import NIOCore
@preconcurrency import NIOHTTP1
@preconcurrency import NIOPosix

/// Minimal SwiftNIO adapter in front of `StatelessHTTPServerTransport`.
/// No Hummingbird: `configureHTTPServerPipeline()` already gives us keep-alive,
/// chunked bodies and `Expect: 100-continue` handling.
actor PocHTTPServer {
    let host: String
    let port: Int
    let endpoint: String
    let token: String
    let transport: StatelessHTTPServerTransport

    private var channel: Channel?

    init(host: String, port: Int, endpoint: String, token: String, transport: StatelessHTTPServerTransport) {
        self.host = host
        self.port = port
        self.endpoint = endpoint
        self.token = token
        self.transport = transport
    }

    func run() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(PocHTTPHandler(server: self))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let channel = try await bootstrap.bind(host: host, port: port).get()
        self.channel = channel
        FileHandle.standardError.write(
            Data("ambient-mcp-poc listening on http://\(host):\(port)\(endpoint)\n".utf8))
        try await channel.closeFuture.get()
    }

    /// Auth pre-check (Windows middleware parity) then hand off to the SDK transport.
    func handle(_ request: HTTPRequest) async -> RawResponse {
        if request.path != endpoint {
            return RawResponse(
                status: 404,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"not_found"}"#.utf8))
        }
        if let failure = McpAuth.check(request, token: token) {
            return RawResponse(status: failure.status, headers: failure.headers, body: failure.body)
        }
        return RawResponse(await transport.handleRequest(request))
    }
}

struct RawResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var body: Data?

    init(status: Int, headers: [String: String], body: Data?) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// The stateless transport never returns `.stream`, so `bodyData` is enough.
    init(_ response: HTTPResponse) {
        self.status = response.statusCode
        self.headers = response.headers
        self.body = response.bodyData
    }
}

private final class PocHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let server: PocHTTPServer
    private var head: HTTPRequestHead?
    private var body: ByteBuffer?

    init(server: PocHTTPServer) {
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
        let data = body.readableBytes > 0 ? Data(body.getBytes(at: 0, length: body.readableBytes) ?? []) : nil
        return HTTPRequest(method: head.method.rawValue, headers: headers, body: data, path: path)
    }

    private func write(_ response: RawResponse, version: HTTPVersion, context: ChannelHandlerContext) {
        var head = HTTPResponseHead(
            version: version, status: HTTPResponseStatus(statusCode: response.status))
        for (name, value) in response.headers {
            head.headers.add(name: name, value: value)
        }
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
