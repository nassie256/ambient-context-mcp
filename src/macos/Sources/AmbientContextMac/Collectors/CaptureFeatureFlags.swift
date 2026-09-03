import Foundation

import AmbientContextCore

/// 「その情報を集めてよいか」を **実効送信ポリシーから** 導く純関数群。
///
/// macOS では収集そのものが権限プロンプトを誘発する経路が 2 つある:
/// - ウィンドウタイトル → アクセシビリティ権限
/// - メディア → オートメーション権限
///
/// どちらも opt-in していないユーザには一切問い合わせないため、送信対象になり得ない情報は
/// 収集自体を止める。判定は `AmbientTransmissionPolicy` の公開 API
/// (`filterStates` / `filterEvents`) にダミー値を通すことで行い、ポリシー実装 (override の
/// 親方向遡上・payload キー単位判定) と必ず同じ解釈になるようにしている。
public enum CaptureFeatureFlags {
    /// タイトルが 1 つでも送信され得るなら true。
    public static func isTitleCaptureEnabled(
        policy: AmbientTransmissionPolicy,
        privacyClassifications: [PrivacyClassification]
    ) -> Bool {
        isAnyAllowed(
            statePaths: [
                "foregroundApp.rawWindowTitle",
                // titleSummary.* は `foregroundApp.titleSummary` の子として判定される。
                "foregroundApp.titleSummary.has_title"
            ],
            eventNames: ["foreground_title_changed"],
            eventPayloadKeys: ["raw_window_title", "titleSummary.has_title"],
            policy: policy,
            privacyClassifications: privacyClassifications)
    }

    /// メディア情報が 1 つでも送信され得るなら true。
    public static func isMediaCaptureEnabled(
        policy: AmbientTransmissionPolicy,
        privacyClassifications: [PrivacyClassification]
    ) -> Bool {
        isAnyAllowed(
            statePaths: [
                "media.isAvailable",
                "media.playbackStatus",
                "media.sourceAppUserModelId",
                "media.title",
                "media.artist",
                "media.albumTitle",
                "media.positionMilliseconds",
                "media.sessions"
            ],
            eventNames: [
                "media_playback_started",
                "media_playback_paused",
                "media_playback_stopped",
                "media_playback_status_changed",
                "media_session_changed"
            ],
            eventPayloadKeys: ["title", "artist", "album_title"],
            policy: policy,
            privacyClassifications: privacyClassifications)
    }

    /// state / event / event payload のいずれか 1 つでもポリシーを通過すれば true。
    ///
    /// ダミー値は「空でない」ことだけが意味を持つ (ポリシーは値を見ない)。
    static func isAnyAllowed(
        statePaths: [String],
        eventNames: [String],
        eventPayloadKeys: [String],
        policy: AmbientTransmissionPolicy,
        privacyClassifications: [PrivacyClassification]
    ) -> Bool {
        let probeStates = statePaths.map { AmbientState(name: $0, value: "probe") }
        if !policy.filterStates(probeStates, privacyClassifications: privacyClassifications).isEmpty {
            return true
        }

        var payload = CaseInsensitiveDictionary<String>()
        for key in eventPayloadKeys {
            payload[key] = "probe"
        }
        let probeEvents = eventNames.map {
            AmbientOutboundEvent(name: $0, value: "probe", payload: payload)
        }
        return !policy.filterEvents(probeEvents, privacyClassifications: privacyClassifications).isEmpty
    }
}
