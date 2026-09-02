import Foundation

/// PoC 用の簡易ログ。画面が見えない環境で挙動を検証するため、stdout と
/// AMBIENT_POC_LOG で指定されたファイルの両方へ追記する。
enum PocLog {
    nonisolated(unsafe) private static var handle: FileHandle?
    private static let lock = NSLock()

    static func start() {
        guard let path = ProcessInfo.processInfo.environment["AMBIENT_POC_LOG"] else { return }
        if !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(stamp)] \(message)\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        lock.lock()
        handle?.write(Data(line.utf8))
        lock.unlock()
    }
}
