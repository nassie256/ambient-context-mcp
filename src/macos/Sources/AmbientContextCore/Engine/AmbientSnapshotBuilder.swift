import Foundation

/// C# `WindowsAmbientContextService.CaptureAsync` の後半 (states / events / 分類の投影) と
/// `ApplyTransmissionPolicy` に相当する組み立て。
///
/// Collector から得た各 Context 値と `TransitionEvaluator` があれば送信用スナップショットが
/// 作れるので、Phase 3b の `MacAmbientContextService` は値の収集だけに集中できる。
public enum AmbientSnapshotBuilder {
    /// 遷移評価 → イベント取得 → 投影 → 送信ポリシー適用 を C# と同じ順序で実行する。
    ///
    /// `activity` / `wellness` は評価より前に確定している必要があるので、呼び出し側で
    /// `evaluator.activity(at:)` / `evaluator.wellness(presence:at:)` を先に呼んでから渡すこと。
    public static func capture(
        observedAt: Date,
        source: String = "macos-desktop",
        evaluator: TransitionEvaluator,
        presence: PresenceContext,
        foreground: ForegroundAppContext,
        battery: BatteryContext,
        network: NetworkContext,
        media: MediaContext,
        power: PowerContext,
        system: SystemContext,
        systemLoad: SystemLoadContext,
        activity: ActivityContext,
        wellness: WellnessContext,
        displays: [DisplayContext],
        privacyClassifications: [PrivacyClassification],
        transmissionPolicy: AmbientTransmissionPolicy
    ) -> AmbientContextSnapshot {
        evaluator.evaluate(
            observedAt: observedAt,
            presence: presence,
            foreground: foreground,
            battery: battery,
            network: network,
            media: media,
            power: power,
            system: system,
            systemLoad: systemLoad,
            activity: activity,
            wellness: wellness,
            displays: displays)

        return build(
            observedAt: observedAt,
            source: source,
            presence: presence,
            foreground: foreground,
            battery: battery,
            network: network,
            media: media,
            power: power,
            system: system,
            systemLoad: systemLoad,
            activity: activity,
            wellness: wellness,
            displays: displays,
            recentEvents: evaluator.recentEvents(),
            privacyClassifications: privacyClassifications,
            transmissionPolicy: transmissionPolicy)
    }

    /// 遷移評価済みの値からスナップショットを組み立てる (投影 + 送信ポリシー適用のみ)。
    public static func build(
        observedAt: Date,
        source: String = "macos-desktop",
        presence: PresenceContext,
        foreground: ForegroundAppContext,
        battery: BatteryContext,
        network: NetworkContext,
        media: MediaContext,
        power: PowerContext,
        system: SystemContext,
        systemLoad: SystemLoadContext,
        activity: ActivityContext,
        wellness: WellnessContext,
        displays: [DisplayContext],
        recentEvents: [AmbientEvent],
        privacyClassifications: [PrivacyClassification],
        transmissionPolicy: AmbientTransmissionPolicy
    ) -> AmbientContextSnapshot {
        let states = AmbientContextProjector.buildStates(
            observedAt: observedAt,
            presence: presence,
            foreground: foreground,
            battery: battery,
            network: network,
            media: media,
            power: power,
            system: system,
            systemLoad: systemLoad,
            activity: activity,
            wellness: wellness,
            displays: displays)
        let events = AmbientContextProjector.buildEvents(recentEvents)

        return AmbientContextSnapshot(
            observedAt: observedAt,
            source: source,
            presence: presence,
            foregroundApp: foreground,
            battery: battery,
            network: network,
            media: media,
            power: power,
            system: system,
            systemLoad: systemLoad,
            activity: activity,
            wellness: wellness,
            displays: displays,
            recentEvents: recentEvents,
            states: states,
            events: events,
            outboundStates: transmissionPolicy.filterStates(states, privacyClassifications: privacyClassifications),
            outboundEvents: transmissionPolicy.filterEvents(events, privacyClassifications: privacyClassifications),
            privacyClassifications: privacyClassifications,
            transmissionPolicy: transmissionPolicy.snapshot)
    }
}
