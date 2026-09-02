import Foundation
import Testing
@testable import AmbientContextCore

@Suite("SensitivityFilter")
struct SensitivityFilterTests {
    static let classifications = [
        PrivacyClassification(path: "events.media_session_changed", sensitivity: "medium", defaultTransmit: false),
        PrivacyClassification(path: "events.media_session_changed.title", sensitivity: "high", defaultTransmit: false),
        PrivacyClassification(path: "events.media_session_changed.artist", sensitivity: "high", defaultTransmit: false)
    ]

    @Test("LookupPayloadFieldSensitivity_returns_exact_match")
    func lookupPayloadFieldSensitivityReturnsExactMatch() {
        let result = SensitivityScopeFilter.lookupPayloadFieldSensitivity(
            eventName: "media_session_changed",
            payloadKey: "title",
            classifications: Self.classifications,
            fallbackSensitivity: "medium")

        #expect(result == "high")
    }

    @Test("LookupPayloadFieldSensitivity_falls_back_to_event_level")
    func lookupPayloadFieldSensitivityFallsBackToEventLevel() {
        let result = SensitivityScopeFilter.lookupPayloadFieldSensitivity(
            eventName: "media_session_changed",
            payloadKey: "source_app",
            classifications: Self.classifications,
            fallbackSensitivity: "medium")

        #expect(result == "medium")
    }

    @Test("ComputePayloadSensitivity_returns_max_high_when_any_field_is_high")
    func computePayloadSensitivityReturnsMaxHighWhenAnyFieldIsHigh() {
        let payload: CaseInsensitiveDictionary<String> = [
            "title": "Imagine",
            "artist": "John Lennon",
            "source_app": "Chrome"
        ]

        let (perKey, max) = SensitivityScopeFilter.computePayloadSensitivity(
            eventName: "media_session_changed",
            payload: payload,
            classifications: Self.classifications,
            eventSensitivity: "medium")

        #expect(perKey["title"] == "high")
        #expect(perKey["artist"] == "high")
        #expect(perKey["source_app"] == "medium")
        #expect(max == "high")
    }

    @Test("ComputePayloadSensitivity_returns_event_level_when_all_fields_inherit")
    func computePayloadSensitivityReturnsEventLevelWhenAllFieldsInherit() {
        let payload: CaseInsensitiveDictionary<String> = ["from": "battery", "to": "ac"]

        let (perKey, max) = SensitivityScopeFilter.computePayloadSensitivity(
            eventName: "ac_power_connected",
            payload: payload,
            classifications: Self.classifications,
            eventSensitivity: "low")

        #expect(perKey["from"] == "low")
        #expect(perKey["to"] == "low")
        #expect(max == "low")
    }

    @Test("FilterEventForScope_keeps_event_drops_high_keys_when_scope_is_medium")
    func filterEventForScopeKeepsEventDropsHighKeysWhenScopeIsMedium() throws {
        let event = LocalContextEvent(
            id: "evt_x",
            sequence: 1,
            observedAt: Date(),
            name: "media_session_changed",
            value: "Imagine",
            payload: ["title": "Imagine", "source_app": "Chrome"],
            sensitivity: "medium",
            payloadSensitivity: ["title": "high", "source_app": "medium"],
            maxFieldSensitivity: "high")

        let filtered = try #require(
            SensitivityScopeFilter.filterEventForScope(event, scopes: ["context.medium:read"]))

        #expect(!filtered.payload.contains("title"))
        #expect(filtered.payload.contains("source_app"))
        #expect(filtered.maxFieldSensitivity == "medium")
        #expect(filtered.payloadSensitivity["source_app"] == "medium")
    }

    @Test("FilterEventForScope_drops_event_when_event_level_exceeds_scope")
    func filterEventForScopeDropsEventWhenEventLevelExceedsScope() {
        let event = LocalContextEvent(
            id: "evt_x",
            sequence: 1,
            observedAt: Date(),
            name: "media_session_changed",
            payload: ["source_app": "Chrome"],
            sensitivity: "medium",
            payloadSensitivity: ["source_app": "medium"],
            maxFieldSensitivity: "medium")

        #expect(SensitivityScopeFilter.filterEventForScope(event, scopes: ["context.low:read"]) == nil)
    }

    @Test("FilterEventForScope_passes_through_when_payload_sensitivity_is_empty")
    func filterEventForScopePassesThroughWhenPayloadSensitivityIsEmpty() throws {
        // 古い events.jsonl から復元したケース。payloadSensitivity が空でも event-level でフィルタが効く。
        let event = LocalContextEvent(
            id: "evt_x",
            sequence: 1,
            observedAt: Date(),
            name: "ac_power_connected",
            payload: ["to": "ac"],
            sensitivity: "low",
            maxFieldSensitivity: "")

        let filtered = try #require(
            SensitivityScopeFilter.filterEventForScope(event, scopes: ["context.low:read"]))
        #expect(filtered.payload.contains("to"))
    }
}

@Suite("HubIngest")
struct HubIngestTests {
    private static func snapshot(observedAt: Date) -> AmbientContextSnapshot {
        AmbientContextSnapshot(
            observedAt: observedAt,
            outboundEvents: [
                AmbientOutboundEvent(
                    observedAt: observedAt,
                    name: "media_session_changed",
                    value: "Imagine",
                    payload: ["title": "Imagine", "source_app": "Chrome"],
                    sensitivity: "medium")
            ],
            privacyClassifications: [
                PrivacyClassification(path: "events.media_session_changed", sensitivity: "medium", defaultTransmit: false),
                PrivacyClassification(path: "events.media_session_changed.title", sensitivity: "high", defaultTransmit: false)
            ])
    }

    @Test("Ingest_populates_payload_sensitivity_from_classifications")
    func ingestPopulatesPayloadSensitivityFromClassifications() throws {
        let hub = LocalContextHubTestFactory.createInMemory()
        let observedAt = Date()

        hub.ingest(Self.snapshot(observedAt: observedAt))

        let poll = hub.pollEvents(LocalContextPollRequest(
            clientId: "test",
            scopes: ["context.high:read"],
            since: observedAt.addingTimeInterval(-60)))

        #expect(poll.events.count == 1)
        let event = try #require(poll.events.first)
        #expect(event.payloadSensitivity["title"] == "high")
        #expect(event.payloadSensitivity["source_app"] == "medium")
        #expect(event.maxFieldSensitivity == "high")
    }

    @Test("PollEvents_with_medium_scope_strips_high_payload_keys_but_keeps_event")
    func pollEventsWithMediumScopeStripsHighPayloadKeysButKeepsEvent() throws {
        let hub = LocalContextHubTestFactory.createInMemory()
        let observedAt = Date()

        hub.ingest(Self.snapshot(observedAt: observedAt))

        let poll = hub.pollEvents(LocalContextPollRequest(
            clientId: "test",
            scopes: ["context.medium:read"],
            since: observedAt.addingTimeInterval(-60)))

        #expect(poll.events.count == 1)
        let event = try #require(poll.events.first)
        #expect(!event.payload.contains("title"))
        #expect(event.payload["source_app"] == "Chrome")
        #expect(event.maxFieldSensitivity == "medium")
    }
}
