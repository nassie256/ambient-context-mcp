using System.Text;
using AmbientContextMcp.Core.Models;
using AmbientContextMcp.Core.Settings;

namespace AmbientContextMcp.Core.Hub;

public sealed class LocalContextHub
{
    private const int DefaultMaxEventAgeHours = 24;
    private const int DefaultMaxEventCount = 500;
    private const int MinMaxEventAgeHours = 1;
    private const int MaxMaxEventAgeHours = 168;
    private const int MinMaxEventCount = 100;
    private const int MaxMaxEventCount = 5000;
    private const int DefaultPollLimit = 50;
    private const int MaxPollLimit = 100;

    private readonly object _lock = new();
    private readonly List<LocalContextEvent> _events = [];
    private readonly HashSet<string> _eventFingerprints = new(StringComparer.Ordinal);
    private readonly Dictionary<string, long> _clientPositions = new(StringComparer.OrdinalIgnoreCase);
    private readonly ISettingsStore _settingsStore;

    private IReadOnlyList<AmbientState> _latestStates = [];
    private IReadOnlyList<PrivacyClassification> _privacyClassifications = [];
    private AmbientTransmissionPolicySnapshot _transmissionPolicy = new();
    private DateTimeOffset _latestObservedAt;
    private int _observedStateCount;
    private int _outboundStateCount;
    private int _internalEventHistoryCount;
    private int _outboundEventCandidateCount;
    private int _maxEventAgeHours = DefaultMaxEventAgeHours;
    private int _maxEventCount = DefaultMaxEventCount;
    private long _nextSequence;

    public event EventHandler<LocalContextEvent>? EventPublished;

    public LocalContextHub(ISettingsStore settingsStore)
    {
        _settingsStore = settingsStore ?? throw new ArgumentNullException(nameof(settingsStore));
        ReloadSettings();
    }

    public void Ingest(AmbientContextSnapshot snapshot)
    {
        List<LocalContextEvent> publishedEvents = [];
        lock (_lock)
        {
            _latestObservedAt = snapshot.ObservedAt;
            _latestStates = snapshot.OutboundStates.ToList();
            _privacyClassifications = snapshot.PrivacyClassifications.ToList();
            _transmissionPolicy = snapshot.TransmissionPolicy;
            _observedStateCount = snapshot.States.Count;
            _outboundStateCount = snapshot.OutboundStates.Count;
            _internalEventHistoryCount = snapshot.Events.Count;
            _outboundEventCandidateCount = snapshot.OutboundEvents.Count;

            foreach (var outboundEvent in snapshot.OutboundEvents)
            {
                var fingerprint = GetFingerprint(outboundEvent);
                if (!_eventFingerprints.Add(fingerprint))
                {
                    continue;
                }

                var sequence = ++_nextSequence;
                var localEvent = new LocalContextEvent
                {
                    Id = CreateEventId(outboundEvent.ObservedAt, sequence),
                    Sequence = sequence,
                    ObservedAt = outboundEvent.ObservedAt,
                    Name = outboundEvent.Name,
                    Value = outboundEvent.Value,
                    Payload = outboundEvent.Payload,
                    Sensitivity = outboundEvent.Sensitivity
                };
                _events.Add(localEvent);
                publishedEvents.Add(localEvent);
            }

            TrimEvents(DateTimeOffset.Now);
        }

        foreach (var localEvent in publishedEvents)
        {
            EventPublished?.Invoke(this, localEvent);
        }
    }

    public LocalContextStateResponse GetContextStates(LocalContextStateRequest request)
    {
        lock (_lock)
        {
            var states = _latestStates
                .Where(state => IsNameIncluded(state.Name, request.Names))
                .Where(state => IsSensitivityAllowed(state.Sensitivity, request.Scopes))
                .ToList();

            return new LocalContextStateResponse
            {
                ObservedAt = _latestObservedAt,
                States = states
            };
        }
    }

    public LocalContextPollResponse PollEvents(LocalContextPollRequest request)
    {
        lock (_lock)
        {
            TrimEvents(DateTimeOffset.Now);

            var clientId = NormalizeClientId(request.ClientId);
            var cursorResult = ResolveCursor(clientId, request.Cursor);
            var limit = NormalizeLimit(request.Limit);
            var matchingEvents = _events
                .Where(item => item.Sequence > cursorResult.Sequence)
                .Where(item => IsNameIncluded(item.Name, request.Names))
                .Where(item => IsSensitivityAllowed(item.Sensitivity, request.Scopes))
                .Take(limit + 1)
                .ToList();

            var returnedEvents = matchingEvents.Take(limit).ToList();
            var lastSequence = returnedEvents.Count > 0
                ? returnedEvents[^1].Sequence
                : cursorResult.Sequence;
            _clientPositions[clientId] = lastSequence;

            return new LocalContextPollResponse
            {
                Events = returnedEvents,
                NextCursor = EncodeCursor(lastSequence),
                HasMore = matchingEvents.Count > limit,
                CursorExpired = cursorResult.Expired,
                Retention = new LocalContextRetentionInfo
                {
                    MaxAgeHours = _maxEventAgeHours,
                    MaxEvents = _maxEventCount
                }
            };
        }
    }

    public LocalContextPolicyResponse GetPolicy()
    {
        lock (_lock)
        {
            return new LocalContextPolicyResponse
            {
                ObservedAt = _latestObservedAt,
                TransmissionPolicy = _transmissionPolicy,
                PrivacyClassifications = _privacyClassifications.ToList(),
                EffectivePolicies = _privacyClassifications
                    .Select(item => BuildEffectivePolicy(item, _transmissionPolicy))
                    .ToList(),
                ObservedStateCount = _observedStateCount,
                OutboundStateCount = _outboundStateCount,
                InternalEventHistoryCount = _internalEventHistoryCount,
                OutboundEventCandidateCount = _outboundEventCandidateCount,
                RetainedOutboundEventCount = _events.Count,
                Retention = new LocalContextRetentionInfo
                {
                    MaxAgeHours = _maxEventAgeHours,
                    MaxEvents = _maxEventCount
                }
            };
        }
    }

    public void ReloadSettings()
    {
        var settings = _settingsStore.LoadLocalContextSettings();
        lock (_lock)
        {
            _maxEventAgeHours = NormalizeMaxEventAgeHours(settings.MaxEventAgeHours);
            _maxEventCount = NormalizeMaxEventCount(settings.MaxEventCount);
            TrimEvents(DateTimeOffset.Now);
        }
    }

    private CursorResult ResolveCursor(string clientId, string cursor)
    {
        if (TryDecodeCursor(cursor, out var cursorSequence))
        {
            return new CursorResult(ClampExpiredCursor(cursorSequence), IsExpired(cursorSequence));
        }

        if (_clientPositions.TryGetValue(clientId, out var clientSequence))
        {
            return new CursorResult(ClampExpiredCursor(clientSequence), IsExpired(clientSequence));
        }

        var latestSequence = _events.Count == 0 ? 0 : _events[^1].Sequence;
        _clientPositions[clientId] = latestSequence;
        return new CursorResult(latestSequence, false);
    }

    private long ClampExpiredCursor(long sequence)
    {
        if (!IsExpired(sequence))
        {
            return sequence;
        }

        return _events.Count == 0 ? 0 : Math.Max(0, _events[0].Sequence - 1);
    }

    private bool IsExpired(long sequence)
    {
        return _events.Count > 0 && sequence < _events[0].Sequence - 1;
    }

    private void TrimEvents(DateTimeOffset now)
    {
        var cutoff = now - TimeSpan.FromHours(_maxEventAgeHours);
        while (_events.Count > 0 && _events[0].ObservedAt < cutoff)
        {
            _eventFingerprints.Remove(GetFingerprint(_events[0]));
            _events.RemoveAt(0);
        }

        while (_events.Count > _maxEventCount)
        {
            _eventFingerprints.Remove(GetFingerprint(_events[0]));
            _events.RemoveAt(0);
        }
    }

    public static int NormalizeMaxEventAgeHours(int hours)
    {
        if (hours <= 0)
        {
            return DefaultMaxEventAgeHours;
        }

        return Math.Clamp(hours, MinMaxEventAgeHours, MaxMaxEventAgeHours);
    }

    public static int NormalizeMaxEventCount(int count)
    {
        if (count <= 0)
        {
            return DefaultMaxEventCount;
        }

        return Math.Clamp(count, MinMaxEventCount, MaxMaxEventCount);
    }

    private static string NormalizeClientId(string clientId)
    {
        return string.IsNullOrWhiteSpace(clientId) ? "anonymous" : clientId.Trim();
    }

    private static int NormalizeLimit(int limit)
    {
        if (limit <= 0)
        {
            return DefaultPollLimit;
        }

        return Math.Min(limit, MaxPollLimit);
    }

    private static bool IsNameIncluded(string name, IReadOnlyList<string> names)
    {
        return names.Count == 0 || names.Contains(name, StringComparer.OrdinalIgnoreCase);
    }

    private static LocalContextEffectivePolicy BuildEffectivePolicy(
        PrivacyClassification classification,
        AmbientTransmissionPolicySnapshot transmissionPolicy)
    {
        var hasOverride = TryGetOverride(
            classification.Path,
            transmissionPolicy.PathTransmitOverrides,
            out var overridePath,
            out var overrideTransmit);

        return new LocalContextEffectivePolicy
        {
            Path = classification.Path,
            Sensitivity = classification.Sensitivity,
            RequiredScope = "context." + NormalizeSensitivity(classification.Sensitivity) + ":read",
            DefaultTransmit = classification.DefaultTransmit,
            EffectiveTransmit = hasOverride ? overrideTransmit : classification.DefaultTransmit,
            HasOverride = hasOverride,
            OverridePath = overridePath,
            OverrideTransmit = hasOverride ? overrideTransmit : null,
            Reason = classification.Reason
        };
    }

    private static bool TryGetOverride(
        string path,
        IReadOnlyDictionary<string, bool> overrides,
        out string overridePath,
        out bool allowed)
    {
        var current = path;
        while (!string.IsNullOrWhiteSpace(current))
        {
            if (overrides.TryGetValue(current, out allowed))
            {
                overridePath = current;
                return true;
            }

            var lastDot = current.LastIndexOf('.');
            if (lastDot < 0)
            {
                break;
            }

            current = current[..lastDot];
        }

        overridePath = "";
        allowed = false;
        return false;
    }

    private static bool IsSensitivityAllowed(string sensitivity, IReadOnlyList<string> scopes)
    {
        var requestedLevel = GetSensitivityLevel(sensitivity);
        var allowedLevel = scopes switch
        {
            var value when value.Contains("context.high:read", StringComparer.OrdinalIgnoreCase) => 3,
            var value when value.Contains("context.medium:read", StringComparer.OrdinalIgnoreCase) => 2,
            var value when value.Contains("context.low:read", StringComparer.OrdinalIgnoreCase) => 1,
            _ => 1
        };

        return requestedLevel <= allowedLevel;
    }

    private static int GetSensitivityLevel(string sensitivity)
    {
        return NormalizeSensitivity(sensitivity) switch
        {
            "high" => 3,
            "medium" => 2,
            _ => 1
        };
    }

    private static string NormalizeSensitivity(string sensitivity)
    {
        return sensitivity.ToLowerInvariant() switch
        {
            "high" => "high",
            "medium" => "medium",
            _ => "low"
        };
    }

    private static string CreateEventId(DateTimeOffset observedAt, long sequence)
    {
        return $"evt_{observedAt.UtcDateTime:yyyyMMddHHmmssfff}_{sequence:D6}";
    }

    private static string EncodeCursor(long sequence)
    {
        return Convert.ToBase64String(Encoding.UTF8.GetBytes("seq:" + sequence))
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    private static bool TryDecodeCursor(string cursor, out long sequence)
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

    private static string GetFingerprint(AmbientOutboundEvent outboundEvent)
    {
        return string.Join(
            "|",
            outboundEvent.ObservedAt.ToUnixTimeMilliseconds().ToString(System.Globalization.CultureInfo.InvariantCulture),
            outboundEvent.Name,
            outboundEvent.Value,
            GetPayloadFingerprint(outboundEvent.Payload));
    }

    private static string GetFingerprint(LocalContextEvent localEvent)
    {
        return string.Join(
            "|",
            localEvent.ObservedAt.ToUnixTimeMilliseconds().ToString(System.Globalization.CultureInfo.InvariantCulture),
            localEvent.Name,
            localEvent.Value,
            GetPayloadFingerprint(localEvent.Payload));
    }

    private static string GetPayloadFingerprint(IReadOnlyDictionary<string, string> payload)
    {
        return string.Join(
            "&",
            payload
                .OrderBy(item => item.Key, StringComparer.OrdinalIgnoreCase)
                .Select(item => item.Key + "=" + item.Value));
    }

    private readonly record struct CursorResult(long Sequence, bool Expired);
}
