import CoreGraphics
import Foundation

import AmbientContextCore

/// C# `WindowsAmbientContextService.GetPresence` / `GetIdleSeconds` の macOS 版。
///
/// Windows は `GetLastInputInfo`、macOS は `CGEventSource.secondsSinceLastEventType`
/// (設計書 §3.3)。どちらも HID 入力ベースで権限不要。
public struct PresenceCollector: Sendable {
    /// `kCGAnyInputEventType` は Swift に import されないため、定義値 (0xFFFFFFFF) を直接使う。
    /// PoC 2 (`src/macos/poc/02-ax-title/Sources/ax-title-poc/main.swift`) と同じ扱い。
    private static let anyInputEventType = CGEventType(rawValue: ~0)

    public init() {}

    /// アイドル秒数。取得できなければ nil (Windows の `GetLastInputInfo` 失敗と同じ扱い)。
    public func idleSeconds() -> Int? {
        guard let eventType = Self.anyInputEventType else { return nil }
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: eventType)
        guard seconds.isFinite, seconds >= 0 else { return nil }
        return Int(seconds)
    }

    /// - Parameter sessionLocked: サービスが保持するロック状態
    ///   (`TransitionEvaluator.sessionLocked`)。C# の `_sessionLocked` と同じ役割。
    public func collect(sessionLocked: Bool) -> PresenceContext {
        let idle = idleSeconds()
        return PresenceContext(
            idleSeconds: idle,
            bucket: sessionLocked ? "locked" : AmbientTier1Rules.getPresenceBucket(idle),
            sessionLocked: sessionLocked)
    }
}
