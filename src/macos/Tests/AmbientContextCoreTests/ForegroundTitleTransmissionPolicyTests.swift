import Foundation
import Testing
@testable import AmbientContextCore

@Suite("ForegroundTitleTransmissionPolicy")
struct ForegroundTitleTransmissionPolicyTests {
    @Test("FilterEvents_strips_high_payload_until_raw_title_opt_in")
    func filterEventsStripsHighPayloadUntilRawTitleOptIn() throws {
        let store = InMemorySettingsStore(
            persistEventLog: false,
            transmissionSettings: AmbientTransmissionSettings(
                schemaVersion: 1,
                pathTransmitOverrides: [
                    "events.foreground_title_changed": true,
                    "events.foreground_title_changed.titleSummary": true
                ]))
        let classifications = AmbientContextCatalog.getPrivacyClassifications(language: "en")
        let policy = AmbientTransmissionPolicy.load(store: store, privacyClassifications: classifications)

        let filtered = policy.filterEvents([
            AmbientOutboundEvent(
                observedAt: AmbientDateFormat.parse("2026-05-23T12:00:00+09:00")!,
                name: "foreground_title_changed",
                value: "true",
                payload: [
                    "process_name": "Code.exe",
                    "titleSummary.file_ext": "cs",
                    "raw_window_title": "Program.cs - demo"
                ],
                sensitivity: "medium")
        ], privacyClassifications: classifications)

        #expect(filtered.count == 1)
        let payload = try #require(filtered.first).payload
        #expect(payload["process_name"] == "Code.exe")
        #expect(payload["titleSummary.file_ext"] == "cs")
        #expect(!payload.contains("raw_window_title"))
    }
}
