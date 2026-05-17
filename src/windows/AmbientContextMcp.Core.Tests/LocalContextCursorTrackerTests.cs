using AmbientContextMcp.Core.Hub;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class LocalContextCursorTrackerTests
{
    [Fact]
    public void Advance_records_client_position()
    {
        var tracker = new LocalContextCursorTracker();
        var now = DateTimeOffset.Now;

        tracker.Advance("client-a", 42, now);
        var result = tracker.Resolve("client-a", cursor: "", isHistoryQuery: false, firstSequence: 1, latestSequence: 100, now);

        Assert.Equal(42, result.Sequence);
        Assert.False(result.Expired);
    }

    [Fact]
    public void PruneStale_removes_entries_past_ttl()
    {
        var tracker = new LocalContextCursorTracker();
        var t0 = new DateTimeOffset(2026, 5, 1, 0, 0, 0, TimeSpan.Zero);

        tracker.Advance("old-client", 10, t0);
        tracker.Advance("fresh-client", 20, t0 + TimeSpan.FromDays(6));

        var removed = tracker.PruneStale(t0 + TimeSpan.FromDays(8), TimeSpan.FromDays(7));

        Assert.Equal(1, removed);
        Assert.Equal(1, tracker.TrackedClientCount);

        // fresh-client は残っているので Resolve で過去の sequence を返す
        var fresh = tracker.Resolve(
            "fresh-client", cursor: "", isHistoryQuery: false,
            firstSequence: 1, latestSequence: 100, now: t0 + TimeSpan.FromDays(8));
        Assert.Equal(20, fresh.Sequence);

        // old-client は落ちているので latestSequence を新規割当する
        var old = tracker.Resolve(
            "old-client", cursor: "", isHistoryQuery: false,
            firstSequence: 1, latestSequence: 100, now: t0 + TimeSpan.FromDays(8));
        Assert.Equal(100, old.Sequence);
    }

    [Fact]
    public void Resolve_touches_lastSeen_so_active_client_is_not_pruned()
    {
        var tracker = new LocalContextCursorTracker();
        var t0 = new DateTimeOffset(2026, 5, 1, 0, 0, 0, TimeSpan.Zero);

        // 古い時刻で登録
        tracker.Advance("client-a", 5, t0);

        // ほぼ TTL ぎりぎりで Resolve (Advance は呼ばない = 取得 0 件のケース)
        // 取得 0 件パスでも lastSeen が touch されて、その後 pruning から守られる必要がある。
        tracker.Resolve(
            "client-a", cursor: "", isHistoryQuery: false,
            firstSequence: 1, latestSequence: 100,
            now: t0 + TimeSpan.FromDays(6));

        // 元の t0 から見れば 8 日経過しているが、touch によって lastSeen は 6 日地点に
        // 移動しているので 6+1 = 7 日経過ではまだ残るはず (TTL = 7 日, 厳密に "未満")。
        var removed = tracker.PruneStale(
            t0 + TimeSpan.FromDays(8),
            TimeSpan.FromDays(2));
        Assert.Equal(0, removed);
        Assert.Equal(1, tracker.TrackedClientCount);
    }
}
