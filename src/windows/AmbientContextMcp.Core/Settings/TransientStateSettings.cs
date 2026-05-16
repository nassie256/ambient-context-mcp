namespace AmbientContextMcp.Core.Settings;

/// <summary>
/// プロセス再起動を跨いで保持すべき軽量なランタイム状態。ユーザー設定ではなく実行時に
/// サービス自身が読み書きする。意味的には「次の起動時にも記憶しておきたい一時状態」。
/// </summary>
public sealed class TransientStateSettings
{
    public int SchemaVersion { get; init; } = 1;

    /// <summary>
    /// 最後に <c>first_activity_today</c> を発火したローカルカレンダー日。null は未発火を意味する。
    /// プロセス再起動後もこの値が当日と一致する限り、同日中の再発火を抑止する。
    /// </summary>
    public DateOnly? LastActivityDate { get; init; }
}
