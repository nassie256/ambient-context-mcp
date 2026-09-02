// Phase 0 PoC #2 — foreground app identity + focused window title (Accessibility) + idle seconds.
//
// Mirrors what src/windows/AmbientContextMcp.Desktop/AmbientContext/WindowsForegroundAppCollector.cs
// produces (processId / processName / appName / category / hasWindowTitle / rawWindowTitle /
// titleSummary) and what AmbientTier1Rules derives, but on macOS APIs.
//
// NOTE: this file is `main.swift`, so its top level is @MainActor in Swift 6 language mode.
// AppKit (NSWorkspace) and the Accessibility APIs used here are main-thread APIs, which is
// exactly what we want.

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// MARK: - Output helpers

let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

@MainActor
func emit(_ event: String, _ fields: [String: Any]) {
    var payload = fields
    payload["event"] = event
    payload["ts"] = isoFormatter.string(from: Date())
    guard
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
        let text = String(data: data, encoding: .utf8)
    else {
        print("{\"event\":\"emit_failed\"}")
        return
    }
    print(text)
    fflush(stdout)
}

func jsonValue(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }

// MARK: - Tier1 classification (bundle-id keyed port of AmbientTier1Rules.ClassifyApp)

struct AppClassification: Sendable {
    let category: String
    let appName: String
}

let bundleClassifications: [String: AppClassification] = [
    // editor / IDE
    "com.microsoft.VSCode": AppClassification(category: "editor", appName: "Visual Studio Code"),
    "com.microsoft.VSCodeInsiders": AppClassification(category: "editor", appName: "Visual Studio Code"),
    "com.todesktop.230313mzl4w4u92": AppClassification(category: "editor", appName: "Cursor"),
    "com.exafunction.windsurf": AppClassification(category: "editor", appName: "Windsurf"),
    "com.jetbrains.intellij": AppClassification(category: "editor", appName: "IntelliJ IDEA"),
    "com.jetbrains.rider": AppClassification(category: "editor", appName: "Rider"),
    "com.jetbrains.pycharm": AppClassification(category: "editor", appName: "PyCharm"),
    "com.jetbrains.WebStorm": AppClassification(category: "editor", appName: "WebStorm"),
    "com.apple.dt.Xcode": AppClassification(category: "editor", appName: "Xcode"),
    "dev.zed.Zed": AppClassification(category: "editor", appName: "Zed"),
    "com.sublimetext.4": AppClassification(category: "editor", appName: "Sublime Text"),
    "com.apple.TextEdit": AppClassification(category: "editor", appName: "TextEdit"),
    // browser
    "com.google.Chrome": AppClassification(category: "browser", appName: "Chrome"),
    "com.apple.Safari": AppClassification(category: "browser", appName: "Safari"),
    "com.microsoft.edgemac": AppClassification(category: "browser", appName: "Edge"),
    "org.mozilla.firefox": AppClassification(category: "browser", appName: "Firefox"),
    "com.brave.Browser": AppClassification(category: "browser", appName: "Brave"),
    "company.thebrowser.Browser": AppClassification(category: "browser", appName: "Arc"),
    "com.vivaldi.Vivaldi": AppClassification(category: "browser", appName: "Vivaldi"),
    // communication
    "com.tinyspeck.slackmacgap": AppClassification(category: "communication", appName: "Slack"),
    "com.hnc.Discord": AppClassification(category: "communication", appName: "Discord"),
    "com.microsoft.teams2": AppClassification(category: "communication", appName: "Teams"),
    "us.zoom.xos": AppClassification(category: "communication", appName: "Zoom"),
    "com.apple.MobileSMS": AppClassification(category: "communication", appName: "Messages"),
    "com.apple.mail": AppClassification(category: "communication", appName: "Mail"),
    // media
    "com.spotify.client": AppClassification(category: "media", appName: "Spotify"),
    "com.apple.Music": AppClassification(category: "media", appName: "Music"),
    "com.apple.TV": AppClassification(category: "media", appName: "TV"),
    "org.videolan.vlc": AppClassification(category: "media", appName: "VLC"),
    "com.colliderli.iina": AppClassification(category: "media", appName: "IINA"),
    "com.apple.QuickTimePlayerX": AppClassification(category: "media", appName: "QuickTime Player"),
    // terminal
    "com.apple.Terminal": AppClassification(category: "terminal", appName: "Terminal"),
    "com.googlecode.iterm2": AppClassification(category: "terminal", appName: "iTerm2"),
    "dev.warp.Warp-Stable": AppClassification(category: "terminal", appName: "Warp"),
    "net.kovidgoyal.kitty": AppClassification(category: "terminal", appName: "kitty"),
    "com.github.wez.wezterm": AppClassification(category: "terminal", appName: "WezTerm"),
    "co.zeit.hyper": AppClassification(category: "terminal", appName: "Hyper"),
    // document
    "com.microsoft.Word": AppClassification(category: "document", appName: "Word"),
    "com.microsoft.Excel": AppClassification(category: "document", appName: "Excel"),
    "com.microsoft.Powerpoint": AppClassification(category: "document", appName: "PowerPoint"),
    "com.apple.iWork.Pages": AppClassification(category: "document", appName: "Pages"),
    "com.apple.iWork.Numbers": AppClassification(category: "document", appName: "Numbers"),
    "com.apple.iWork.Keynote": AppClassification(category: "document", appName: "Keynote"),
    "com.apple.Preview": AppClassification(category: "document", appName: "Preview"),
    "com.apple.Notes": AppClassification(category: "document", appName: "Notes"),
    "notion.id": AppClassification(category: "document", appName: "Notion"),
    // shell
    "com.apple.finder": AppClassification(category: "shell", appName: "Finder"),
    "com.apple.systempreferences": AppClassification(category: "shell", appName: "System Settings"),
    "com.apple.Spotlight": AppClassification(category: "shell", appName: "Spotlight"),
]

/// Port of AmbientTier1Rules.ClassifyApp: unknown -> ("other", <fallback name>);
/// missing data -> ("", "") (never the sentinel string "unknown").
func classifyApp(bundleId: String?, fallbackName: String?) -> AppClassification {
    guard let bundleId, !bundleId.trimmingCharacters(in: .whitespaces).isEmpty else {
        if let fallbackName, !fallbackName.isEmpty {
            return AppClassification(category: "other", appName: fallbackName)
        }
        return AppClassification(category: "", appName: "")
    }
    if let hit = bundleClassifications[bundleId] {
        return hit
    }
    return AppClassification(category: "other", appName: fallbackName ?? bundleId)
}

/// Port of AmbientTier1Rules.GetPresenceBucket.
func presenceBucket(idleSeconds: Int?) -> String {
    guard let idleSeconds else { return "unknown" }
    switch idleSeconds {
    case ..<10: return "active"
    case ..<120: return "idle"
    case ..<600: return "away_short"
    default: return "away_long"
    }
}

// MARK: - Foreground app (no permission required)

struct ForegroundApp: Sendable {
    let bundleIdentifier: String?
    let localizedName: String?
    let processIdentifier: pid_t
    let executableName: String?
}

@MainActor
func frontmostApp() -> ForegroundApp? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    return ForegroundApp(
        bundleIdentifier: app.bundleIdentifier,
        localizedName: app.localizedName,
        processIdentifier: app.processIdentifier,
        executableName: app.executableURL?.lastPathComponent
    )
}

@MainActor
func foregroundAppFields(_ app: ForegroundApp?, includeTitle: Bool) -> [String: Any] {
    guard let app else {
        return [
            "available": false,
            "category": "",
            "appName": "",
        ]
    }
    let classification = classifyApp(bundleId: app.bundleIdentifier, fallbackName: app.localizedName)
    var fields: [String: Any] = [
        "available": true,
        "bundleIdentifier": jsonValue(app.bundleIdentifier),
        "localizedName": jsonValue(app.localizedName),
        "processId": Int(app.processIdentifier),
        // Windows: "code.exe"; macOS: executable file name without extension, e.g. "Code".
        "processName": jsonValue(app.executableName),
        "category": classification.category,
        "appName": classification.appName,
    ]
    if includeTitle {
        let title = focusedWindowTitle(pid: app.processIdentifier)
        fields["hasWindowTitle"] = !title.title.isEmpty
        fields["rawWindowTitle"] = title.title
        fields["titleReason"] = title.reason
    }
    return fields
}

// MARK: - Accessibility

func axErrorName(_ error: AXError) -> String {
    switch error {
    case .success: return "success"
    case .failure: return "failure"
    case .illegalArgument: return "illegalArgument"
    case .invalidUIElement: return "invalidUIElement"
    case .invalidUIElementObserver: return "invalidUIElementObserver"
    case .cannotComplete: return "cannotComplete"
    case .attributeUnsupported: return "attributeUnsupported"
    case .actionUnsupported: return "actionUnsupported"
    case .notificationUnsupported: return "notificationUnsupported"
    case .notImplemented: return "notImplemented"
    case .notificationAlreadyRegistered: return "notificationAlreadyRegistered"
    case .notificationNotRegistered: return "notificationNotRegistered"
    case .apiDisabled: return "apiDisabled"
    case .noValue: return "noValue"
    case .parameterizedAttributeUnsupported: return "parameterizedAttributeUnsupported"
    case .notEnoughPrecision: return "notEnoughPrecision"
    @unknown default: return "unknown(\(error.rawValue))"
    }
}

@MainActor
func isAccessibilityTrusted(prompt: Bool) -> Bool {
    // Swift 6 gotcha: `kAXTrustedCheckOptionPrompt` is imported as a mutable global `var`
    // (CFStringRef), so referencing it is a strict-concurrency error. Its documented value is
    // the literal below, so we spell the key out instead.
    let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

struct TitleResult {
    let title: String
    /// Empty when the title was read successfully; otherwise a short machine-readable reason.
    let reason: String
}

/// Never throws, never hangs (1s AX messaging timeout), returns "" + reason on any AXError.
@MainActor
func focusedWindowTitle(pid: pid_t) -> TitleResult {
    guard AXIsProcessTrusted() else {
        return TitleResult(title: "", reason: "accessibility_not_trusted")
    }
    let appElement = AXUIElementCreateApplication(pid)
    // Guards against a hung/non-responsive target app blocking the collector thread.
    AXUIElementSetMessagingTimeout(appElement, 1.0)

    var windowRef: CFTypeRef?
    let windowError = AXUIElementCopyAttributeValue(
        appElement, kAXFocusedWindowAttribute as CFString, &windowRef)
    guard windowError == .success, let windowRef else {
        return TitleResult(title: "", reason: "focused_window:\(axErrorName(windowError))")
    }
    guard CFGetTypeID(windowRef) == AXUIElementGetTypeID() else {
        return TitleResult(title: "", reason: "focused_window:unexpected_type")
    }
    // swiftlint:disable:next force_cast
    let windowElement = windowRef as! AXUIElement

    var titleRef: CFTypeRef?
    let titleError = AXUIElementCopyAttributeValue(
        windowElement, kAXTitleAttribute as CFString, &titleRef)
    guard titleError == .success, let titleRef else {
        return TitleResult(title: "", reason: "title:\(axErrorName(titleError))")
    }
    guard let title = titleRef as? String else {
        return TitleResult(title: "", reason: "title:unexpected_type")
    }
    return TitleResult(title: title, reason: "")
}

// MARK: - Idle seconds

/// kCGAnyInputEventType is not exposed to Swift; it is 0xFFFFFFFF.
let anyInputEventType = CGEventType(rawValue: ~0)!

func idleSeconds() -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEventType)
}

// MARK: - Snapshot

@MainActor
func emitSnapshot(_ label: String) {
    let app = frontmostApp()
    let idle = idleSeconds()
    var fields = foregroundAppFields(app, includeTitle: true)
    fields["idleSeconds"] = (idle * 1000).rounded() / 1000
    fields["presenceBucket"] = presenceBucket(idleSeconds: Int(idle))
    fields["accessibilityTrusted"] = AXIsProcessTrusted()
    fields["label"] = label
    emit("snapshot", fields)
}

// MARK: - CLI

let arguments = Array(CommandLine.arguments.dropFirst())
var watchSeconds: Double = 0
var promptForAccessibility = false
var index = 0
while index < arguments.count {
    switch arguments[index] {
    case "--watch":
        index += 1
        watchSeconds = index < arguments.count ? (Double(arguments[index]) ?? 20) : 20
    case "--prompt-ax":
        promptForAccessibility = true
    case "--help", "-h":
        print("usage: ax-title-poc [--watch <seconds>] [--prompt-ax]")
        exit(0)
    default:
        FileHandle.standardError.write(Data("unknown argument: \(arguments[index])\n".utf8))
        exit(2)
    }
    index += 1
}

emit(
    "startup",
    [
        "pid": Int(ProcessInfo.processInfo.processIdentifier),
        "executablePath": Bundle.main.executablePath ?? "",
        "bundleIdentifier": jsonValue(Bundle.main.bundleIdentifier),
        "isAppBundle": Bundle.main.bundleIdentifier != nil,
        "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
    ])

// Step 2a: trust check WITHOUT prompt (must be observed before any prompting call).
let trustedNoPrompt = isAccessibilityTrusted(prompt: false)
emit(
    "accessibility_check",
    [
        "api": "AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt: false)",
        "trusted": trustedNoPrompt,
    ])

if promptForAccessibility {
    let trustedWithPrompt = isAccessibilityTrusted(prompt: true)
    emit(
        "accessibility_check",
        [
            "api": "AXIsProcessTrustedWithOptions(kAXTrustedCheckOptionPrompt: true)",
            "trusted": trustedWithPrompt,
            "note": "when not trusted the OS shows a system alert offering 'Open System Settings'",
        ])
}

// Step 1 + 2b + 3: one-shot snapshot.
emitSnapshot("initial")

if watchSeconds > 0 {
    emit("watch_start", ["seconds": watchSeconds])

    // Step 1: foreground app activation stream (no permission needed).
    let workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
    ) { note in
        // Swift 6 gotcha: the Notification handed to the block is task-isolated and
        // NSRunningApplication is not Sendable, so we destructure into plain values
        // *outside* MainActor.assumeIsolated and only capture those.
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let foreground = app.map {
            ForegroundApp(
                bundleIdentifier: $0.bundleIdentifier,
                localizedName: $0.localizedName,
                processIdentifier: $0.processIdentifier,
                executableName: $0.executableURL?.lastPathComponent)
        }
        MainActor.assumeIsolated {
            var fields = foregroundAppFields(foreground, includeTitle: true)
            fields["source"] = "NSWorkspace.didActivateApplicationNotification"
            emit("app_activated", fields)
        }
    }

    let deactivateObserver = NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didDeactivateApplicationNotification,
        object: nil,
        queue: .main
    ) { note in
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        let bundleIdentifier = app?.bundleIdentifier
        let localizedName = app?.localizedName
        MainActor.assumeIsolated {
            emit(
                "app_deactivated",
                [
                    "bundleIdentifier": jsonValue(bundleIdentifier),
                    "localizedName": jsonValue(localizedName),
                ])
        }
    }

    // Step 4: presence.sessionLocked sources. Registration only; we do not lock the screen.
    let distributed = DistributedNotificationCenter.default()
    var lockObservers: [NSObjectProtocol] = []
    for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
        let observer = distributed.addObserver(
            forName: Notification.Name(name),
            object: nil,
            queue: .main
        ) { note in
            let notificationName = note.name.rawValue
            MainActor.assumeIsolated {
                emit(
                    "session_lock_notification",
                    [
                        "name": notificationName,
                        "sessionLocked": notificationName == "com.apple.screenIsLocked",
                    ])
            }
        }
        lockObservers.append(observer)
    }
    emit(
        "lock_observers_registered",
        [
            "names": ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"],
            "center": "DistributedNotificationCenter.default()",
        ])

    // Step 3: idle sampling every 2 seconds.
    let timer = Timer(timeInterval: 2.0, repeats: true) { _ in
        MainActor.assumeIsolated {
            emitSnapshot("tick")
        }
    }
    RunLoop.main.add(timer, forMode: .common)

    let deadline = Date().addingTimeInterval(watchSeconds)
    while Date() < deadline {
        RunLoop.main.run(mode: .default, before: deadline)
    }

    timer.invalidate()
    NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
    NSWorkspace.shared.notificationCenter.removeObserver(deactivateObserver)
    for observer in lockObservers {
        distributed.removeObserver(observer)
    }
    emit("watch_end", [:])
}
