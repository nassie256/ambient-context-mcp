import AppKit
import Foundation

// ---------------------------------------------------------------------------
// Phase 0 PoC #3 -- macOS media context via Apple Events (AppleScript).
//
// Windows counterpart: WindowsMediaContextCollector.cs (SMTC).
// macOS has no public SMTC equivalent; MediaRemote is private and closed to
// non-Apple processes since macOS 15.4. This PoC probes the only supported
// route: Apple Events to scriptable players (Music.app, Spotify).
// ---------------------------------------------------------------------------

/// Mirrors the Windows collector's 1500 ms guard: a hung media app must never
/// stall the ambient capture loop.
let scriptTimeout: TimeInterval = ProcessInfo.processInfo.environment["MEDIA_POC_TIMEOUT_MS"]
    .flatMap(Double.init).map { $0 / 1000.0 } ?? 1.5

struct PlayerCandidate {
    let bundleId: String
    let displayName: String
    /// AppleScript application name used in `tell application "..."`.
    let scriptName: String
    /// true when `duration of current track` is already in milliseconds (Spotify).
    let durationIsMilliseconds: Bool
}

let candidates: [PlayerCandidate] = [
    PlayerCandidate(
        bundleId: "com.apple.Music",
        displayName: "Music",
        scriptName: "Music",
        durationIsMilliseconds: false
    ),
    PlayerCandidate(
        bundleId: "com.spotify.client",
        displayName: "Spotify",
        scriptName: "Spotify",
        durationIsMilliseconds: true
    ),
]

// MARK: - Output model (mirrors MediaContext / MediaSessionContext fields)

struct MediaLine: Codable {
    var isAvailable: Bool
    var sourceAppUserModelId: String
    var sourceKind: String
    var playbackStatus: String
    var isPlaying: Bool?
    var title: String
    var artist: String
    var albumTitle: String
    var positionMilliseconds: Int64?
    var endTimeMilliseconds: Int64?
    var error: String
    /// PoC-only diagnostics.
    var isRunning: Bool
    var appleScriptErrorNumber: Int?
    var elapsedMilliseconds: Int
}

/// Proposed macOS additions to MediaSourceKindClassifier (bundle-id based).
func classifySourceKind(_ sourceApp: String) -> String {
    let lower = sourceApp.lowercased()
    if lower.contains("com.apple.tv") || lower.contains("videolan") || lower.contains("iina")
        || lower.contains("netflix") || lower.contains("mpv") { return "video" }
    if lower.contains("com.apple.music") || lower.contains("com.apple.itunes")
        || lower.contains("spotify") || lower.contains("tidal")
        || lower.contains("com.apple.podcasts") { return "music" }
    if lower.contains("com.google.chrome") || lower.contains("com.apple.safari")
        || lower.contains("microsoft.edgemac") || lower.contains("firefox")
        || lower.contains("brave.browser") || lower.contains("vivaldi")
        || lower.contains("arc") { return "browser" }
    return "unknown"
}

func normalizePlaybackStatus(_ raw: String) -> String {
    switch raw.lowercased() {
    case "playing": return "Playing"
    case "paused": return "Paused"
    case "stopped": return "Stopped"
    default: return "unknown"
    }
}

// MARK: - AppleScript execution with a hard deadline

/// Sendable snapshot produced entirely on the worker thread, so that the
/// non-Sendable NSAppleEventDescriptor never crosses a thread boundary.
struct ScriptResult: Sendable {
    var state: String = ""
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var positionSeconds: Double?
    var durationRaw: Double?
    var errorNumber: Int?
    var errorMessage: String?
}

final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ScriptResult?
    func set(_ value: ScriptResult) {
        lock.lock(); stored = value; lock.unlock()
    }
    func get() -> ScriptResult? {
        lock.lock(); defer { lock.unlock() }; return stored
    }
}

/// NOTE: short variable names such as `st` / `td` collide with the players'
/// scripting terminology and fail to compile with -2741
/// ("Expected expression but found ..."). Use long, unambiguous names.
/// The `try` block keeps a running-but-idle player from erroring out with
/// -1728 ("Can't get current track"), so player state is still reported.
func script(for candidate: PlayerCandidate) -> String {
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

func string(_ list: NSAppleEventDescriptor, _ index: Int) -> String {
    list.atIndex(index)?.stringValue ?? ""
}

/// Runs the AppleScript on a detached thread and abandons it after `timeout`.
/// Returns nil on timeout.
func runScript(_ source: String, timeout: TimeInterval) -> ScriptResult? {
    let box = ResultBox()
    let semaphore = DispatchSemaphore(value: 0)

    let thread = Thread {
        var out = ScriptResult()
        var errorInfo: NSDictionary?
        if let apple = NSAppleScript(source: source) {
            let descriptor = apple.executeAndReturnError(&errorInfo)
            if let info = errorInfo {
                out.errorNumber = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue
                out.errorMessage = info[NSAppleScript.errorMessage] as? String
                    ?? info[NSAppleScript.errorBriefMessage] as? String
                    ?? "\(info)"
            } else if descriptor.numberOfItems >= 6 {
                out.state = string(descriptor, 1)
                out.title = string(descriptor, 2)
                out.artist = string(descriptor, 3)
                out.album = string(descriptor, 4)
                out.positionSeconds = Double(string(descriptor, 5))
                out.durationRaw = Double(string(descriptor, 6))
            } else {
                out.errorMessage = "unexpected AppleScript result shape"
            }
        } else {
            out.errorMessage = "NSAppleScript could not be constructed"
        }
        box.set(out)
        semaphore.signal()
    }
    thread.stackSize = 512 * 1024
    thread.start()

    if semaphore.wait(timeout: .now() + timeout) == .timedOut {
        return nil
    }
    return box.get()
}

// MARK: - Per-player probe

func probe(_ candidate: PlayerCandidate) -> MediaLine {
    var line = MediaLine(
        isAvailable: false,
        sourceAppUserModelId: candidate.bundleId,
        sourceKind: classifySourceKind(candidate.bundleId),
        playbackStatus: "unknown",
        isPlaying: nil,
        title: "",
        artist: "",
        albumTitle: "",
        positionMilliseconds: nil,
        endTimeMilliseconds: nil,
        error: "",
        isRunning: false,
        appleScriptErrorNumber: nil,
        elapsedMilliseconds: 0
    )

    // Never launch the app: `tell application "Music"` would start it.
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: candidate.bundleId)
    guard !running.isEmpty else {
        line.error = "player not running"
        return line
    }
    line.isRunning = true

    let started = DispatchTime.now()
    let result = runScript(script(for: candidate), timeout: scriptTimeout)
    line.elapsedMilliseconds = Int(
        Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000.0
    )

    guard let result else {
        line.error = "AppleScript timed out after \(Int(scriptTimeout * 1000)) ms"
        return line
    }

    if let number = result.errorNumber {
        line.appleScriptErrorNumber = number
        switch number {
        case -1728:
            // "Can't get current track" -- running but nothing loaded.
            line.isAvailable = true
            line.playbackStatus = "Stopped"
            line.isPlaying = false
            line.error = "no current track (AppleScript -1728)"
        case -1743:
            line.error = "automation permission denied (errAEEventNotPermitted -1743): "
                + "grant System Settings > Privacy & Security > Automation > "
                + "<this app> > \(candidate.displayName)"
        case -600, -609:
            line.error = "player process not connectable (\(number))"
        case -1712:
            line.error = "Apple Event timed out (-1712)"
        default:
            line.error = "AppleScript error \(number): \(result.errorMessage ?? "")"
        }
        return line
    }

    if let message = result.errorMessage {
        line.error = message
        return line
    }

    line.isAvailable = true
    line.playbackStatus = normalizePlaybackStatus(result.state)
    line.isPlaying = line.playbackStatus == "Playing"
    line.title = result.title
    line.artist = result.artist
    line.albumTitle = result.album
    if let position = result.positionSeconds {
        line.positionMilliseconds = Int64((position * 1000.0).rounded())
    }
    if let duration = result.durationRaw {
        line.endTimeMilliseconds = candidate.durationIsMilliseconds
            ? Int64(duration.rounded())
            : Int64((duration * 1000.0).rounded())
    }
    return line
}

// MARK: - Entry point

let encoder = JSONEncoder()
encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

// `media-poc --selftest-timeout` proves the deadline guard: a 5 s script is
// abandoned after 1500 ms instead of stalling the caller.
if CommandLine.arguments.contains("--selftest-timeout") {
    let started = DispatchTime.now()
    let result = runScript("delay 5\nreturn {\"a\",\"b\",\"c\",\"d\",\"e\",\"f\"}", timeout: scriptTimeout)
    let elapsed = Int(
        Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000.0
    )
    print("{\"selftest\":\"timeout\",\"timedOut\":\(result == nil),\"elapsedMilliseconds\":\(elapsed)}")
    exit(0)
}

// `media-poc --bench` shows the per-call cost inside one warm process.
if CommandLine.arguments.contains("--bench") {
    for candidate in candidates where !NSRunningApplication
        .runningApplications(withBundleIdentifier: candidate.bundleId).isEmpty {
        var samples: [Int] = []
        for _ in 0..<5 { samples.append(probe(candidate).elapsedMilliseconds) }
        print("{\"bench\":\"\(candidate.bundleId)\",\"elapsedMillisecondsSamples\":\(samples)}")
    }
    exit(0)
}

for candidate in candidates {
    let line = probe(candidate)
    if let data = try? encoder.encode(line), let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}
