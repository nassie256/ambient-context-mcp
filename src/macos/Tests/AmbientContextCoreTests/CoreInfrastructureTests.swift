import Foundation
import Testing
@testable import AmbientContextCore

/// C# 側に対応テストが無い、移植固有の基盤 (JSON 整形 / 日付書式 / 診断ログ / ツール層) の回帰テスト。
@Suite("CoreInfrastructure")
struct CoreInfrastructureTests {
    @Test("Iso8601_round_trip_keeps_local_offset_shape")
    func iso8601RoundTrip() throws {
        let text = "2026-05-04T10:15:00.123+09:00"
        let parsed = try #require(AmbientDateFormat.parse(text))
        let rendered = AmbientDateFormat.string(from: parsed, timeZone: TimeZone(secondsFromGMT: 9 * 3600)!)
        #expect(rendered == text)
    }

    @Test("Iso8601_parse_accepts_z_and_missing_fraction")
    func iso8601ParseVariants() throws {
        let withZ = try #require(AmbientDateFormat.parse("2026-05-23T03:00:00Z"))
        let withOffset = try #require(AmbientDateFormat.parse("2026-05-23T12:00:00+09:00"))
        #expect(withZ == withOffset)
        #expect(AmbientDateFormat.parse("not-a-date") == nil)
        #expect(AmbientDateFormat.parse("") == nil)
    }

    @Test("Json_encoder_uses_camelCase_keys_and_does_not_escape_slashes")
    func jsonEncoderShape() throws {
        let state = LocalContextState(
            observedAt: AmbientDateFormat.parse("2026-05-04T10:15:00.123+09:00"),
            name: "media/title",
            value: "a/b",
            sensitivity: "high")
        let text = AmbientContextJson.string(state)

        #expect(text.contains("\"observedAt\""))
        #expect(text.contains("\"a/b\""))
        #expect(!text.contains("\\/"))
        // pretty printed (2 space indent)
        #expect(text.contains("\n  \"name\""))
    }

    @Test("Json_encoder_omits_null_metadata_on_states")
    func jsonEncoderOmitsNullMetadata() {
        let text = AmbientContextJson.string(LocalContextState(name: "battery.bucket", value: "ok"))
        #expect(!text.contains("observedAt"))
        #expect(!text.contains("sensitivity"))
    }

    @Test("CaseInsensitiveDictionary_lookup_ignores_case_but_keeps_original_key")
    func caseInsensitiveDictionaryBehaviour() {
        var dictionary: CaseInsensitiveDictionary<String> = ["Media.Title": "Imagine"]
        #expect(dictionary["media.title"] == "Imagine")
        #expect(dictionary.keys == ["Media.Title"])

        dictionary["MEDIA.TITLE"] = "Woman"
        #expect(dictionary.count == 1)
        #expect(dictionary.keys == ["Media.Title"])
        #expect(dictionary["media.title"] == "Woman")

        dictionary.removeValue(forKey: "media.TITLE")
        #expect(dictionary.isEmpty)
    }

    @Test("ContextToolsCore_getStates_returns_json")
    func contextToolsGetStates() {
        let hub = LocalContextHubTestFactory.createInMemory()
        hub.ingest(AmbientContextSnapshot(
            observedAt: Date(),
            outboundStates: [AmbientState(name: "presence.bucket", value: "active", sensitivity: "low")]))

        let json = ContextToolsCore.getStates(hub: hub, scopes: ["context.all:read"])
        #expect(json.contains("\"presence.bucket\""))
        #expect(json.contains("\"policyVersion\""))
    }

    @Test("ContextToolsCore_pollEvents_rejects_invalid_timestamp")
    func contextToolsRejectsInvalidTimestamp() {
        let hub = LocalContextHubTestFactory.createInMemory()

        #expect(throws: ContextToolsError.self) {
            _ = try ContextToolsCore.pollEvents(hub: hub, since: "yesterday")
        }

        do {
            _ = try ContextToolsCore.pollEvents(hub: hub, until: "nope")
            Issue.record("should have thrown")
        } catch let error as ContextToolsError {
            #expect(error.description ==
                "'until' must be an ISO 8601 timestamp such as 2026-05-10T00:00:00+09:00.")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test("ContextToolsCore_describeEvents_and_getPolicy_return_json")
    func contextToolsDescribeAndPolicy() {
        let hub = LocalContextHubTestFactory.createInMemory()
        #expect(ContextToolsCore.describeEvents(hub: hub).contains("\"eventSchemaCatalog\""))
        #expect(ContextToolsCore.getPolicy(hub: hub).contains("\"privacyClassifications\""))
    }

    @Test("AppDiagnosticLog_writes_jsonl_lines")
    func appDiagnosticLogWrites() throws {
        let temp = TempDirectory()
        let log = AppDiagnosticLog.shared
        log.configure(settingsPath: temp.file("settings.json"))
        log.log(category: "test", event: "started", detail: ["port": .int(37690)])

        let path = try #require(log.logPath)
        let content = try String(contentsOfFile: path, encoding: .utf8)
        #expect(content.contains("\"category\":\"test\""))
        #expect(content.contains("\"event\":\"started\""))
        #expect(content.contains("\"port\":37690"))
        #expect(content.hasSuffix("\n"))
    }

    @Test("Hub_normalizes_retention_limits")
    func hubNormalizesRetentionLimits() {
        #expect(LocalContextHub.normalizeMaxEventAgeHours(0) == 24)
        #expect(LocalContextHub.normalizeMaxEventAgeHours(1000) == 168)
        #expect(LocalContextHub.normalizeMaxEventCount(-1) == 500)
        #expect(LocalContextHub.normalizeMaxEventCount(10) == 100)
        #expect(LocalContextHub.normalizeMaxEventCount(999_999) == 5000)
    }

    @Test("Hub_publishes_events_to_callback")
    func hubPublishesEvents() {
        let hub = LocalContextHubTestFactory.createInMemory()
        let box = Box()
        hub.eventPublished = { event in box.append(event.name) }

        hub.ingest(AmbientContextSnapshot(
            observedAt: Date(),
            outboundEvents: [
                AmbientOutboundEvent(observedAt: Date(), name: "user_returned", value: "active", sensitivity: "low")
            ]))

        #expect(box.names == ["user_returned"])
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ name: String) {
            lock.lock()
            storage.append(name)
            lock.unlock()
        }

        var names: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }
}
