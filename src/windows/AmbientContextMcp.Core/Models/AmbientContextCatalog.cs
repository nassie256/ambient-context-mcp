using System.Globalization;

namespace AmbientContextMcp.Core.Models;

public static partial class AmbientContextCatalog
{
    public static IReadOnlyList<PrivacyClassification> GetPrivacyClassifications()
    {
        return
        [
            Privacy("presence.bucket", "low", true,
                "active/idle/away程度の粗い状態。自発発話や通知タイミングに有用。",
                "Coarse-grained presence (active/idle/away). Useful for proactive prompts and notification timing."),
            Privacy("presence.idleSeconds", "medium", false,
                "作業リズムを細かく推測できるため、送信はOpt-in向き。",
                "Reveals fine-grained work rhythm; opt-in only."),
            Privacy("presence.sessionLocked", "medium", false,
                "離席や復帰の推測に使えるため、送信はOpt-in向き。",
                "Implies away/return state; opt-in only."),
            Privacy("events.presence_bucket_changed", "low", true,
                "在席状態の粗い遷移。状態値より自発発話トリガに向く。",
                "Coarse presence transition. More useful as a proactive trigger than as a state value."),
            Privacy("events.user_returned", "low", true,
                "復帰時発話に直結する低機微イベント。",
                "Low-sensitivity event aligned with return-to-work prompts."),
            Privacy("events.user_became_idle", "low", true,
                "割り込み抑制に使いやすい低機微イベント。",
                "Low-sensitivity event useful for suppressing interruptions."),
            Privacy("events.session_locked", "medium", false,
                "離席状態を示すため、送信はOpt-in向き。",
                "Indicates an away state; opt-in only."),
            Privacy("events.session_unlocked", "medium", false,
                "復帰状態を示すため、送信はOpt-in向き。",
                "Indicates a return-to-work state; opt-in only."),
            Privacy("events.session_logon", "medium", false,
                "OSセッション開始を示すため、送信はOpt-in向き。",
                "Indicates an OS session start; opt-in only."),
            Privacy("events.session_logoff", "medium", false,
                "OSセッション終了を示すため、送信はOpt-in向き。",
                "Indicates an OS session end; opt-in only."),

            Privacy("foregroundApp.category", "medium", false,
                "作業種別の推定に有用だが、行動履歴になりうる。",
                "Helpful for inferring task category, but can become an activity log."),
            Privacy("foregroundApp.appName", "medium", false,
                "利用アプリ名は作業内容の手がかりになる。",
                "The app name in use hints at what the user is working on."),
            Privacy("foregroundApp.processName", "medium", false,
                "アプリ識別子として有用だが、利用環境の詳細に当たる。",
                "Useful as an app identifier, but reveals details of the user's environment."),
            Privacy("foregroundApp.rawWindowTitle", "high", false,
                "ページ名、ファイル名、DM相手、検索語などが混入しやすい。既定では送信しない。",
                "Easily leaks page titles, file names, DM partners, or search queries. Off by default."),
            Privacy("foregroundApp.titleSummary", "medium", false,
                "生タイトルより低機微だが、既知サイト名や拡張子から作業内容を推測できる。",
                "Less sensitive than the raw title, but known site names or file extensions can still hint at activity."),
            Privacy("events.foreground_app_category_changed", "medium", false,
                "[廃止] foreground_changed の category_changed フラグに統合されました。このイベントは発火しません。現役イベントの一覧は ambient_context_describe_events を参照。",
                "[Deprecated] Merged into foreground_changed's category_changed flag. This event no longer fires. See ambient_context_describe_events for the active event list."),
            Privacy("activity.contextSwitchesPerMin", "medium", false,
                "アプリ切替頻度から作業リズムを推測できるためOpt-in向き。",
                "App switch frequency reveals work rhythm; opt-in only."),
            Privacy("events.context_switch_burst", "medium", false,
                "短時間のアプリ切替増加。作業リズムの履歴になるためOpt-in向き。",
                "A burst of short-interval app switches. Opt-in because it forms a work-rhythm log."),

            Privacy("battery.bucket", "low", true,
                "低電力時の注意喚起に有用で、個人情報性は低い。",
                "Useful for low-power alerts; not personally identifying."),
            Privacy("battery.percent", "low", true,
                "電源文脈として有用で、単体の機微性は低い。",
                "Useful as power context; low sensitivity on its own."),
            Privacy("battery.charging", "low", true,
                "充電開始/停止イベントに有用。",
                "Useful for charge-start/stop events."),
            Privacy("events.battery_percent_crossed_threshold", "low", true,
                "80/50/30/20%の節目通過。発話トリガとして有用。",
                "Crossing the 80 / 50 / 30 / 20 % thresholds. Useful as a prompt trigger."),
            Privacy("events.battery_medium", "low", true,
                "バッテリー残量が中程度まで下がったことを示す低機微イベント。",
                "Low-sensitivity event indicating battery has dropped to a medium level."),
            Privacy("events.battery_low", "low", true,
                "低電力時の注意喚起に有用な低機微イベント。",
                "Low-sensitivity event useful for low-power alerts."),
            Privacy("events.battery_critical", "low", true,
                "電源切れ回避に有用な低機微イベント。",
                "Low-sensitivity event useful for avoiding power loss."),
            Privacy("events.charger_connected", "low", true,
                "充電開始を示す低機微イベント。",
                "Low-sensitivity event indicating charging has started."),
            Privacy("events.charger_disconnected", "low", true,
                "充電停止を示す低機微イベント。",
                "Low-sensitivity event indicating charging has stopped."),
            Privacy("power.lastKnownSettings", "low", true,
                "AC/DC、画面状態、節電状態など。発話トリガに有用で機微性は低め。",
                "AC/DC, display state, power-save state, etc. Useful as a prompt trigger; low sensitivity."),
            Privacy("events.power_setting_changed", "low", true,
                "AC/DCや画面電源などの粗い電源状態変化。",
                "Coarse changes in power state such as AC/DC or display power."),
            Privacy("events.power_source_changed", "low", true,
                "AC接続/バッテリー駆動への遷移。状態値より発話トリガとして使いやすい。",
                "Transition between AC and battery operation. More useful as a prompt trigger than as a state value."),
            Privacy("events.ac_power_connected", "low", true,
                "電源ケーブル接続を示す低機微イベント。",
                "Low-sensitivity event indicating the power cable was plugged in."),
            Privacy("events.battery_power_active", "low", true,
                "バッテリー駆動へ切り替わったことを示す低機微イベント。",
                "Low-sensitivity event indicating a switch to battery operation."),
            Privacy("events.short_term_power_active", "low", true,
                "短期電源状態を示す低機微イベント。",
                "Low-sensitivity event indicating a short-term power state."),
            Privacy("events.system_suspend", "low", true,
                "スリープ開始を示す低機微イベント。",
                "Low-sensitivity event indicating sleep has started."),
            Privacy("events.system_resume_user", "low", true,
                "ユーザー操作による復帰を示す低機微イベント。",
                "Low-sensitivity event indicating user-driven resume."),
            Privacy("events.system_resume_automatic", "low", true,
                "自動復帰を示す低機微イベント。",
                "Low-sensitivity event indicating an automatic resume."),

            Privacy("network.isAvailable", "low", true,
                "オンライン/オフライン判定のみ。",
                "Online / offline status only."),
            Privacy("events.network_connectivity_changed", "low", true,
                "オンライン/オフライン遷移。同期や再接続通知に有用。",
                "Online / offline transition. Useful for sync and reconnect notices."),

            Privacy("media.isAvailable", "medium", false,
                "メディアセッションの有無は行動文脈になりうるためOpt-in向き。",
                "Whether a media session exists can become activity context; opt-in only."),
            Privacy("media.playbackStatus", "medium", false,
                "再生中かどうかは割り込み制御に有用だが、行動文脈に当たる。",
                "Whether media is playing helps with interruption control, but is still activity context."),
            Privacy("media.sourceAppUserModelId", "medium", false,
                "再生元アプリ名。音楽/動画サービスの利用推測につながる。",
                "The app the media is coming from. Hints at which music or video service is in use."),
            Privacy("media.title", "high", false,
                "曲名・動画名・配信タイトルは嗜好や閲覧内容そのもの。",
                "Track / video / stream titles directly reveal preferences and viewed content."),
            Privacy("media.artist", "high", false,
                "嗜好情報に直結するため、既定では送信しない。",
                "Directly tied to user taste; off by default."),
            Privacy("media.albumTitle", "high", false,
                "嗜好情報に直結するため、既定では送信しない。",
                "Directly tied to user taste; off by default."),
            Privacy("media.positionMilliseconds", "medium", false,
                "単体では低機微だが視聴行動ログになる。",
                "Low sensitivity on its own, but accumulates into a viewing-behavior log."),
            Privacy("media.sessions", "high", false,
                "複数アプリの再生候補とタイトルを含むため、実験ログ以外では既定送信しない。",
                "Contains multiple apps' playback candidates and titles; off by default outside diagnostics."),
            Privacy("events.media_playback_started", "medium", false,
                "再生開始。曲名なしでも行動文脈に当たるためOpt-in向き。",
                "Playback start. Even without a title it is still activity context; opt-in only."),
            Privacy("events.media_playback_paused", "medium", false,
                "再生一時停止。割り込み制御に有用だがOpt-in向き。",
                "Playback paused. Useful for interruption control; opt-in only."),
            Privacy("events.media_playback_stopped", "medium", false,
                "再生停止。割り込み制御に有用だがOpt-in向き。",
                "Playback stopped. Useful for interruption control; opt-in only."),
            Privacy("events.media_playback_status_changed", "medium", false,
                "再生状態の変化。割り込み制御に有用だがOpt-in向き。",
                "Playback state change. Useful for interruption control; opt-in only."),
            Privacy("events.media_session_changed.title", "high", false,
                "曲名・動画名・配信タイトル。視聴履歴そのものなので個別 opt-in 推奨。",
                "Track / video / stream title. A viewing history in itself; per-key opt-in recommended."),
            Privacy("events.media_session_changed.artist", "high", false,
                "アーティスト/出演者。視聴履歴そのものなので個別 opt-in 推奨。",
                "Artist or performer. A viewing history in itself; per-key opt-in recommended."),

            Privacy("system.timeZoneId", "medium", false,
                "地域推定につながる。時刻挨拶にはローカル処理で足りる。",
                "Can imply the user's region. Time-of-day greetings can be handled locally."),
            Privacy("system.uptimeSeconds", "low", true,
                "再起動直後か長時間稼働中かの判断に使える低機微の粗い稼働時間。",
                "Low-sensitivity coarse uptime; useful for distinguishing fresh boot from long-running."),
            Privacy("system.cpuPressureBucket", "low", true,
                "重い処理を実行するタイミング判断に使える粗いCPU負荷。",
                "Coarse CPU load; useful for deciding when to run heavy work."),
            Privacy("system.memoryPressureBucket", "low", true,
                "重い処理を実行するタイミング判断に使える粗いメモリ負荷。",
                "Coarse memory pressure; useful for deciding when to run heavy work."),
            Privacy("wellness.continuousActiveMinutes", "low", true,
                "長時間作業の注意喚起に使える粗い継続時間。",
                "Coarse continuous-active duration; useful for long-session alerts."),
            Privacy("wellness.minutesSinceLastBreak", "low", true,
                "休憩提案に使える粗い経過時間。",
                "Coarse time-since-break; useful for suggesting a rest."),
            Privacy("events.system_under_load", "low", true,
                "システム負荷が高いことを示す粗いイベント。",
                "Coarse event indicating high system load."),
            Privacy("events.long_session_warning", "low", true,
                "長時間作業の注意喚起イベント。",
                "Long-session warning event."),
            Privacy("events.first_activity_today", "low", true,
                "当日最初の活動開始を示す低機微イベント。",
                "Low-sensitivity event indicating first activity of the day."),
            Privacy("display.count", "medium", false,
                "外部ディスプレイの有無を推測できるため、送信はOpt-in向き。",
                "Implies whether an external display is connected; opt-in only."),
            Privacy("displays", "medium", false,
                "作業環境の構成情報。UI配置にはローカル処理で足りる。",
                "Workspace topology info. UI placement can be handled locally."),
            Privacy("events.timezone_changed", "medium", false,
                "移動や環境変化を示すが地域推定につながる。",
                "Indicates travel or environment change, but implies region."),
            Privacy("events.display_count_changed", "medium", false,
                "外部モニター接続/解除。作業環境情報なのでOpt-in向き。",
                "External monitor connect / disconnect. Workspace info; opt-in only."),

            Privacy("events.foreground_changed", "medium", false,
                "アプリ切替頻度から作業リズムを推測できる。",
                "App switch frequency reveals work rhythm."),
            Privacy("events.media_session_changed", "medium", false,
                "曲が変わった瞬間のタイミング信号。曲名/アーティストは別 path (.title/.artist) で個別 opt-in が必要。",
                "Timing signal at the moment a track changes. Title / artist require separate opt-in via the .title / .artist paths.")
        ];
    }

    public static IReadOnlyList<TransmissionOptionDefinition> GetTransmissionOptions()
    {
        return
        [
            Option("foregroundApp.category"),
            Option("foregroundApp.appName"),
            Option("foregroundApp.processName"),
            Option("foregroundApp.titleSummary"),
            Option("foregroundApp.rawWindowTitle"),
            Option("events.foreground_changed"),
            Option("activity.contextSwitchesPerMin"),
            Option("events.context_switch_burst"),
            Option("media.isAvailable"),
            Option("media.playbackStatus"),
            Option("media.sourceAppUserModelId"),
            Option("media.title"),
            Option("media.artist"),
            Option("media.albumTitle"),
            Option("events.media_playback_started"),
            Option("events.media_playback_paused"),
            Option("events.media_session_changed"),
            Option("events.media_session_changed.title"),
            Option("events.media_session_changed.artist"),
            Option("system.timeZoneId"),
            Option("display.count"),
            Option("displays")
        ];
    }

    private static TransmissionOptionDefinition Option(string path)
    {
        var classification = GetPrivacyClassifications()
            .Single(item => item.Path.Equals(path, StringComparison.OrdinalIgnoreCase));
        return new TransmissionOptionDefinition
        {
            Path = classification.Path,
            Sensitivity = classification.Sensitivity
        };
    }

    private static PrivacyClassification Privacy(
        string path,
        string sensitivity,
        bool defaultTransmit,
        string reasonJa,
        string reasonEn)
    {
        return new PrivacyClassification
        {
            Path = path,
            Sensitivity = sensitivity,
            DefaultTransmit = defaultTransmit,
            Reason = PickReason(reasonJa, reasonEn)
        };
    }

    private static string PickReason(string reasonJa, string reasonEn)
    {
        return string.Equals(
            CultureInfo.CurrentUICulture.TwoLetterISOLanguageName,
            "ja",
            StringComparison.OrdinalIgnoreCase)
            ? reasonJa
            : reasonEn;
    }
}

public sealed class TransmissionOptionDefinition
{
    public string Path { get; init; } = "";

    public string Sensitivity { get; init; } = "medium";
}
