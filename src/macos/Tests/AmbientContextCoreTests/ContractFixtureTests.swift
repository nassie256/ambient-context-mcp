import Foundation
import Testing
@testable import AmbientContextCore

/// `src/macos/Fixtures/contract/*.json` (C# 版から生成した契約フィクスチャ) と
/// Swift 実装の出力が一致することを検証する。drift 対策の中核 (設計メモ §5)。
///
/// `tools-list.json` は Phase 2 (MCP サーバ) の対象なのでここでは扱わない。
@Suite("ContractFixtures")
struct ContractFixtureTests {
    // MARK: - fixture のロード

    /// #filePath から上に辿って `mcpb/manifest.json` を持つリポジトリルートを探し、
    /// `src/macos/Fixtures/contract` を返す。
    static var fixtureDirectory: URL? {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let marker = directory.appendingPathComponent("mcpb/manifest.json")
            if FileManager.default.fileExists(atPath: marker.path) {
                return directory.appendingPathComponent("src/macos/Fixtures/contract")
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    static func load<T: Decodable>(_ name: String, as type: T.Type) throws -> T {
        let directory = try #require(
            fixtureDirectory,
            "契約フィクスチャのディレクトリが見つからない (mcpb/manifest.json を持つ親を探索した)")
        let url = directory.appendingPathComponent(name)
        try #require(
            FileManager.default.fileExists(atPath: url.path),
            "契約フィクスチャ \(name) が存在しない: \(url.path)")
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
    }

    // MARK: - カタログ

    @Test("privacy_classifications_match_fixture", arguments: ["en", "ja"])
    func privacyClassificationsMatchFixture(language: String) throws {
        let expected = try Self.load(
            "privacy-classifications.\(language).json", as: [PrivacyClassification].self)
        let actual = AmbientContextCatalog.getPrivacyClassifications(language: language)

        #expect(actual.count == expected.count)
        for (index, item) in expected.enumerated() where index < actual.count {
            #expect(actual[index] == item, "privacy classification #\(index) (\(item.path)) が一致しない")
        }
    }

    @Test("event_schemas_match_fixture", arguments: ["en", "ja"])
    func eventSchemasMatchFixture(language: String) throws {
        let expected = try Self.load("event-schemas.\(language).json", as: [EventSchema].self)
        let actual = AmbientContextCatalog.getEventSchemas(language: language)

        #expect(actual.count == expected.count)
        for (index, item) in expected.enumerated() where index < actual.count {
            #expect(actual[index] == item, "event schema #\(index) (\(item.name)) が一致しない")
        }
    }

    @Test("transmission_ui_groups_match_fixture")
    func transmissionUiGroupsMatchFixture() throws {
        let expected = try Self.load(
            "transmission-ui-groups.json", as: [TransmissionUiGroupDefinition].self)
        // グループ定義に言語依存の文字列は無いので en で比較する。
        let actual = AmbientContextCatalog.getTransmissionUiGroups(language: "en")

        #expect(actual == expected)
    }

    // MARK: - policyVersion

    struct PolicyVersionCase: Decodable {
        struct Classification: Decodable {
            let path: String
            let sensitivity: String
            let defaultTransmit: Bool
        }

        let name: String
        let classifications: [Classification]
        let overrides: [String: Bool]
        let expected: String
    }

    @Test("policy_version_matches_fixture")
    func policyVersionMatchesFixture() throws {
        let cases = try Self.load("policy-version.json", as: [PolicyVersionCase].self)
        #expect(!cases.isEmpty)

        for testCase in cases {
            let classifications = testCase.classifications.map {
                PrivacyClassification(
                    path: $0.path,
                    sensitivity: $0.sensitivity,
                    defaultTransmit: $0.defaultTransmit)
            }
            var overrides = CaseInsensitiveDictionary<Bool>()
            for key in testCase.overrides.keys.sorted() {
                overrides[key] = testCase.overrides[key]
            }

            let actual = PolicyVersionService.computePolicyVersion(
                classifications: classifications, overrides: overrides)
            #expect(actual == testCase.expected, "policyVersion case \(testCase.name)")
        }
    }

    // MARK: - cursor / event id

    struct CursorEncodingFixture: Decodable {
        struct CursorCase: Decodable {
            let sequence: Int64
            let cursor: String
        }

        struct EventIdCase: Decodable {
            let observedAtUtc: String
            let sequence: Int64
            let id: String
        }

        let cursors: [CursorCase]
        let eventIdFormat: String
        let eventIds: [EventIdCase]
    }

    @Test("cursor_encoding_matches_fixture")
    func cursorEncodingMatchesFixture() throws {
        let fixture = try Self.load("cursor-encoding.json", as: CursorEncodingFixture.self)

        for testCase in fixture.cursors {
            #expect(LocalContextCursorTracker.encode(testCase.sequence) == testCase.cursor)
            #expect(LocalContextCursorTracker.decode(testCase.cursor) == testCase.sequence)
        }

        for testCase in fixture.eventIds {
            let observedAt = try #require(AmbientDateFormat.parse(testCase.observedAtUtc))
            let actual = LocalContextHub.createEventId(
                observedAt: observedAt, sequence: testCase.sequence)
            #expect(actual == testCase.id)
        }
    }

    // MARK: - transmission policy

    struct TransmissionPolicyFixture: Decodable {
        struct StateCase: Decodable {
            struct State: Decodable {
                let name: String
                let value: String
                let sensitivity: String
            }

            let name: String
            let overrides: [String: Bool]
            let states: [State]
            let expectedStateNames: [String]
        }

        struct EventCase: Decodable {
            struct Event: Decodable {
                let name: String
                let value: String
                let sensitivity: String
                let payload: [String: String]
            }

            let name: String
            let overrides: [String: Bool]
            let event: Event
            let expectedDelivered: Bool
            let expectedPayloadKeys: [String]
        }

        struct MergeCase: Decodable {
            let name: String
            let existingOverrides: [String: Bool]
            let enabledOptionIds: [String]
            let expectedOverrides: [String: Bool]
        }

        let filterStates: [StateCase]
        let filterEvents: [EventCase]
        let mergeOverrides: [MergeCase]
    }

    private static func makePolicy(
        overrides: [String: Bool],
        classifications: [PrivacyClassification]
    ) -> AmbientTransmissionPolicy {
        var typed = CaseInsensitiveDictionary<Bool>()
        for key in overrides.keys.sorted() {
            typed[key] = overrides[key]
        }
        let store = InMemorySettingsStore(
            persistEventLog: false,
            transmissionSettings: AmbientTransmissionSettings(
                schemaVersion: 1, pathTransmitOverrides: typed))
        return AmbientTransmissionPolicy.load(store: store, privacyClassifications: classifications)
    }

    @Test("filter_states_match_fixture")
    func filterStatesMatchFixture() throws {
        let fixture = try Self.load("transmission-policy-cases.json", as: TransmissionPolicyFixture.self)
        let classifications = AmbientContextCatalog.getPrivacyClassifications(language: "en")

        for testCase in fixture.filterStates {
            let policy = Self.makePolicy(overrides: testCase.overrides, classifications: classifications)
            let states = testCase.states.map {
                AmbientState(name: $0.name, value: $0.value, sensitivity: $0.sensitivity)
            }
            let filtered = policy.filterStates(states, privacyClassifications: classifications)
            #expect(filtered.map(\.name) == testCase.expectedStateNames, "filterStates case \(testCase.name)")
        }
    }

    @Test("filter_events_match_fixture")
    func filterEventsMatchFixture() throws {
        let fixture = try Self.load("transmission-policy-cases.json", as: TransmissionPolicyFixture.self)
        let classifications = AmbientContextCatalog.getPrivacyClassifications(language: "en")

        for testCase in fixture.filterEvents {
            let policy = Self.makePolicy(overrides: testCase.overrides, classifications: classifications)
            var payload = CaseInsensitiveDictionary<String>()
            for key in testCase.event.payload.keys.sorted() {
                payload[key] = testCase.event.payload[key]
            }
            let outbound = AmbientOutboundEvent(
                observedAt: Date(timeIntervalSince1970: 0),
                name: testCase.event.name,
                value: testCase.event.value,
                payload: payload,
                sensitivity: testCase.event.sensitivity)

            let filtered = policy.filterEvents([outbound], privacyClassifications: classifications)

            #expect(
                filtered.count == (testCase.expectedDelivered ? 1 : 0),
                "filterEvents case \(testCase.name) の配信可否が一致しない")
            if let delivered = filtered.first {
                #expect(
                    delivered.payload.keys.sorted() == testCase.expectedPayloadKeys.sorted(),
                    "filterEvents case \(testCase.name) の payload キーが一致しない")
            }
        }
    }

    @Test("merge_overrides_match_fixture")
    func mergeOverridesMatchFixture() throws {
        let fixture = try Self.load("transmission-policy-cases.json", as: TransmissionPolicyFixture.self)
        let options = AmbientContextCatalog.getTransmissionUiGroups(language: "en").flatMap(\.options)

        for testCase in fixture.mergeOverrides {
            var existing = CaseInsensitiveDictionary<Bool>()
            for key in testCase.existingOverrides.keys.sorted() {
                existing[key] = testCase.existingOverrides[key]
            }

            let merged = TransmissionUiSettingsMerge.mergeOverrides(
                existingOverrides: existing,
                options: options,
                enabledOptionIds: Set(testCase.enabledOptionIds))

            var actual: [String: Bool] = [:]
            for pair in merged {
                actual[pair.key] = pair.value
            }
            #expect(actual == testCase.expectedOverrides, "mergeOverrides case \(testCase.name)")
        }
    }
}
