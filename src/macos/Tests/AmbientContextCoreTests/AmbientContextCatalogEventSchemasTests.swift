import Foundation
import Testing
@testable import AmbientContextCore

@Suite("AmbientContextCatalogEventSchemas")
struct AmbientContextCatalogEventSchemasTests {
    @Test("Catalog_contains_core_event_names")
    func catalogContainsCoreEventNames() {
        let all = AmbientContextCatalog.getEventSchemas(language: "en")
        let names = Set(all.map { $0.name.lowercased() })

        #expect(names.contains("foreground_changed"))
        #expect(names.contains("foreground_title_changed"))
        #expect(names.contains("media_session_changed"))
        #expect(names.contains("first_activity_today"))
        #expect(names.contains("session_locked"))
        #expect(names.contains("battery_low"))
        #expect(names.contains("power_source_changed"))
    }

    @Test("Schema_names_are_unique")
    func schemaNamesAreUnique() {
        let all = AmbientContextCatalog.getEventSchemas(language: "en")
        let names = all.map { $0.name }
        let distinct = Set(names.map { $0.lowercased() })

        #expect(distinct.count == names.count)
    }

    @Test("Foreground_title_changed_marks_raw_window_title_as_high")
    func foregroundTitleChangedMarksRawWindowTitleAsHigh() throws {
        let schema = try #require(
            AmbientContextCatalog.getEventSchemas(language: "en")
                .first { $0.name == "foreground_title_changed" })

        #expect(schema.sensitivity == "medium")

        let rawTitle = try #require(schema.payloadKeys.first { $0.key == "raw_window_title" })
        let summary = try #require(schema.payloadKeys.first { $0.key == "titleSummary.file_ext" })
        #expect(rawTitle.sensitivity == "high")
        #expect(summary.sensitivity == "medium")
    }

    @Test("Media_session_changed_marks_title_and_artist_as_high")
    func mediaSessionChangedMarksTitleAndArtistAsHigh() throws {
        let schema = try #require(
            AmbientContextCatalog.getEventSchemas(language: "en")
                .first { $0.name == "media_session_changed" })

        #expect(schema.sensitivity == "medium")

        let title = try #require(schema.payloadKeys.first { $0.key == "title" })
        let artist = try #require(schema.payloadKeys.first { $0.key == "artist" })
        #expect(title.sensitivity == "high")
        #expect(artist.sensitivity == "high")
    }

    @Test("Every_schema_has_non_empty_description", arguments: ["en", "ja"])
    func everySchemaHasNonEmptyDescription(language: String) {
        for schema in AmbientContextCatalog.getEventSchemas(language: language) {
            #expect(
                !schema.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "Event \(schema.name) has no description")
        }
    }

    @Test("Every_payload_key_has_non_empty_description", arguments: ["en", "ja"])
    func everyPayloadKeyHasNonEmptyDescription(language: String) {
        for schema in AmbientContextCatalog.getEventSchemas(language: language) {
            for key in schema.payloadKeys {
                #expect(
                    !key.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    "Event \(schema.name) key \(key.key) has no description")
            }
        }
    }

    @Test("GetEventSchemas_via_hub_returns_catalog")
    func getEventSchemasViaHubReturnsCatalog() {
        let hub = LocalContextHubTestFactory.createInMemory()

        let response = hub.getEventSchemas()

        #expect(response.source == "eventSchemaCatalog")
        #expect(!response.events.isEmpty)
    }

    @Test("Every_event_schema_has_privacy_classification")
    func everyEventSchemaHasPrivacyClassification() {
        let classifications = Set(
            AmbientContextCatalog.getPrivacyClassifications(language: "en")
                .map { $0.path.lowercased() })

        for schema in AmbientContextCatalog.getEventSchemas(language: "en") {
            #expect(classifications.contains("events.\(schema.name)".lowercased()))
        }
    }

    @Test("Every_transmission_option_has_privacy_classification")
    func everyTransmissionOptionHasPrivacyClassification() {
        let classifications = Set(
            AmbientContextCatalog.getPrivacyClassifications(language: "en")
                .map { $0.path.lowercased() })

        for group in AmbientContextCatalog.getTransmissionUiGroups(language: "en") {
            for option in group.options {
                for path in option.linkedPaths {
                    #expect(classifications.contains(path.lowercased()))
                }
            }
        }
    }
}
