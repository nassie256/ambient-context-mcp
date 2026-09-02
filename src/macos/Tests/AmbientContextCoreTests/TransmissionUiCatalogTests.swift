import Testing
@testable import AmbientContextCore

@Suite("TransmissionUiCatalog")
struct TransmissionUiCatalogTests {
    @Test("Every_ui_option_links_only_classified_paths")
    func everyUiOptionLinksOnlyClassifiedPaths() {
        let classifications = Set(
            AmbientContextCatalog.getPrivacyClassifications(language: "en")
                .map { $0.path.lowercased() })

        for group in AmbientContextCatalog.getTransmissionUiGroups(language: "en") {
            for option in group.options {
                #expect(!option.linkedPaths.isEmpty)
                for path in option.linkedPaths {
                    #expect(classifications.contains(path.lowercased()))
                }
            }
        }
    }

    @Test("Flattened_transmission_options_cover_all_ui_linked_paths")
    func flattenedTransmissionOptionsCoverAllUiLinkedPaths() {
        let uiPaths = Set(
            AmbientContextCatalog.getTransmissionUiGroups(language: "en")
                .flatMap { $0.options }
                .flatMap { $0.linkedPaths }
                .map { $0.lowercased() })
        let flatPaths = Set(
            AmbientContextCatalog.getTransmissionOptions(language: "en")
                .map { $0.path.lowercased() })

        #expect(uiPaths == flatPaths)
    }

    @Test("Ui_groups_have_expected_structure")
    func uiGroupsHaveExpectedStructure() {
        let groups = AmbientContextCatalog.getTransmissionUiGroups(language: "en")

        #expect(groups.count == 4)
        #expect(groups.map(\.id) == ["foregroundApp", "activity", "media", "environment"])
        #expect(groups.flatMap(\.options).count == 11)
        for option in groups.flatMap(\.options) {
            #expect(!option.primaryPath.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
