import Foundation
import Testing
@testable import AmbientContextCore

@Suite("StateMetadata")
struct StateMetadataTests {
    @Test("GetContextStates_omits_metadata_when_requested")
    func getContextStatesOmitsMetadataWhenRequested() throws {
        let hub = LocalContextHubTestFactory.createInMemory()
        let observedAt = Date()

        hub.ingest(AmbientContextSnapshot(
            observedAt: observedAt,
            outboundStates: [
                AmbientState(
                    observedAt: observedAt,
                    name: "battery.bucket",
                    value: "ok",
                    sensitivity: "low")
            ]))

        let response = hub.getContextStates(LocalContextStateRequest(includeMetadata: false))

        #expect(response.states.count == 1)
        let state = try #require(response.states.first)
        #expect(state.name == "battery.bucket")
        #expect(state.value == "ok")
        #expect(state.observedAt == nil)
        #expect(state.sensitivity == nil)
    }
}
