import Foundation
import Testing
@testable import AmbientContextCore

@Suite("BackfillLegacyEvents")
struct BackfillLegacyEventsTests {
    private let temp = TempDirectory()

    private var settingsPath: String { temp.file("settings.json") }
    private var eventLogPath: String { temp.file("events.jsonl") }

    /// payloadSensitivity / maxFieldSensitivity は旧スキーマでは存在しないので含めない。
    private func legacyEventJsonl(observedAt: Date) -> String {
        let iso = AmbientDateFormat.string(from: observedAt)
        return "{\"id\":\"evt_legacy_1\",\"sequence\":1,"
            + "\"observedAt\":\"\(iso)\","
            + "\"name\":\"media_session_changed\",\"value\":\"Imagine\","
            + "\"payload\":{\"title\":\"Imagine\",\"source_app\":\"Chrome\"},"
            + "\"sensitivity\":\"medium\"}\n"
    }

    private static let classifications = [
        PrivacyClassification(path: "events.media_session_changed", sensitivity: "medium", defaultTransmit: false),
        PrivacyClassification(path: "events.media_session_changed.title", sensitivity: "high", defaultTransmit: false)
    ]

    @Test("Ingest_backfills_legacy_events_so_high_payload_keys_are_stripped_at_medium_scope")
    func ingestBackfillsLegacyEvents() throws {
        // アップグレード前 (= 旧スキーマ) の events.jsonl を再現する。
        // 24h trim 保持窓に収まる新しいタイムスタンプにしないと復元時に落ちる。
        let legacyObservedAt = Date().addingTimeInterval(-30 * 60)
        try legacyEventJsonl(observedAt: legacyObservedAt)
            .write(toFile: eventLogPath, atomically: true, encoding: .utf8)

        let hub = LocalContextHubTestFactory.createWithPersistentLog(settingsPath: settingsPath)

        // アップグレード後の最初の Ingest。classifications が初めて到着するタイミング。
        hub.ingest(AmbientContextSnapshot(
            observedAt: Date(),
            privacyClassifications: Self.classifications))

        // medium scope で history query。leak が残っているなら title が混入する。
        let poll = hub.pollEvents(LocalContextPollRequest(
            clientId: "test",
            scopes: ["context.medium:read"],
            since: legacyObservedAt.addingTimeInterval(-60)))

        #expect(poll.events.count == 1)
        let event = try #require(poll.events.first)
        #expect(!event.payload.contains("title"))
        #expect(event.payload.contains("source_app"))
        #expect(event.maxFieldSensitivity == "medium")
    }

    @Test("Backfill_rewrites_events_jsonl_so_leak_does_not_return_after_restart")
    func backfillRewritesEventsJsonl() throws {
        let legacyObservedAt = Date().addingTimeInterval(-30 * 60)
        try legacyEventJsonl(observedAt: legacyObservedAt)
            .write(toFile: eventLogPath, atomically: true, encoding: .utf8)

        let hub = LocalContextHubTestFactory.createWithPersistentLog(settingsPath: settingsPath)
        hub.ingest(AmbientContextSnapshot(
            observedAt: Date(),
            privacyClassifications: Self.classifications))

        let contentAfterBackfill = try String(contentsOfFile: eventLogPath, encoding: .utf8)
        #expect(contentAfterBackfill.contains("\"maxFieldSensitivity\":\"high\""))
        #expect(contentAfterBackfill.contains("\"payloadSensitivity\":"))
    }
}
