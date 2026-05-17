using System.Text;

namespace AmbientContextMcp.Core.Hub;

public sealed class LocalContextCursorTracker
{
    // ClientId ごとの位置を永久蓄積するとリークになるので、一定期間アクセスのない
    // entry は古い順に落とす。MCP クライアントは通常 1 ホスト数個だが、UUID で
    // 毎回名乗る misbehaving client がいた場合に dict が無制限に膨らむのを防ぐ。
    public static readonly TimeSpan DefaultStaleClientTtl = TimeSpan.FromDays(7);

    private readonly Dictionary<string, Entry> _clientPositions = new(StringComparer.OrdinalIgnoreCase);

    public CursorResult Resolve(
        string clientId,
        string cursor,
        bool isHistoryQuery,
        long firstSequence,
        long latestSequence,
        DateTimeOffset now)
    {
        if (TryDecode(cursor, out var cursorSequence))
        {
            return new CursorResult(
                ClampExpired(cursorSequence, firstSequence),
                IsExpired(cursorSequence, firstSequence));
        }

        if (isHistoryQuery)
        {
            return new CursorResult(firstSequence == 0 ? 0 : Math.Max(0, firstSequence - 1), false);
        }

        var normalizedClientId = NormalizeClientId(clientId);
        if (_clientPositions.TryGetValue(normalizedClientId, out var entry))
        {
            // touch: 読み出しでも lastSeen を更新しないと、subscribe しっぱなしで
            // Advance だけ呼ばれないパス (= 取得 0 件で位置が進まない) が TTL で落ちる。
            _clientPositions[normalizedClientId] = entry with { LastSeen = now };
            return new CursorResult(
                ClampExpired(entry.Sequence, firstSequence),
                IsExpired(entry.Sequence, firstSequence));
        }

        _clientPositions[normalizedClientId] = new Entry(latestSequence, now);
        return new CursorResult(latestSequence, false);
    }

    public void Advance(string clientId, long sequence, DateTimeOffset now)
    {
        _clientPositions[NormalizeClientId(clientId)] = new Entry(sequence, now);
    }

    /// <summary>
    /// 最終アクセスから ttl 経過した client entry を削除する。戻り値は削除件数。
    /// </summary>
    public int PruneStale(DateTimeOffset now, TimeSpan? ttl = null)
    {
        var threshold = now - (ttl ?? DefaultStaleClientTtl);
        List<string>? stale = null;
        foreach (var pair in _clientPositions)
        {
            if (pair.Value.LastSeen < threshold)
            {
                (stale ??= []).Add(pair.Key);
            }
        }

        if (stale is null)
        {
            return 0;
        }

        foreach (var key in stale)
        {
            _clientPositions.Remove(key);
        }

        return stale.Count;
    }

    public int TrackedClientCount => _clientPositions.Count;

    public static string Encode(long sequence)
    {
        return Convert.ToBase64String(Encoding.UTF8.GetBytes("seq:" + sequence))
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    private static long ClampExpired(long sequence, long firstSequence)
    {
        return IsExpired(sequence, firstSequence)
            ? Math.Max(0, firstSequence - 1)
            : sequence;
    }

    private static bool IsExpired(long sequence, long firstSequence)
    {
        return firstSequence > 0 && sequence < firstSequence - 1;
    }

    private static string NormalizeClientId(string clientId)
    {
        return string.IsNullOrWhiteSpace(clientId) ? "anonymous" : clientId.Trim();
    }

    private static bool TryDecode(string cursor, out long sequence)
    {
        sequence = 0;
        if (string.IsNullOrWhiteSpace(cursor))
        {
            return false;
        }

        try
        {
            var padded = cursor.Replace('-', '+').Replace('_', '/');
            padded = padded.PadRight(padded.Length + ((4 - padded.Length % 4) % 4), '=');
            var text = Encoding.UTF8.GetString(Convert.FromBase64String(padded));
            return text.StartsWith("seq:", StringComparison.OrdinalIgnoreCase) &&
                   long.TryParse(text[4..], out sequence);
        }
        catch
        {
            return false;
        }
    }

    public readonly record struct CursorResult(long Sequence, bool Expired);

    private readonly record struct Entry(long Sequence, DateTimeOffset LastSeen);
}
