using AmbientContextMcp.Core.Models;

namespace AmbientContextMcp.Core.Hub;

public sealed class LocalContextStateRequest
{
    public IReadOnlyList<string> Names { get; init; } = [];

    public IReadOnlyList<string> Scopes { get; init; } = [];

    public bool IncludeMetadata { get; init; } = true;
}

public sealed class LocalContextStateResponse
{
    public DateTimeOffset ObservedAt { get; init; }

    public IReadOnlyList<AmbientState> States { get; init; } = [];

    public string Source { get; init; } = "outboundStates";
}

public sealed class LocalContextPollRequest
{
    public string ClientId { get; init; } = "";

    public string Cursor { get; init; } = "";

    public IReadOnlyList<string> Names { get; init; } = [];

    public IReadOnlyList<string> Scopes { get; init; } = [];

    public int Limit { get; init; } = 50;

    /// <summary>
    /// 指定すると ObservedAt &gt;= Since のイベントのみを返す。
    /// Since または Until のいずれかが指定された呼び出しは history query 扱いとなり、
    /// クライアント位置 (cursor の暗黙進行) は更新されない。
    /// </summary>
    public DateTimeOffset? Since { get; init; }

    /// <summary>
    /// 指定すると ObservedAt &lt;= Until のイベントのみを返す。
    /// </summary>
    public DateTimeOffset? Until { get; init; }
}

public sealed class LocalContextPollResponse
{
    public IReadOnlyList<LocalContextEvent> Events { get; init; } = [];

    public string NextCursor { get; init; } = "";

    public bool HasMore { get; init; }

    public bool CursorExpired { get; init; }

    public LocalContextRetentionInfo Retention { get; init; } = new();
}

public sealed class LocalContextPolicyResponse
{
    public DateTimeOffset ObservedAt { get; init; }

    public string Source { get; init; } = "privacyClassifications";

    public AmbientTransmissionPolicySnapshot TransmissionPolicy { get; init; } = new();

    public IReadOnlyList<PrivacyClassification> PrivacyClassifications { get; init; } = [];

    public IReadOnlyList<LocalContextEffectivePolicy> EffectivePolicies { get; init; } = [];

    public int ObservedStateCount { get; init; }

    public int OutboundStateCount { get; init; }

    public int InternalEventHistoryCount { get; init; }

    public int OutboundEventCandidateCount { get; init; }

    public int RetainedOutboundEventCount { get; init; }

    public LocalContextRetentionInfo Retention { get; init; } = new();
}

public sealed class LocalContextEffectivePolicy
{
    public string Path { get; init; } = "";

    public string Sensitivity { get; init; } = "low";

    public string RequiredScope { get; init; } = "context.low:read";

    public bool DefaultTransmit { get; init; }

    public bool EffectiveTransmit { get; init; }

    public bool HasOverride { get; init; }

    public string OverridePath { get; init; } = "";

    public bool? OverrideTransmit { get; init; }

    public string Reason { get; init; } = "";
}

public sealed class LocalContextEvent
{
    public string Id { get; init; } = "";

    public long Sequence { get; init; }

    public DateTimeOffset ObservedAt { get; init; }

    public string Name { get; init; } = "";

    public string Value { get; init; } = "";

    public IReadOnlyDictionary<string, string> Payload { get; init; } =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    public string Sensitivity { get; init; } = "low";
}

public sealed class LocalContextRetentionInfo
{
    public int MaxAgeHours { get; init; } = 24;

    public int MaxEvents { get; init; } = 500;
}
