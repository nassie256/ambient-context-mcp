import Foundation
import Testing
@testable import AmbientContextCore

@Suite("PollSummaryMode")
struct PollSummaryModeTests {
    private static func buildSingleEventSnapshot(observedAt: Date) -> AmbientContextSnapshot {
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

    @Test("Default_poll_request_includes_payload")
    func defaultPollRequestIncludesPayload() throws {
        let hub = LocalContextHubTestFactory.createInMemory()
        let observedAt = Date()

        hub.ingest(Self.buildSingleEventSnapshot(observedAt: observedAt))

        let poll = hub.pollEvents(LocalContextPollRequest(
            clientId: "test",
            scopes: ["context.high:read"],
            since: observedAt.addingTimeInterval(-60)))

        #expect(poll.events.count == 1)
        let event = try #require(poll.events.first)
        #expect(event.payload["title"] == "Imagine")
        #expect(event.payload["source_app"] == "Chrome")
    }

    @Test("Summary_mode_strips_payload_and_payload_sensitivity")
    func summaryModeStripsPayloadAndPayloadSensitivity() throws {
        let hub = LocalContextHubTestFactory.createInMemory()
        let observedAt = Date()

        hub.ingest(Self.buildSingleEventSnapshot(observedAt: observedAt))

        let poll = hub.pollEvents(LocalContextPollRequest(
            clientId: "test",
            scopes: ["context.high:read"],
            since: observedAt.addingTimeInterval(-60),
            includePayload: false))

        #expect(poll.events.count == 1)
        let event = try #require(poll.events.first)
        #expect(event.payload.isEmpty)
        #expect(event.payloadSensitivity.isEmpty)
    }

    @Test("Summary_mode_preserves_top_level_metadata")
    func summaryModePreservesTopLevelMetadata() throws {
        let hub = LocalContextHubTestFactory.createInMemory()
        let observedAt = Date()

        hub.ingest(Self.buildSingleEventSnapshot(observedAt: observedAt))

        let poll = hub.pollEvents(LocalContextPollRequest(
            clientId: "test",
            scopes: ["context.high:read"],
            since: observedAt.addingTimeInterval(-60),
            includePayload: false))

        #expect(poll.events.count == 1)
        let event = try #require(poll.events.first)
        #expect(!event.id.isEmpty)
        #expect(event.name == "media_session_changed")
        #expect(event.value == "Imagine")
        #expect(event.sensitivity == "medium")
        #expect(event.maxFieldSensitivity == "high")
    }
}
