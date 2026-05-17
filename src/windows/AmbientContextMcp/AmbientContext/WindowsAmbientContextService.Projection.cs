using AmbientContextMcp.Core.Models;

namespace AmbientContextMcp.AmbientContext;

public sealed partial class WindowsAmbientContextService
{
    private static readonly TimeSpan OutboundEventDeduplicationWindow = TimeSpan.FromSeconds(2);

    private static readonly IReadOnlyDictionary<string, string[]> HigherLevelEventsBySuppressedEvent =
        new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase)
        {
            // foreground_app_category_changed は廃止済み (foreground_changed の category_changed フラグに統合)。
            // 抑止対象が無くなったため foreground_changed エントリも削除。
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
        return AmbientContextCatalog.GetPrivacyClassifications();
    }
}
