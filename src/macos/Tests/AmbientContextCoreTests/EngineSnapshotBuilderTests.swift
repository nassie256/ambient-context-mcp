import Foundation
import Testing
@testable import AmbientContextCore

@Suite("EngineSnapshotBuilder")
struct EngineSnapshotBuilderTests {
    @Test("Capture_runs_evaluate_then_projects_and_applies_policy")
    func captureBuildsOutboundSnapshot() throws {
        let clock = ManualClock(EngineTestClock.base)
        let evaluator = makeEvaluator(clock: clock)
        let store = InMemorySettingsStore(persistEventLog: false)
        let classifications = AmbientContextCatalog.getPrivacyClassifications(language: "en")
        let policy = AmbientTransmissionPolicy.load(store: store, privacyClassifications: classifications)

        func capture(_ inputs: EngineInputs, at observedAt: Date) -> AmbientContextSnapshot {
            AmbientSnapshotBuilder.capture(
                observedAt: observedAt,
                evaluator: evaluator,
                presence: inputs.presence,
                foreground: inputs.foreground,
                battery: inputs.battery,
                network: inputs.network,
                media: inputs.media,
                power: evaluator.power(),
                system: inputs.system,
                systemLoad: inputs.systemLoad,
                activity: inputs.activity,
                wellness: inputs.wellness,
                displays: inputs.displays,
                privacyClassifications: classifications,
                transmissionPolicy: policy)
        }

        var inputs = EngineInputs()
        inputs.foreground = ForegroundAppContext(
            processName: "Code",
            appName: "Visual Studio Code",
            category: "editor",
            hasWindowTitle: true,
            rawWindowTitle: "secret.swift — proj",
            titleSummary: AmbientTier1Rules.summarizeWindowTitle(
                category: "editor", title: "secret.swift — proj", rules: .macOS))
        _ = capture(inputs, at: clock.current)

        clock.advance(60)
        inputs.presence = PresenceContext(idleSeconds: 30, bucket: "idle")
        let snapshot = capture(inputs, at: clock.current)

        #expect(snapshot.source == "macos-desktop")
        #expect(snapshot.observedAt == clock.current)
        #expect(snapshot.states.contains { $0.name == "presence.bucket" && $0.value == "idle" })
        #expect(snapshot.recentEvents.map(\.kind) == ["presence_bucket_changed", "user_became_idle"])
        // presence_bucket_changed は同時刻の user_became_idle に抑制される。
        #expect(snapshot.events.map(\.name) == ["user_became_idle"])
        #expect(snapshot.privacyClassifications.isEmpty == false)
        #expect(snapshot.transmissionPolicy.defaultBehavior == "privacyClassifications.defaultTransmit")

        // 既定ポリシーでは高機微な rawWindowTitle は outbound から落ちる。
        #expect(snapshot.states.contains { $0.name == "foregroundApp.rawWindowTitle" })
        #expect(snapshot.outboundStates.contains { $0.name == "foregroundApp.rawWindowTitle" } == false)
        #expect(snapshot.outboundStates.count <= snapshot.states.count)
        #expect(snapshot.outboundEvents.count <= snapshot.events.count)
    }
}
