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

    /// 1 リクエストの処理に許す上限。超えたら 504 を返して接続を解放する
    /// (SDK 側の continuation が何らかの理由で resume されなくても無限待ちにしない)。
    public static let requestTimeoutSeconds: Double = 60

    private let pipelineFactory: @Sendable () async throws -> AmbientMcpServer.RequestPipeline
    private let tokenProvider: @Sendable () -> String

    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    /// - Parameters:
    ///   - pipelineFactory: リクエスト 1 件分の transport + Server を作るファクトリ
    ///     (`AmbientMcpServer.makePipeline(hub:)`)。共有すると JSON-RPC id の衝突で
    ///     リクエストがハングするため、必ずリクエストごとに新しい組を返すこと。
    ///   - tokenProvider: リクエストごとに現在のトークンを取る。設定画面での再生成に追従するため
    ///     値ではなくクロージャで受ける (`McpServerHost.reloadSettings()` 後も有効)。
    public init(
        pipelineFactory: @escaping @Sendable () async throws -> AmbientMcpServer.RequestPipeline,
        tokenProvider: @escaping @Sendable () -> String
    ) {
        self.pipelineFactory = pipelineFactory
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

        let pipeline: AmbientMcpServer.RequestPipeline
        do {
            pipeline = try await pipelineFactory()
        } catch {
            return RawHTTPResponse(
                status: 500,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"server_unavailable"}"#.utf8))
        }

        let response = await Self.withTimeout(seconds: Self.requestTimeoutSeconds) {
            await pipeline.transport.handleRequest(request)
        }
        // shutdown は必ず行う。タイムアウトで見捨てた処理も、ここで continuation が解放される。
        await pipeline.shutdown()

        guard let response else {
            return RawHTTPResponse(
                status: 504,
                headers: ["Content-Type": "application/json"],
                body: Data(#"{"error":"timeout"}"#.utf8))
        }
        return RawHTTPResponse(response)
    }

    /// `operation` の結果を `seconds` まで待ち、間に合わなければ nil を返す。
    ///
    /// TaskGroup は「子タスクが全部終わるまで戻らない」ので、キャンセルに反応しない
    /// SDK の継続待ちには使えない。見捨てた処理は後で勝手に完了して破棄される。
    static func withTimeout(
        seconds: Double,
        operation: @escaping @Sendable () async -> HTTPResponse
    ) async -> HTTPResponse? {
        await withCheckedContinuation { (continuation: CheckedContinuation<HTTPResponse?, Never>) in
            let once = ResumeOnce(continuation)
            Task {
                let value = await operation()
                once.resume(with: value)
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                once.resume(with: nil)
            }
        }
    }

    /// 継続を高々 1 回だけ再開するラッパ (完了とタイムアウトの競合を吸収する)。
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<HTTPResponse?, Never>?

        init(_ continuation: CheckedContinuation<HTTPResponse?, Never>) {
            self.continuation = continuation
        }

        func resume(with value: HTTPResponse?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
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
            let keepAlive = head.isKeepAlive
            // `ChannelHandlerContext` は Sendable でなく、しかも **await をまたぐと既に
            // ハンドラがパイプラインから外れている可能性がある** (クライアントが応答前に
            // 切断した場合)。`Channel` は Sendable かつ切断後の write も安全に失敗するだけ
            // なので、非同期処理をまたぐ書き戻しは必ず channel 経由で行う。
            let channel = context.channel
            Task {
                let response = await self.server.handle(request)
                Self.write(
                    response, version: version, keepAlive: keepAlive, channel: channel)
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

    /// `Channel` 経由で応答を書き戻す。切断済みチャネルへの write は promise が
    /// `ChannelError.ioOnClosedChannel` で失敗するだけで、クラッシュにはならない。
    private static func write(
        _ response: RawHTTPResponse,
        version: HTTPVersion,
        keepAlive: Bool,
        channel: Channel
    ) {
        var head = HTTPResponseHead(
            version: version, status: HTTPResponseStatus(statusCode: response.status))
        for (name, value) in response.headers {
            head.headers.add(name: name, value: value)
        }
        // SDK の HTTPResponse には Content-Length が入っていない。付けないと keep-alive がハングする。
        head.headers.replaceOrAdd(name: "Content-Length", value: String(response.body?.count ?? 0))
        // `Connection: close` / HTTP/1.0 (keep-alive 明示なし) では応答後に閉じる。
        // HTTPResponseHead.isKeepAlive はこのヘッダを見て決まるので、リクエスト側の値を写す。
        if !keepAlive {
            head.headers.replaceOrAdd(name: "Connection", value: "close")
        } else if version.major == 1 && version.minor == 0 {
            // HTTP/1.0 の既定は close なので、keep-alive は明示しないと切られる。
            head.headers.replaceOrAdd(name: "Connection", value: "keep-alive")
        }

        let bodyPart: HTTPServerResponsePart? = response.body.flatMap { data in
            guard !data.isEmpty else { return nil }
            var buffer = channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            return .body(.byteBuffer(buffer))
        }
        let headPart = HTTPServerResponsePart.head(head)

        channel.eventLoop.execute {
            channel.write(headPart, promise: nil)
            if let bodyPart {
                channel.write(bodyPart, promise: nil)
            }
            let done = channel.writeAndFlush(HTTPServerResponsePart.end(nil))
            if !keepAlive {
                done.whenComplete { _ in channel.close(promise: nil) }
            }
        }
    }
}
