namespace AmbientContextMcp.Core.Models;

public sealed class AmbientContextSnapshot
{
    public int SchemaVersion { get; init; } = 2;

    public DateTimeOffset ObservedAt { get; init; }

    public string Source { get; init; } = "windows-desktop";

    public PresenceContext Presence { get; init; } = new();

    public ForegroundAppContext ForegroundApp { get; init; } = new();

    public BatteryContext Battery { get; init; } = new();

    public NetworkContext Network { get; init; } = new();

    public MediaContext Media { get; init; } = new();

    public PowerContext Power { get; init; } = new();

    public SystemContext System { get; init; } = new();

    public SystemLoadContext SystemLoad { get; init; } = new();

    public ActivityContext Activity { get; init; } = new();

    public WellnessContext Wellness { get; init; } = new();

    public IReadOnlyList<DisplayContext> Displays { get; init; } = [];

    public IReadOnlyList<AmbientEvent> RecentEvents { get; init; } = [];

    public IReadOnlyList<AmbientState> States { get; init; } = [];

    public IReadOnlyList<AmbientOutboundEvent> Events { get; init; } = [];

    public IReadOnlyList<AmbientState> OutboundStates { get; init; } = [];

    public IReadOnlyList<AmbientOutboundEvent> OutboundEvents { get; init; } = [];

    public IReadOnlyList<PrivacyClassification> PrivacyClassifications { get; init; } = [];

    public AmbientTransmissionPolicySnapshot TransmissionPolicy { get; init; } = new();
}

public sealed class PresenceContext
{
    public int? IdleSeconds { get; init; }

    public string Bucket { get; init; } = "unknown";

    public bool SessionLocked { get; init; }
}

public sealed class ForegroundAppContext
{
    public string ProcessName { get; init; } = "";

    public int? ProcessId { get; init; }

    public string AppName { get; init; } = "";

    public string Category { get; init; } = "unknown";

    public bool HasWindowTitle { get; init; }

    public string RawWindowTitle { get; init; } = "";

    public IReadOnlyDictionary<string, string> TitleSummary { get; init; } =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
}

public sealed class BatteryContext
{
    public bool Present { get; init; }

    public int? Percent { get; init; }

    public bool? Charging { get; init; }

    public bool? OnAcPower { get; init; }

    public bool? BatterySaver { get; init; }

    public string Bucket { get; init; } = "unknown";
}

public sealed class NetworkContext
{
    public bool IsAvailable { get; init; }

    public IReadOnlyList<string> InterfaceKinds { get; init; } = [];
}

public sealed class MediaContext
{
    public bool IsAvailable { get; init; }

    public string SourceAppUserModelId { get; init; } = "";

    public string PlaybackStatus { get; init; } = "unknown";

    public bool? IsPlaying { get; init; }

    public string Title { get; init; } = "";

    public string Artist { get; init; } = "";

    public string AlbumTitle { get; init; } = "";

    public string AlbumArtist { get; init; } = "";

    public int TrackNumber { get; init; }

    public IReadOnlyList<string> Genres { get; init; } = [];

    public long? PositionMilliseconds { get; init; }

    public long? StartTimeMilliseconds { get; init; }

    public long? EndTimeMilliseconds { get; init; }

    public DateTimeOffset? TimelineLastUpdatedAt { get; init; }

    public IReadOnlyList<MediaSessionContext> Sessions { get; init; } = [];

    public string Error { get; init; } = "";
}

public sealed class MediaSessionContext
{
    public bool Selected { get; init; }

    public string SourceAppUserModelId { get; init; } = "";

    public string PlaybackStatus { get; init; } = "unknown";

    public bool IsPlaying { get; init; }

    public string Title { get; init; } = "";

    public string Artist { get; init; } = "";

    public string AlbumTitle { get; init; } = "";

    public long? PositionMilliseconds { get; init; }

    public long? EndTimeMilliseconds { get; init; }

    public string Error { get; init; } = "";
}

public sealed class PowerContext
{
    public IReadOnlyDictionary<string, string> LastKnownSettings { get; init; } =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    public AmbientEvent? LastPowerSettingEvent { get; init; }
}

public sealed class SystemContext
{
    public string TimeZoneId { get; init; } = "";

    public int UtcOffsetMinutes { get; init; }

    public long UptimeSeconds { get; init; }

    public bool Is64BitOperatingSystem { get; init; }

    public string ProcessArchitecture { get; init; } = "";
}

public sealed class SystemLoadContext
{
    public int? CpuUsagePercent { get; init; }

    public string CpuPressureBucket { get; init; } = "unknown";

    public int? MemoryUsedPercent { get; init; }

    public string MemoryPressureBucket { get; init; } = "unknown";
}

public sealed class ActivityContext
{
    public int ContextSwitchesPerMin { get; init; }
}

public sealed class WellnessContext
{
    public int ContinuousActiveMinutes { get; init; }

    public int MinutesSinceLastBreak { get; init; }
}

public sealed class DisplayContext
{
    public string DeviceName { get; init; } = "";

    public bool Primary { get; init; }

    public int Left { get; init; }

    public int Top { get; init; }

    public int Width { get; init; }

    public int Height { get; init; }

    public int WorkAreaLeft { get; init; }

    public int WorkAreaTop { get; init; }

    public int WorkAreaWidth { get; init; }

    public int WorkAreaHeight { get; init; }

    public int BitsPerPixel { get; init; }
}

public sealed class AmbientEvent
{
    public DateTimeOffset ObservedAt { get; init; }

    public string Kind { get; init; } = "";

    public string Sensitivity { get; init; } = "low";

    public bool InitializationOnly { get; init; }

    public IReadOnlyDictionary<string, string> Data { get; init; } =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
}

public sealed class AmbientState
{
    public DateTimeOffset ObservedAt { get; init; }

    public string Name { get; init; } = "";

    public string Value { get; init; } = "";

    public string Sensitivity { get; init; } = "low";
}

public sealed class AmbientOutboundEvent
{
    public DateTimeOffset ObservedAt { get; init; }

    public string Name { get; init; } = "";

    public string Value { get; init; } = "";

    public IReadOnlyDictionary<string, string> Payload { get; init; } =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    public string Sensitivity { get; init; } = "low";
}

public sealed class PrivacyClassification
{
    public string Path { get; init; } = "";

    public string Sensitivity { get; init; } = "low";

    public bool DefaultTransmit { get; init; }

    public string Reason { get; init; } = "";
}

public sealed class AmbientTransmissionPolicySnapshot
{
    public string SettingsPath { get; init; } = "";

    public int ExplicitOverrideCount { get; init; }

    public string DefaultBehavior { get; init; } = "privacyClassifications.defaultTransmit";

    public IReadOnlyDictionary<string, bool> PathTransmitOverrides { get; init; } =
        new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
}
