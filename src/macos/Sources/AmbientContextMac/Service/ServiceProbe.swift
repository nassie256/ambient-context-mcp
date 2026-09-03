import AppKit
import Foundation

import AmbientContextCore

/// .app バンドル無しで `MacAmbientContextService` を動かす検証用プローブ。
///
/// 一時ディレクトリの設定ファイル / スナップショットを使うので、ユーザの
/// `~/Library/Application Support/AmbientContextMcp/` には一切触れない。
///
/// 呼び出し側 (スクラッチの `main.swift` など) はメインランループを回すこと。
/// `DistributedNotificationCenter` の配送に CFRunLoop が要るため:
/// ```swift
/// Task { @MainActor in await runServiceProbe(seconds: 90); exit(0) }
/// RunLoop.main.run()
/// ```
///
/// - Parameters:
///   - enableTitleCapture: `foregroundApp.titleSummary` の override を ON にして AX 経路を試す。
///     アクセシビリティ未許可なら degrade して空タイトルになる (プロンプトは出ない)。
///   - enableMediaCapture: `media.playbackStatus` の override を ON にして Apple Events 経路を
///     試す。**既に Music / Spotify が起動している場合のみ**使うこと (未起動なら問い合わせない)。
@MainActor
public func runServiceProbe(
    seconds: Int,
    enableTitleCapture: Bool = false,
    enableMediaCapture: Bool = false
) async {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ambient-context-probe-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let settingsPath = root.appendingPathComponent("settings.json").path
    let snapshotPath = root.appendingPathComponent("ambient-context.json").path
    let store = JsonFileSettingsStore(path: settingsPath)

    var overrides = CaseInsensitiveDictionary<Bool>()
    if enableTitleCapture {
        overrides["foregroundApp.titleSummary"] = true
    }
    if enableMediaCapture {
        overrides["media.playbackStatus"] = true
    }
    if !overrides.isEmpty {
        AmbientTransmissionPolicy.save(
            store: store,
            settings: AmbientTransmissionSettings(schemaVersion: 1, pathTransmitOverrides: overrides),
            privacyClassifications: AmbientContextCatalog.getPrivacyClassifications())
    }

    let service = MacAmbientContextService(settingsStore: store, snapshotPath: snapshotPath)
    let observed = ProbeEventRecorder()
    await service.setSnapshotUpdatedHandler { snapshot in
        observed.record(snapshot)
    }

    print("[probe] settingsPath=\(settingsPath)")
    print("[probe] snapshotPath=\(snapshotPath)")
    print("[probe] titleCaptureEnabled=\(await service.isTitleCaptureEnabled)"
        + " mediaCaptureEnabled=\(await service.isMediaCaptureEnabled)")

    await service.start()
    print("[probe] started; watching for \(seconds)s")

    let deadline = Date().addingTimeInterval(TimeInterval(seconds))
    while Date() < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    let snapshot = await service.latestSnapshot
    await service.stop()

    print("[probe] --- states (name=value) ---")
    for state in snapshot.states {
        print("[probe] state \(state.name)=\(state.value) (\(state.sensitivity))")
    }
    print("[probe] --- outbound states: \(snapshot.outboundStates.count) ---")
    for state in snapshot.outboundStates {
        print("[probe] outbound-state \(state.name)=\(state.value)")
    }
    print("[probe] --- events (all captures) ---")
    for line in observed.eventLines() {
        print("[probe] event \(line)")
    }
    print("[probe] --- captures ---")
    for line in observed.captureLines() {
        print("[probe] capture \(line)")
    }
    print("[probe] done")
}

/// プローブ中に観測したスナップショットを溜める (コールバックは任意スレッドから来る)。
final class ProbeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var captures: [String] = []
    private var seenEventKeys = Set<String>()
    private var lastAt: Date?

    func record(_ snapshot: AmbientContextSnapshot) {
        lock.lock()
        defer { lock.unlock() }

        let elapsed = lastAt.map { snapshot.observedAt.timeIntervalSince($0) } ?? 0
        lastAt = snapshot.observedAt
        captures.append(String(format:
            "observedAt=%@ deltaSincePrevious=%.3fs states=%d outboundStates=%d events=%d outboundEvents=%d",
            AmbientDateFormat.string(from: snapshot.observedAt),
            elapsed,
            snapshot.states.count,
            snapshot.outboundStates.count,
            snapshot.events.count,
            snapshot.outboundEvents.count))

        for event in snapshot.recentEvents {
            let payload = event.data.sortedPairs
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            // 同一 capture 内で同 kind の別イベント (電源設定 7 件など) を潰さないよう
            // payload まで含めて重複判定する。
            let key = AmbientDateFormat.string(from: event.observedAt) + "|" + event.kind + "|" + payload
            guard seenEventKeys.insert(key).inserted else { continue }
            events.append("\(event.kind) [\(event.sensitivity)] \(payload)")
        }
    }

    func eventLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func captureLines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return captures
    }
}
