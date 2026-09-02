import Foundation

/// StdioBridge の I/O 部分 (discovery 監視・トレイ起動・HTTP 中継)。
/// C# 版 `Program.cs` の `EnsureUpstreamReadyAsync` / `ProxyLoopAsync` / `ForwardAsync` に対応する。

struct BridgeStartupError: Error {
    let message: String
}

enum Bridge {
    static let startupWaitMs = 20_000
    static let startupPollIntervalMs = 250
    static let healthCheckTimeout: TimeInterval = 1.5
    static let requestTimeout: TimeInterval = 120
    /// Windows 版が .NET ランタイムの導入を案内する位置に置く、macOS 固有の案内。
    static let gatekeeperHint =
        "If the app was blocked by Gatekeeper, move it to /Applications and allow it in "
        + "System Settings → Privacy & Security."

    // MARK: - 起動

    /// トレイ (.app もしくは開発用の裸実行ファイル) の起動方法。
    enum TrayTarget {
        case app(String)
        case executable(String)

        var path: String {
            switch self {
            case .app(let path), .executable(let path): return path
            }
        }
    }

    /// discovery ファイルが健全ならそれを返し、駄目なら同梱トレイを起動して待つ。
    static func ensureUpstreamReady() async throws -> Discovery {
        let discoveryPath = DiscoveryFile.resolvePath()

        if let existing = DiscoveryFile.read(path: discoveryPath), await isHealthy(existing) {
            return existing
        }

        guard let tray = resolveTrayTarget() else {
            throw BridgeStartupError(
                message:
                    "Cannot locate \"Ambient Context MCP.app\" (or ambient-mcp) next to this binary. "
                    + "The bundle appears to be incomplete.")
        }

        let child = try launch(tray)

        let deadline = Date().addingTimeInterval(Double(startupWaitMs) / 1000)
        while Date() < deadline {
            if let child, !child.isRunning {
                throw BridgeStartupError(
                    message:
                        "\(tray.path) exited with code \(child.terminationStatus) before becoming "
                        + "responsive. \(gatekeeperHint)")
            }

            try? await Task.sleep(nanoseconds: UInt64(startupPollIntervalMs) * 1_000_000)

            if let discovery = DiscoveryFile.read(path: discoveryPath), await isHealthy(discovery) {
                return discovery
            }
        }

        throw BridgeStartupError(
            message:
                "Ambient Context MCP did not publish a usable discovery file within "
                + "\(startupWaitMs / 1000) seconds. \(gatekeeperHint)")
    }

    /// 1) `AMBIENT_MCP_APP_PATH` 2) 実行ファイルと同じディレクトリの `.app` 3) 同ディレクトリの
    /// 裸実行ファイル `ambient-mcp` (開発用) の順に探す。
    static func resolveTrayTarget(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        executableDirectory: String = Bridge.executableDirectory()
    ) -> TrayTarget? {
        if let override = environment["AMBIENT_MCP_APP_PATH"], !override.isEmpty,
            let target = classify(path: override) {
            return target
        }

        let directory = executableDirectory as NSString
        let bundled = directory.appendingPathComponent("Ambient Context MCP.app")
        if let target = classify(path: bundled) {
            return target
        }
        return classify(path: directory.appendingPathComponent("ambient-mcp"))
    }

    private static func classify(path: String) -> TrayTarget? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return path.hasSuffix(".app") ? .app(path) : nil
        }
        return .executable(path)
    }

    static func executableDirectory() -> String {
        let executable =
            Bundle.main.executableURL?.resolvingSymlinksInPath()
            ?? URL(fileURLWithPath: CommandLine.arguments.first ?? ".").resolvingSymlinksInPath()
        return executable.deletingLastPathComponent().path
    }

    /// `.app` は `open -g -a` に任せる (launchd 配下で起動され、この プロセスの子にはならない)。
    /// 裸実行ファイルは Process で直接起動し、stdio は一切継承させない。
    /// 戻り値が nil なら「子プロセスとして監視できない」= .app 経路。
    private static func launch(_ tray: TrayTarget) throws -> Process? {
        switch tray {
        case .app(let path):
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-a", path]
            open.standardInput = FileHandle.nullDevice
            open.standardOutput = FileHandle.nullDevice
            open.standardError = FileHandle.nullDevice
            do {
                try open.run()
            } catch {
                throw BridgeStartupError(
                    message: "Failed to launch \(path) via /usr/bin/open: "
                        + "\(error.localizedDescription). \(gatekeeperHint)")
            }
            open.waitUntilExit()
            if open.terminationStatus != 0 {
                throw BridgeStartupError(
                    message:
                        "/usr/bin/open failed to launch \(path) (exit code "
                        + "\(open.terminationStatus)). \(gatekeeperHint)")
            }
            return nil

        case .executable(let path):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                throw BridgeStartupError(
                    message: "Failed to launch \(path): \(error.localizedDescription). "
                        + gatekeeperHint)
            }
            return process
        }
    }

    // MARK: - HTTP

    /// baseUrl に GET して、HTTP 応答が返れば (401/404 でも) リスナは生きているとみなす。
    static func isHealthy(_ discovery: Discovery) async -> Bool {
        guard let url = URL(string: discovery.baseUrl) else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = healthCheckTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        do {
            _ = try await URLSession.shared.data(for: request)
            return true
        } catch {
            return false
        }
    }

    /// 1 行の JSON-RPC を上流へ POST し、stdout に書くべきバイト列を返す。
    static func forward(discovery: Discovery, jsonRpcLine: String) async throws -> Data? {
        guard let url = URL(string: discovery.mcpUrl) else {
            throw BridgeStartupError(message: "Invalid mcpUrl in discovery file: \(discovery.mcpUrl)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(discovery.token)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(jsonRpcLine.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse {
            if http.statusCode == 202 || http.statusCode == 204 {
                return nil
            }
            if let contentType = http.value(forHTTPHeaderField: "Content-Type"),
                contentType.lowercased().hasPrefix("text/event-stream") {
                guard let text = String(data: data, encoding: .utf8),
                    let block = SseParser.firstDataBlock(text)
                else {
                    return nil
                }
                return Data(block.utf8)
            }
        }

        return data.isEmpty ? nil : data
    }

    // MARK: - 中継ループ

    /// stdin を 1 行ずつ読み、空行は捨て、それ以外は上流へ中継する。
    static func proxyLoop(discovery: Discovery) async {
        let stdout = FileHandle.standardOutput
        while let rawLine = readLine(strippingNewline: true) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty { continue }

            var responseBytes: Data?
            do {
                responseBytes = try await forward(discovery: discovery, jsonRpcLine: line)
            } catch {
                responseBytes = LocalErrorResponse.make(
                    requestLine: line, message: errorMessage(error))
            }

            if let responseBytes, !responseBytes.isEmpty {
                var payload = responseBytes
                payload.append(0x0A)
                stdout.write(payload)
            }
        }
    }

    /// C# の `Exception.Message` 相当の短い説明。
    static func errorMessage(_ error: Error) -> String {
        if let startup = error as? BridgeStartupError { return startup.message }
        return (error as NSError).localizedDescription
    }

    static func logToStderr(_ message: String) {
        FileHandle.standardError.write(Data("ambient-mcp-stdio: \(message)\n".utf8))
    }
}
