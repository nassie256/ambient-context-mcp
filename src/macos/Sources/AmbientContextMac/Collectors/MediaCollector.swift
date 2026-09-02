import AppKit
import Foundation

import AmbientContextCore

/// C# `WindowsMediaContextCollector` (SMTC) の macOS 版。
///
/// macOS には SMTC 相当の公開 API が無いため、Apple Events (`NSAppleScript`) で
/// Music.app / Spotify に問い合わせる (設計書 §3.4、PoC 3 の実装ルール)。
///
/// 実装上の必須ルール (PoC 3 RESULT.md §7):
/// 1. `NSRunningApplication.runningApplications(withBundleIdentifier:)` で起動中のプレイヤー
///    だけに問い合わせる (未起動アプリに `tell application` すると**起動してしまう**)
/// 2. 1500 ms のタイムアウトガード (Windows 版と同値)。超過時はスレッドを放棄する
/// 3. `duration` は Music が秒、Spotify がミリ秒。`player position` は両方秒
/// 4. AppleScript の変数名は 3 文字以上の非衝突名 (2 文字だと -2741 でコンパイル失敗)
/// 5. -1728 (トラック無し) / -1743 (権限拒否) を個別に reason へ写像する
public struct MediaCollector: Sendable {
    /// Windows 版 `MediaApiTimeout` と同値。
    public static let scriptTimeout: TimeInterval = 1.5

    /// 問い合わせ対象プレイヤー。
    public struct PlayerCandidate: Sendable, Hashable {
        public var bundleId: String
        public var displayName: String
        /// `tell application "..."` に使う名前。
        public var scriptName: String
        /// `duration of current track` が既にミリ秒か (Spotify は true)。
        public var durationIsMilliseconds: Bool

        public init(
            bundleId: String,
            displayName: String,
            scriptName: String,
            durationIsMilliseconds: Bool
        ) {
            self.bundleId = bundleId
            self.displayName = displayName
            self.scriptName = scriptName
            self.durationIsMilliseconds = durationIsMilliseconds
        }
    }

    public static let defaultCandidates: [PlayerCandidate] = [
        PlayerCandidate(
            bundleId: "com.apple.Music",
            displayName: "Music",
            scriptName: "Music",
            durationIsMilliseconds: false),
        PlayerCandidate(
            bundleId: "com.spotify.client",
            displayName: "Spotify",
            scriptName: "Spotify",
            durationIsMilliseconds: true)
    ]

    private let candidates: [PlayerCandidate]

    public init(candidates: [PlayerCandidate] = MediaCollector.defaultCandidates) {
        self.candidates = candidates
    }

    /// `mediaCaptureEnabled` が false のときは呼ばないこと (オートメーション権限プロンプトを
    /// opt-in していないユーザに出さないため)。呼び出し側 = `MacAmbientContextService`。
    ///
    /// 呼び出し元の actor / MainActor をブロックしないよう、AppleScript は必ず
    /// 専用スレッドで実行し `withCheckedContinuation` で待つ。
    public func collect() async -> MediaContext {
        let running = await MainActor.run { Self.runningCandidates(self.candidates) }
        guard !running.isEmpty else {
            return MediaContext(error: "no supported media player running")
        }

        var sessions: [MediaSessionContext] = []
        for candidate in running {
            sessions.append(await Self.probe(candidate))
        }

        // Windows と同じ選択規則: 再生中 > 先頭。
        let selectedIndex = sessions.firstIndex(where: { $0.isPlaying }) ?? 0
        sessions = sessions.enumerated().map { index, session in
            var copy = session
            copy.selected = index == selectedIndex
            return copy
        }

        AppDiagnosticLog.shared.log(
            category: "media",
            event: "get_media_sessions",
            detail: [
                "count": .int(sessions.count),
                // bundle id は識別子であり個人情報を含まない。title / artist は意図的に記録しない。
                "bundleIds": .string(sessions.map(\.sourceAppUserModelId).joined(separator: ",")),
                "selectedSource": .string(sessions[selectedIndex].sourceAppUserModelId),
                "selectedIsPlaying": .bool(sessions[selectedIndex].isPlaying),
                "playingCount": .int(sessions.filter(\.isPlaying).count),
                "sessionErrors": .int(sessions.filter { !$0.error.isEmpty }.count)
            ])

        let selected = sessions[selectedIndex]
        // playbackStatus が取れていなければ「メディア不明」。sessions と error は残す
        // (Windows も session 一覧だけの MediaContext を返す経路がある)。
        guard selected.playbackStatus != "unknown" else {
            return MediaContext(sessions: sessions, error: selected.error)
        }

        return MediaContext(
            isAvailable: true,
            sourceAppUserModelId: selected.sourceAppUserModelId,
            playbackStatus: selected.playbackStatus,
            isPlaying: selected.isPlaying,
            title: selected.title,
            artist: selected.artist,
            albumTitle: selected.albumTitle,
            // albumArtist / trackNumber / genres / startTimeMilliseconds は Apple Events では
            // プレイヤー間で取得可否が割れるため、JSON 形状を Windows と揃えたまま常に空にする
            // (PoC 3 RESULT.md §7.1-1)。
            positionMilliseconds: selected.positionMilliseconds,
            endTimeMilliseconds: selected.endTimeMilliseconds,
            // Apple Events はタイムラインの更新時刻を返さないので観測時刻で代替する。
            timelineLastUpdatedAt: Date(),
            sessions: sessions,
            error: selected.error)
    }

    /// 起動中のプレイヤーだけを返す (`NSRunningApplication` は MainActor API)。
    @MainActor
    static func runningCandidates(_ candidates: [PlayerCandidate]) -> [PlayerCandidate] {
        candidates.filter {
            !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleId).isEmpty
        }
    }

    // MARK: - AppleScript

    /// PoC 3 と同じスクリプト。**2 文字変数はプレイヤーの用語辞書と衝突する**ため長い名前を使う。
    /// `try` は「起動しているがトラック未ロード」(-1728) を吸収し、player state だけを返させる。
    static func script(for candidate: PlayerCandidate) -> String {
        """
        tell application "\(candidate.scriptName)"
            set playerStateText to (player state as text)
            set trackName to ""
            set trackArtist to ""
            set trackAlbum to ""
            set trackPosition to ""
            set trackDuration to ""
            try
                set currentTrackRef to current track
                set trackName to (name of currentTrackRef) as text
                set trackArtist to (artist of currentTrackRef) as text
                set trackAlbum to (album of currentTrackRef) as text
                set trackDuration to (duration of currentTrackRef) as text
                set trackPosition to (player position) as text
            end try
            return {playerStateText, trackName, trackArtist, trackAlbum, trackPosition, trackDuration}
        end tell
        """
    }

    /// AppleScript の生結果。非 Sendable な `NSAppleEventDescriptor` を跨がせないため、
    /// ワーカースレッド上で値型に落としてから返す。
    struct ScriptResult: Sendable {
        var state = ""
        var title = ""
        var artist = ""
        var album = ""
        var positionSeconds: Double?
        var durationRaw: Double?
        var errorNumber: Int?
        var errorMessage: String?
    }

    /// AppleScript を専用スレッドで実行し、`timeout` を超えたらスレッドを放棄して nil を返す。
    /// 呼び出し元スレッドはブロックしない (継続で再開する)。
    static func runScript(_ source: String, timeout: TimeInterval) async -> ScriptResult? {
        await withCheckedContinuation { (continuation: CheckedContinuation<ScriptResult?, Never>) in
            let resumed = ResumeOnce(continuation)

            let thread = Thread {
                var output = ScriptResult()
                var errorInfo: NSDictionary?
                if let apple = NSAppleScript(source: source) {
                    let descriptor = apple.executeAndReturnError(&errorInfo)
                    if let info = errorInfo {
                        output.errorNumber = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue
                        output.errorMessage = info[NSAppleScript.errorMessage] as? String
                            ?? info[NSAppleScript.errorBriefMessage] as? String
                            ?? "\(info)"
                    } else if descriptor.numberOfItems >= 6 {
                        output.state = Self.item(descriptor, 1)
                        output.title = Self.item(descriptor, 2)
                        output.artist = Self.item(descriptor, 3)
                        output.album = Self.item(descriptor, 4)
                        output.positionSeconds = Double(Self.item(descriptor, 5))
                        output.durationRaw = Double(Self.item(descriptor, 6))
                    } else {
                        output.errorMessage = "unexpected AppleScript result shape"
                    }
                } else {
                    output.errorMessage = "NSAppleScript could not be constructed"
                }
                resumed.resume(with: output)
            }
            thread.stackSize = 512 * 1024
            thread.start()

            // タイムアウト側。先に到達した方だけが継続を再開する (ResumeOnce が保証)。
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                resumed.resume(with: nil)
            }
        }
    }

    /// 継続を高々 1 回だけ再開するためのラッパ (スレッド完了とタイムアウトの競合を吸収する)。
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<ScriptResult?, Never>?

        init(_ continuation: CheckedContinuation<ScriptResult?, Never>) {
            self.continuation = continuation
        }

        func resume(with value: ScriptResult?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    static func item(_ list: NSAppleEventDescriptor, _ index: Int) -> String {
        list.atIndex(index)?.stringValue ?? ""
    }

    /// AppleScript の `playing` / `paused` / `stopped` を SMTC の文字列に正規化する。
    /// Music はさらに `fast forwarding` / `rewinding` を返すが、Windows 互換のため unknown 扱い。
    public static func normalizePlaybackStatus(_ raw: String) -> String {
        switch raw.lowercased() {
        case "playing": return "Playing"
        case "paused": return "Paused"
        case "stopped": return "Stopped"
        default: return "unknown"
        }
    }

    /// AppleScript のエラー番号 → 人間可読な reason (PoC 3 RESULT.md §7.1-7)。
    public static func errorReason(number: Int, playerName: String, message: String?) -> String {
        switch number {
        case -1728:
            return "no current track (AppleScript -1728)"
        case -1743:
            return "automation permission denied (errAEEventNotPermitted -1743): "
                + "grant System Settings > Privacy & Security > Automation > "
                + "<this app> > \(playerName)"
        case -600, -609:
            return "player process not connectable (\(number))"
        case -1712:
            return "Apple Event timed out (-1712)"
        default:
            return "AppleScript error \(number): \(message ?? "")"
        }
    }

    static func probe(_ candidate: PlayerCandidate) async -> MediaSessionContext {
        var session = MediaSessionContext(sourceAppUserModelId: candidate.bundleId)

        guard let result = await runScript(script(for: candidate), timeout: scriptTimeout) else {
            session.error = "AppleScript timed out after \(Int(scriptTimeout * 1000)) ms"
            return session
        }

        if let number = result.errorNumber {
            session.error = errorReason(
                number: number,
                playerName: candidate.displayName,
                message: result.errorMessage)
            if number == -1728 {
                // 起動しているがトラック未ロード。状態としては有効な "Stopped"。
                session.playbackStatus = "Stopped"
                session.isPlaying = false
            }
            return session
        }

        if let message = result.errorMessage {
            session.error = message
            return session
        }

        session.playbackStatus = normalizePlaybackStatus(result.state)
        session.isPlaying = session.playbackStatus == "Playing"
        session.title = result.title
        session.artist = result.artist
        session.albumTitle = result.album
        if let position = result.positionSeconds {
            session.positionMilliseconds = Int64((position * 1000.0).rounded())
        }
        if let duration = result.durationRaw {
            session.endTimeMilliseconds = candidate.durationIsMilliseconds
                ? Int64(duration.rounded())
                : Int64((duration * 1000.0).rounded())
        }
        return session
    }
}
