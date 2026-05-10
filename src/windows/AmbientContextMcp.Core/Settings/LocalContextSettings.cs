namespace AmbientContextMcp.Core.Settings;

public sealed class LocalContextSettings
{
    public int SchemaVersion { get; init; } = 1;

    public int MaxEventAgeHours { get; init; } = 24;

    public int MaxEventCount { get; init; } = 500;

    /// <summary>
    /// 既定 false。true の場合、Hub のイベント履歴を %LOCALAPPDATA%\AmbientContextMcp\events.jsonl
    /// に追記し、再起動を跨いで保持期間内の履歴を保つ。送信ポリシーで許可された outbound イベントのみが保存される。
    /// </summary>
    public bool PersistEventLog { get; init; }
}
