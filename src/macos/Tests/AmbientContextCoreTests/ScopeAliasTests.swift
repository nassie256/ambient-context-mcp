import Foundation
import Testing
@testable import AmbientContextCore

@Suite("ScopeAlias")
struct ScopeAliasTests {
    @Test("GetStates_with_context_all_returns_all_allowed_states")
    func getStatesWithContextAllReturnsAllAllowedStates() {
        let hub = LocalContextHubTestFactory.createInMemory()
        hub.ingest(AmbientContextSnapshot(
            observedAt: Date(),
            outboundStates: [
                AmbientState(name: "presence.bucket", value: "active", sensitivity: "low"),
                AmbientState(name: "foregroundApp.category", value: "code", sensitivity: "medium"),
                AmbientState(name: "media.title", value: "Imagine", sensitivity: "high")
            ]))

        let states = hub.getContextStates(LocalContextStateRequest(scopes: ["context.all:read"]))

        #expect(states.states.count == 3)
    }

    @Test("GetStates_with_context_all_equals_high")
    func getStatesWithContextAllEqualsHigh() {
        let hub = LocalContextHubTestFactory.createInMemory()
        hub.ingest(AmbientContextSnapshot(
            observedAt: Date(),
            outboundStates: [
                AmbientState(name: "presence.bucket", value: "active", sensitivity: "low"),
                AmbientState(name: "media.title", value: "Imagine", sensitivity: "high")
            ]))

        let withAll = hub.getContextStates(LocalContextStateRequest(scopes: ["context.all:read"]))
        let withHigh = hub.getContextStates(LocalContextStateRequest(scopes: ["context.high:read"]))

        #expect(withAll.states.count == withHigh.states.count)
    }
}
