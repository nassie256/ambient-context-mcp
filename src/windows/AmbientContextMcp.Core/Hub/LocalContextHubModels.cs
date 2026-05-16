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

    /// <summary>
    /// クライアントが get_policy を再取得すべきかを判定するための短いハッシュ。
    /// privacyClassifications と pathTransmitOverrides の合成から導出され、
    /// ポリシーに変化があった場合にのみ値が変わる。
    /// </summary>
    public string PolicyVersion { get; init; } = "";
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

    /// <summary>
    /// false の場合、各イベントから <c>payload</c> / <c>payloadSensitivity</c> を取り除いた要約形式で返す。
    /// 一覧スキャン目的のクライアントが大量取得時のレスポンスサイズを抑えるためのスイッチ。
    /// 既定 true (= 従来挙動)。
    /// </summary>
    public bool IncludePayload { get; init; } = true;
}

public sealed class LocalContextPollResponse
{
    public IReadOnlyList<LocalContextEvent> Events { get; init; } = [];

    public string NextCursor { get; init; } = "";

    public bool HasMore { get; init; }

    public bool CursorExpired { get; init; }

    public LocalContextRetentionInfo Retention { get; init; } = new();

    /// <summary>
    /// LocalContextStateResponse.PolicyVersion と同一値。クライアントは前回の値と比較して
    /// 変化があるときだけ get_policy を再取得すればよい。
    /// </summary>
    public string PolicyVersion { get; init; } = "";
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

    /// <summary>
    /// payload キーごとの機微度。Ingest 時に PrivacyClassifications から導出される。
    /// 該当 classification が無いキーは event-level <see cref="Sensitivity"/> を継承する。
    /// 古い events.jsonl から復元した場合は空 dict になり、フィルタは event-level Sensitivity にフォールバックする。
    /// </summary>
    public IReadOnlyDictionary<string, string> PayloadSensitivity { get; init; } =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// event-level Sensitivity と payload キー機微度のうち最も高いもの。
    /// クライアントが scope を判断するための一次サマリ。空文字列の場合は Sensitivity を参照する。
    /// </summary>
    public string MaxFieldSensitivity { get; init; } = "";
}

public sealed class LocalContextRetentionInfo
{
    public int MaxAgeHours { get; init; } = 24;

    public int MaxEvents { get; init; } = 500;
}
