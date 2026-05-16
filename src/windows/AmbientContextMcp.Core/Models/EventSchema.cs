namespace AmbientContextMcp.Core.Models;

/// <summary>
/// イベント単位の payload スキーマを記述する。<c>ambient_context_describe_events</c> ツール経由で
/// クライアントが「foreground_changed の payload には何が入るか」「media_session_changed の title は高機微か」
/// などを 1 回で参照できるようにする。
/// </summary>
public sealed class EventSchema
{
    public string Name { get; init; } = "";

    public string Sensitivity { get; init; } = "low";

    public string Description { get; init; } = "";

    public IReadOnlyList<EventPayloadKey> PayloadKeys { get; init; } = [];
}

public sealed class EventPayloadKey
{
    public string Key { get; init; } = "";

    public string Sensitivity { get; init; } = "low";

    public string Description { get; init; } = "";

    public string Example { get; init; } = "";
}
