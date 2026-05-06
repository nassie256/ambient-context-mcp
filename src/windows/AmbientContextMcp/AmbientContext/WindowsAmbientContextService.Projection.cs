using AmbientContextMcp.Core.Models;

namespace AmbientContextMcp.AmbientContext;

public sealed partial class WindowsAmbientContextService
{
    private static readonly TimeSpan OutboundEventDeduplicationWindow = TimeSpan.FromSeconds(2);

    private static readonly IReadOnlyDictionary<string, string[]> HigherLevelEventsBySuppressedEvent =
        new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase)
        {
            ["foreground_changed"] =
            [
                "foreground_app_category_changed"
            ],
            ["presence_bucket_changed"] =
            [
                "user_returned",
                "user_became_idle"
            ],
            ["power_setting_changed"] =
            [
                "power_source_changed",
                "ac_power_connected",
                "battery_power_active",
                "short_term_power_active",
                "battery_percent_crossed_threshold",
                "battery_medium",
                "battery_low",
                "battery_critical"
            ],
            ["power_source_changed"] =
            [
                "ac_power_connected",
                "battery_power_active",
                "short_term_power_active"
            ]
        };

    private IReadOnlyList<AmbientState> BuildStates(
        DateTimeOffset observedAt,
        PresenceContext presence,
        ForegroundAppContext foreground,
        BatteryContext battery,
        NetworkContext network,
        MediaContext media,
        PowerContext power,
        SystemContext system,
        SystemLoadContext systemLoad,
        ActivityContext activity,
        WellnessContext wellness,
        IReadOnlyList<DisplayContext> displays)
    {
        var states = new List<AmbientState>
        {
            State(observedAt, "presence.bucket", presence.Bucket),
            State(observedAt, "presence.idleSeconds", presence.IdleSeconds?.ToString() ?? "unknown", "medium"),
            State(observedAt, "presence.sessionLocked", presence.SessionLocked.ToString().ToLowerInvariant(), "medium"),
            State(observedAt, "foregroundApp.category", foreground.Category, "medium"),
            State(observedAt, "foregroundApp.appName", foreground.AppName, "medium"),
            State(observedAt, "foregroundApp.processName", foreground.ProcessName, "medium"),
            State(observedAt, "battery.bucket", battery.Bucket),
            State(observedAt, "battery.percent", battery.Percent?.ToString() ?? "unknown"),
            State(observedAt, "battery.charging", battery.Charging?.ToString().ToLowerInvariant() ?? "unknown"),
            State(observedAt, "network.isAvailable", network.IsAvailable.ToString().ToLowerInvariant()),
            State(observedAt, "media.isAvailable", media.IsAvailable.ToString().ToLowerInvariant(), "medium"),
            State(observedAt, "media.playbackStatus", media.PlaybackStatus, "medium"),
            State(observedAt, "media.sourceAppUserModelId", media.SourceAppUserModelId, "medium"),
            State(observedAt, "system.timeZoneId", system.TimeZoneId, "medium"),
            State(observedAt, "system.uptimeSeconds", system.UptimeSeconds.ToString()),
            State(observedAt, "system.cpuPressureBucket", systemLoad.CpuPressureBucket),
            State(observedAt, "system.memoryPressureBucket", systemLoad.MemoryPressureBucket),
            State(observedAt, "wellness.continuousActiveMinutes", wellness.ContinuousActiveMinutes.ToString()),
            State(observedAt, "wellness.minutesSinceLastBreak", wellness.MinutesSinceLastBreak.ToString()),
            State(observedAt, "activity.contextSwitchesPerMin", activity.ContextSwitchesPerMin.ToString(), "medium"),
            State(observedAt, "display.count", displays.Count.ToString(), "medium")
        };

        foreach (var item in foreground.TitleSummary)
        {
            states.Add(State(observedAt, "foregroundApp.titleSummary." + item.Key, item.Value, "medium"));
        }

        if (!string.IsNullOrWhiteSpace(foreground.RawWindowTitle))
        {
            states.Add(State(observedAt, "foregroundApp.rawWindowTitle", foreground.RawWindowTitle, "high"));
        }

        if (!string.IsNullOrWhiteSpace(media.Title))
        {
            states.Add(State(observedAt, "media.title", media.Title, "high"));
        }

        if (!string.IsNullOrWhiteSpace(media.Artist))
        {
            states.Add(State(observedAt, "media.artist", media.Artist, "high"));
        }

        foreach (var setting in power.LastKnownSettings)
        {
            states.Add(State(observedAt, "power.lastKnownSettings." + setting.Key, setting.Value));
        }

        return states;
    }

    private static IReadOnlyList<AmbientOutboundEvent> BuildEvents(IReadOnlyList<AmbientEvent> events)
    {
        return DeduplicateOutboundEvents(events
            .Where(item => !item.InitializationOnly)
            .ToList())
            .TakeLast(10)
            .Select(item => new AmbientOutboundEvent
            {
                ObservedAt = item.ObservedAt,
                Name = item.Kind,
                Value = GetEventValue(item),
                Payload = item.Data,
                Sensitivity = item.Sensitivity
            })
            .ToList();
    }

    private static IReadOnlyList<AmbientEvent> DeduplicateOutboundEvents(IReadOnlyList<AmbientEvent> events)
    {
        return events
            .Where(item => !HasNearbyHigherLevelEvent(item, events))
            .ToList();
    }

    private static bool HasNearbyHigherLevelEvent(AmbientEvent ambientEvent, IReadOnlyList<AmbientEvent> events)
    {
        if (!HigherLevelEventsBySuppressedEvent.TryGetValue(ambientEvent.Kind, out var higherLevelEvents))
        {
            return false;
        }

        return events.Any(candidate =>
            !ReferenceEquals(candidate, ambientEvent) &&
            higherLevelEvents.Contains(candidate.Kind, StringComparer.OrdinalIgnoreCase) &&
            IsWithinDeduplicationWindow(ambientEvent.ObservedAt, candidate.ObservedAt));
    }

    private static bool IsWithinDeduplicationWindow(DateTimeOffset left, DateTimeOffset right)
    {
        return Duration(left - right) <= OutboundEventDeduplicationWindow;
    }

    private static TimeSpan Duration(TimeSpan value)
    {
        return value < TimeSpan.Zero ? -value : value;
    }

    private static string GetEventValue(AmbientEvent ambientEvent)
    {
        if (ambientEvent.Data.TryGetValue("to", out var toValue))
        {
            return toValue;
        }

        if (ambientEvent.Data.TryGetValue("value", out var value))
        {
            return value;
        }

        return "true";
    }

    private static AmbientState State(DateTimeOffset observedAt, string name, string value, string sensitivity = "low")
    {
        return new AmbientState
        {
            ObservedAt = observedAt,
            Name = name,
            Value = value,
            Sensitivity = sensitivity
        };
    }

    /// <summary>
    /// 設定ダイアログなど UI 側で classification 一覧を参照するための公開ラッパ。
    /// </summary>
    public static IReadOnlyList<PrivacyClassification> GetPrivacyClassificationsForUi()
    {
        return GetPrivacyClassifications();
    }

    private static IReadOnlyList<PrivacyClassification> GetPrivacyClassifications()
    {
        return
        [
            Privacy("presence.bucket", "low", true, "active/idle/away程度の粗い状態。自発発話や通知タイミングに有用。"),
            Privacy("presence.idleSeconds", "medium", false, "作業リズムを細かく推測できるため、送信はOpt-in向き。"),
            Privacy("presence.sessionLocked", "medium", false, "離席や復帰の推測に使えるため、送信はOpt-in向き。"),
            Privacy("events.presence_bucket_changed", "low", true, "在席状態の粗い遷移。状態値より自発発話トリガに向く。"),
            Privacy("events.user_returned", "low", true, "復帰時発話に直結する低機微イベント。"),
            Privacy("events.user_became_idle", "low", true, "割り込み抑制に使いやすい低機微イベント。"),
            Privacy("events.session_locked", "medium", false, "離席状態を示すため、送信はOpt-in向き。"),
            Privacy("events.session_unlocked", "medium", false, "復帰状態を示すため、送信はOpt-in向き。"),
            Privacy("events.session_logon", "medium", false, "OSセッション開始を示すため、送信はOpt-in向き。"),
            Privacy("events.session_logoff", "medium", false, "OSセッション終了を示すため、送信はOpt-in向き。"),

            Privacy("foregroundApp.category", "medium", false, "作業種別の推定に有用だが、行動履歴になりうる。"),
            Privacy("foregroundApp.appName", "medium", false, "利用アプリ名は作業内容の手がかりになる。"),
            Privacy("foregroundApp.processName", "medium", false, "アプリ識別子として有用だが、利用環境の詳細に当たる。"),
            Privacy("foregroundApp.rawWindowTitle", "high", false, "ページ名、ファイル名、DM相手、検索語などが混入しやすい。既定では送信しない。"),
            Privacy("foregroundApp.titleSummary", "medium", false, "生タイトルより低機微だが、既知サイト名や拡張子から作業内容を推測できる。"),
            Privacy("events.foreground_app_category_changed", "medium", false, "作業カテゴリの遷移。便利だが行動履歴になりうる。"),
            Privacy("activity.contextSwitchesPerMin", "medium", false, "アプリ切替頻度から作業リズムを推測できるためOpt-in向き。"),
            Privacy("events.context_switch_burst", "medium", false, "短時間のアプリ切替増加。作業リズムの履歴になるためOpt-in向き。"),

            Privacy("battery.bucket", "low", true, "低電力時の注意喚起に有用で、個人情報性は低い。"),
            Privacy("battery.percent", "low", true, "電源文脈として有用で、単体の機微性は低い。"),
            Privacy("battery.charging", "low", true, "充電開始/停止イベントに有用。"),
            Privacy("events.battery_percent_crossed_threshold", "low", true, "80/50/30/20%の節目通過。発話トリガとして有用。"),
            Privacy("events.battery_medium", "low", true, "バッテリー残量が中程度まで下がったことを示す低機微イベント。"),
            Privacy("events.battery_low", "low", true, "低電力時の注意喚起に有用な低機微イベント。"),
            Privacy("events.battery_critical", "low", true, "電源切れ回避に有用な低機微イベント。"),
            Privacy("events.charger_connected", "low", true, "充電開始を示す低機微イベント。"),
            Privacy("events.charger_disconnected", "low", true, "充電停止を示す低機微イベント。"),
            Privacy("power.lastKnownSettings", "low", true, "AC/DC、画面状態、節電状態など。発話トリガに有用で機微性は低め。"),
            Privacy("events.power_setting_changed", "low", true, "AC/DCや画面電源などの粗い電源状態変化。"),
            Privacy("events.power_source_changed", "low", true, "AC接続/バッテリー駆動への遷移。状態値より発話トリガとして使いやすい。"),
            Privacy("events.ac_power_connected", "low", true, "電源ケーブル接続を示す低機微イベント。"),
            Privacy("events.battery_power_active", "low", true, "バッテリー駆動へ切り替わったことを示す低機微イベント。"),
            Privacy("events.short_term_power_active", "low", true, "短期電源状態を示す低機微イベント。"),
            Privacy("events.system_suspend", "low", true, "スリープ開始を示す低機微イベント。"),
            Privacy("events.system_resume_user", "low", true, "ユーザー操作による復帰を示す低機微イベント。"),
            Privacy("events.system_resume_automatic", "low", true, "自動復帰を示す低機微イベント。"),

            Privacy("network.isAvailable", "low", true, "オンライン/オフライン判定のみ。"),
            Privacy("events.network_connectivity_changed", "low", true, "オンライン/オフライン遷移。同期や再接続通知に有用。"),

            Privacy("media.isAvailable", "medium", false, "メディアセッションの有無は行動文脈になりうるためOpt-in向き。"),
            Privacy("media.playbackStatus", "medium", false, "再生中かどうかは割り込み制御に有用だが、行動文脈に当たる。"),
            Privacy("media.sourceAppUserModelId", "medium", false, "再生元アプリ名。音楽/動画サービスの利用推測につながる。"),
            Privacy("media.title", "high", false, "曲名・動画名・配信タイトルは嗜好や閲覧内容そのもの。"),
            Privacy("media.artist", "high", false, "嗜好情報に直結するため、既定では送信しない。"),
            Privacy("media.albumTitle", "high", false, "嗜好情報に直結するため、既定では送信しない。"),
            Privacy("media.positionMilliseconds", "medium", false, "単体では低機微だが視聴行動ログになる。"),
            Privacy("media.sessions", "high", false, "複数アプリの再生候補とタイトルを含むため、実験ログ以外では既定送信しない。"),
            Privacy("events.media_playback_started", "medium", false, "再生開始。曲名なしでも行動文脈に当たるためOpt-in向き。"),
            Privacy("events.media_playback_paused", "medium", false, "再生一時停止。割り込み制御に有用だがOpt-in向き。"),
            Privacy("events.media_playback_stopped", "medium", false, "再生停止。割り込み制御に有用だがOpt-in向き。"),
            Privacy("events.media_playback_status_changed", "medium", false, "再生状態の変化。割り込み制御に有用だがOpt-in向き。"),
            // events.media_session_changed の payload キーは個別に分類する。
            // event 本体は「曲が変わった瞬間」のタイミング信号 (medium) で、
            // 曲名/アーティストは別 path で個別 opt-in を要求する (high)。
            Privacy("events.media_session_changed.title", "high", false, "曲名・動画名・配信タイトル。視聴履歴そのものなので個別 opt-in 推奨。"),
            Privacy("events.media_session_changed.artist", "high", false, "アーティスト/出演者。視聴履歴そのものなので個別 opt-in 推奨。"),

            Privacy("system.timeZoneId", "medium", false, "地域推定につながる。時刻挨拶にはローカル処理で足りる。"),
            Privacy("system.uptimeSeconds", "low", true, "再起動直後か長時間稼働中かの判断に使える低機微の粗い稼働時間。"),
            Privacy("system.cpuPressureBucket", "low", true, "重い処理を実行するタイミング判断に使える粗いCPU負荷。"),
            Privacy("system.memoryPressureBucket", "low", true, "重い処理を実行するタイミング判断に使える粗いメモリ負荷。"),
            Privacy("wellness.continuousActiveMinutes", "low", true, "長時間作業の注意喚起に使える粗い継続時間。"),
            Privacy("wellness.minutesSinceLastBreak", "low", true, "休憩提案に使える粗い経過時間。"),
            Privacy("events.system_under_load", "low", true, "システム負荷が高いことを示す粗いイベント。"),
            Privacy("events.long_session_warning", "low", true, "長時間作業の注意喚起イベント。"),
            Privacy("events.first_activity_today", "low", true, "当日最初の活動開始を示す低機微イベント。"),
            Privacy("display.count", "medium", false, "外部ディスプレイの有無を推測できるため、送信はOpt-in向き。"),
            Privacy("displays", "medium", false, "作業環境の構成情報。UI配置にはローカル処理で足りる。"),
            Privacy("events.timezone_changed", "medium", false, "移動や環境変化を示すが地域推定につながる。"),
            Privacy("events.display_count_changed", "medium", false, "外部モニター接続/解除。作業環境情報なのでOpt-in向き。"),

            Privacy("events.foreground_changed", "medium", false, "アプリ切替頻度から作業リズムを推測できる。"),
            Privacy("events.media_session_changed", "medium", false, "曲が変わった瞬間のタイミング信号。曲名/アーティストは別 path (.title/.artist) で個別 opt-in が必要。")
        ];
    }

    private static PrivacyClassification Privacy(string path, string sensitivity, bool defaultTransmit, string reason)
    {
        return new PrivacyClassification
        {
            Path = path,
            Sensitivity = sensitivity,
            DefaultTransmit = defaultTransmit,
            Reason = reason
        };
    }
}
