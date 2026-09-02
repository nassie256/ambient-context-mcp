import Foundation
import Testing
@testable import AmbientContextCore

@Suite("TransmissionUiSettingsMerge")
struct TransmissionUiSettingsMergeTests {
    private static var allOptions: [TransmissionUiOptionDefinition] {
        AmbientContextCatalog.getTransmissionUiGroups(language: "en").flatMap(\.options)
    }

    @Test("MergeOverrides_keeps_shared_parent_path_when_one_media_option_is_enabled")
    func mergeOverridesKeepsSharedParentPath() {
        let merged = TransmissionUiSettingsMerge.mergeOverrides(
            existingOverrides: [:],
            options: Self.allOptions,
            enabledOptionIds: ["media.overview"])

        #expect(merged["events.media_session_changed"] == true)
        #expect(merged["media.isAvailable"] == true)
        #expect(!merged.contains("events.media_session_changed.title"))
    }

    @Test("MergeOverrides_unions_paths_from_multiple_enabled_options")
    func mergeOverridesUnionsPaths() {
        let merged = TransmissionUiSettingsMerge.mergeOverrides(
            existingOverrides: [:],
            options: Self.allOptions,
            enabledOptionIds: ["media.overview", "media.title"])

        #expect(merged["events.media_session_changed"] == true)
        #expect(merged["events.media_session_changed.title"] == true)
        #expect(!merged.contains("events.media_session_changed.artist"))
    }

    @Test("MergeOverrides_does_not_remove_unmanaged_overrides")
    func mergeOverridesDoesNotRemoveUnmanagedOverrides() {
        let merged = TransmissionUiSettingsMerge.mergeOverrides(
            existingOverrides: ["legacy.custom.path": true],
            options: Self.allOptions,
            enabledOptionIds: [])

        #expect(merged["legacy.custom.path"] == true)
    }

    @Test("IsOptionEnabled_uses_primary_path_only")
    func isOptionEnabledUsesPrimaryPathOnly() throws {
        let mediaTitle = try #require(Self.allOptions.first { $0.id == "media.title" })
        var overrides: CaseInsensitiveDictionary<Bool> = ["events.media_session_changed": true]

        #expect(!TransmissionUiSettingsMerge.isOptionEnabled(option: mediaTitle, overrides: overrides))

        overrides["media.title"] = true
        #expect(TransmissionUiSettingsMerge.isOptionEnabled(option: mediaTitle, overrides: overrides))
    }

    @Test("Every_option_primary_path_is_in_linked_paths")
    func everyOptionPrimaryPathIsInLinkedPaths() {
        for option in Self.allOptions {
            #expect(option.linkedPaths.contains { $0.lowercased() == option.primaryPath.lowercased() })
        }
    }
}
