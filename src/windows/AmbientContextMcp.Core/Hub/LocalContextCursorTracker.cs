using System.Text;

namespace AmbientContextMcp.Core.Hub;

public sealed class LocalContextCursorTracker
{
    private readonly Dictionary<string, long> _clientPositions = new(StringComparer.OrdinalIgnoreCase);

    public CursorResult Resolve(
        string clientId,
        string cursor,
        bool isHistoryQuery,
        long firstSequence,
        long latestSequence)
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
        if (_clientPositions.TryGetValue(normalizedClientId, out var clientSequence))
        {
            return new CursorResult(
                ClampExpired(clientSequence, firstSequence),
                IsExpired(clientSequence, firstSequence));
        }

        _clientPositions[normalizedClientId] = latestSequence;
        return new CursorResult(latestSequence, false);
    }

    public void Advance(string clientId, long sequence)
    {
        _clientPositions[NormalizeClientId(clientId)] = sequence;
    }

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
}
