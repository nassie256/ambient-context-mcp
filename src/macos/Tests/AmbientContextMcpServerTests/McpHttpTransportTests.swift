import AmbientContextCore
import Darwin
import Foundation
import MCP
import Testing
@testable import AmbientContextMcpServer

/// NIO アダプタ (`McpHttpServer` の `McpHttpHandler`) と transport の多重化まわりの回帰テスト。
@Suite("McpHttpTransport")
struct McpHttpTransportTests {
    /// 応答を書き戻す前にクライアントが切断してもサーバが落ちないこと。
    ///
    /// 以前は `ChannelHandlerContext` を `Task` に持ち出して await の後に書いていたため、
    /// 切断済み (= パイプラインから外れた) context への書き込みになっていた。
    /// 書き戻しは `Channel` 経由に変えてある。
    @Test("client_disconnect_before_response_does_not_kill_server")
    func clientDisconnectBeforeResponseDoesNotKillServer() async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let payload = try JSONSerialization.data(
            withJSONObject: TestHTTP.toolsCallPayload(name: "ambient_context_get_states"))
        let request = RawTCP.httpRequest(
            path: "/mcp", token: server.token, body: payload, version: "HTTP/1.1")

        // 送ってすぐ RST で切る、を何度も繰り返す。1 回でも context 経由の write が
        // 生きていればここで落ちる。
        for _ in 0..<25 {
            try RawTCP.sendAndAbort(port: server.port, request: request)
        }

        // サーバは生きていて次のリクエストを普通に処理できる。
        let after = try await TestHTTP.rpc(
            server.mcpUrl,
            payload: TestHTTP.toolsCallPayload(name: "ambient_context_get_states"),
            token: server.token)
        #expect(after.status == 200)
        #expect(try after.json()["result"] as? [String: Any] != nil)
    }

    /// `Connection: close` を送ったら応答後に閉じること (以前は keep-alive のまま開きっぱなし)。
    @Test("connection_close_is_honoured")
    func connectionCloseIsHonoured() async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let payload = try JSONSerialization.data(
            withJSONObject: TestHTTP.toolsListPayload())
        let response = try RawTCP.exchange(
            port: server.port,
            request: RawTCP.httpRequest(
                path: "/mcp", token: server.token, body: payload,
                version: "HTTP/1.1", extraHeaders: ["Connection": "close"]))

        #expect(response.hasPrefix("HTTP/1.1 200"))
        #expect(response.lowercased().contains("connection: close"))
        // exchange は EOF まで読む。戻ってきた時点でサーバが閉じたことの証明。
        #expect(response.contains("\"result\""))
    }

    /// HTTP/1.0 は既定が close。keep-alive を明示していないので応答後に閉じる。
    @Test("http_1_0_closes_after_response")
    func http10ClosesAfterResponse() async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }

        let payload = try JSONSerialization.data(withJSONObject: TestHTTP.toolsListPayload())
        let response = try RawTCP.exchange(
            port: server.port,
            request: RawTCP.httpRequest(
                path: "/mcp", token: server.token, body: payload, version: "HTTP/1.0"))

        #expect(response.hasPrefix("HTTP/1.0 200"))
        #expect(response.lowercased().contains("connection: close"))
        #expect(response.contains("\"result\""))
    }

    /// クライアントが選んだ JSON-RPC id は衝突しうる。
    /// transport を 1 個共有していた頃は、同じ id の同時リクエストで
    /// `responseWaiters[id]` が上書きされ、先行リクエストが永久にハングしていた。
    @Test("concurrent_requests_with_the_same_id_both_get_answered")
    func concurrentRequestsWithTheSameIdBothGetAnswered() async throws {
        let server = try await TestServer()
        defer { Task { await server.shutdown() } }
        let url = server.mcpUrl
        let token = server.token

        // Any は Sendable でないので、子タスクからは生のボディ (Data) だけ持ち帰る。
        let bodies = await withTaskGroup(of: (Int, Data)?.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let tool = index.isMultiple(of: 2)
                        ? "ambient_context_get_states" : "ambient_context_get_policy"
                    guard let response = try? await TestHTTP.rpc(
                        url,
                        payload: TestHTTP.toolsCallPayload(id: 1, name: tool),
                        token: token,
                        session: URLSession(configuration: .ephemeral))
                    else { return nil }
                    return (index, response.body)
                }
            }
            var collected: [(Int, Data)] = []
            for await item in group {
                if let item { collected.append(item) }
            }
            return collected
        }

        #expect(bodies.count == 8, "同じ id の同時リクエストが全部返らなかった")
        for (index, body) in bodies {
            let json = try #require(
                try JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(json["id"] as? Int == 1, "\(index): id が保たれていない")
            let result = json["result"] as? [String: Any]
            #expect(result != nil, "\(index): result が無い (\(json))")
            #expect(result?["isError"] as? Bool == false, "\(index): ツールがエラーを返した")
        }
    }

    /// タイムアウトヘルパは、間に合わなければ nil を返して呼び出し側を解放する。
    @Test("request_timeout_helper_returns_nil_when_operation_is_slow")
    func requestTimeoutHelperReturnsNilWhenOperationIsSlow() async throws {
        let value = await McpHttpServer.withTimeout(seconds: 0.05) {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return HTTPResponse.data(Data())
        }
        #expect(value == nil)
    }
}

// MARK: - 生ソケットのクライアント

/// URLSession では表現できない「応答前に切断」「HTTP/1.0」を作るための最小クライアント。
enum RawTCP {
    static func httpRequest(
        path: String,
        token: String,
        body: Data,
        version: String,
        extraHeaders: [String: String] = [:]
    ) -> Data {
        var headers = [
            "Host": "127.0.0.1",
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
            "Accept": "application/json, text/event-stream",
            "Content-Length": String(body.count)
        ]
        for (name, value) in extraHeaders { headers[name] = value }
        var text = "POST \(path) \(version)\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        return Data(text.utf8) + body
    }

    /// リクエストを送ってから即座に RST で切る (応答は読まない)。
    static func sendAndAbort(port: Int, request: Data) throws {
        let fd = try connect(port: port)
        // SO_LINGER {on, 0} → close() が FIN ではなく RST を送る = 確実に即死させる。
        var linger = linger(l_onoff: 1, l_linger: 0)
        setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
        _ = try write(fd, request)
        close(fd)
    }

    /// リクエストを送り、サーバが接続を閉じる (EOF) まで読んで返す。
    static func exchange(port: Int, request: Data) throws -> String {
        let fd = try connect(port: port)
        defer { close(fd) }

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        _ = try write(fd, request)

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let read = recv(fd, &buffer, buffer.count, 0)
            if read <= 0 { break }
            received.append(contentsOf: buffer[0..<read])
        }
        return String(decoding: received, as: UTF8.self)
    }

    private static func connect(port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket(errno) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let code = errno
            close(fd)
            throw Failure.connect(code)
        }
        return fd
    }

    private static func write(_ fd: Int32, _ data: Data) throws -> Int {
        try data.withUnsafeBytes { raw -> Int in
            var sent = 0
            while sent < raw.count {
                let written = send(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent, 0)
                guard written > 0 else { throw Failure.write(errno) }
                sent += written
            }
            return sent
        }
    }

    enum Failure: Error {
        case socket(Int32)
        case connect(Int32)
        case write(Int32)
    }
}
