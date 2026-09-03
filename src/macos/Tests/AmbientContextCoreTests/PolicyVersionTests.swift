import Foundation
import Testing
@testable import AmbientContextCore

@Suite("PolicyVersion")
struct PolicyVersionTests {
    private static let classifications = [
        PrivacyClassification(path: "media.title", sensitivity: "high", defaultTransmit: false)
    ]

    @Test("Same_policy_produces_same_version")
    func samePolicyProducesSameVersion() {
        let overrides: CaseInsensitiveDictionary<Bool> = ["media.title": true]

        let a = PolicyVersionService.computePolicyVersion(
            classifications: Self.classifications, overrides: overrides)
        let b = PolicyVersionService.computePolicyVersion(
            classifications: Self.classifications, overrides: overrides)

        #expect(!a.isEmpty)
        #expect(a == b)
    }

    @Test("Changing_override_changes_version")
    func changingOverrideChangesVersion() {
        let before = PolicyVersionService.computePolicyVersion(
            classifications: Self.classifications, overrides: [:])
        let after = PolicyVersionService.computePolicyVersion(
            classifications: Self.classifications, overrides: ["media.title": true])

        #expect(before != after)
    }

    @Test("Override_order_does_not_affect_version")
    func overrideOrderDoesNotAffectVersion() {
        let ordered1: CaseInsensitiveDictionary<Bool> = ["media.title": true, "media.artist": true]
        let ordered2: CaseInsensitiveDictionary<Bool> = ["media.artist": true, "media.title": true]

        #expect(
            PolicyVersionService.computePolicyVersion(
                classifications: Self.classifications, overrides: ordered1) ==
            PolicyVersionService.computePolicyVersion(
                classifications: Self.classifications, overrides: ordered2))
    }

    @Test("Hub_exposes_policy_version_via_state_and_poll_responses")
    func hubExposesPolicyVersionViaStateAndPollResponses() {
        let hub = LocalContextHubTestFactory.createInMemory()
        hub.ingest(AmbientContextSnapshot(
            observedAt: Date(),
            privacyClassifications: [
                PrivacyClassification(path: "media.title", sensitivity: "high", defaultTransmit: false)
            ]))

        let state = hub.getContextStates(LocalContextStateRequest())
        let poll = hub.pollEvents(LocalContextPollRequest(clientId: "test"))

        #expect(!state.policyVersion.isEmpty)
        #expect(state.policyVersion == poll.policyVersion)
    }
}
