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
    private const int MaxPollLimit = 1000;

    private readonly object _lock = new();
    private readonly List<LocalContextEvent> _events = [];
    private readonly HashSet<string> _eventFingerprints = new(StringComparer.Ordinal);
    private readonly LocalContextCursorTracker _cursorTracker = new();
    private readonly ISettingsStore _settingsStore;
    private readonly LocalContextEventLog _eventLog;

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
    private bool _persistEventLog;
    private long _nextSequence;
    private string _policyVersion = "";

    public event EventHandler<LocalContextEvent>? EventPublished;

    public LocalContextHub(ISettingsStore settingsStore)
    {
        _settingsStore = settingsStore ?? throw new ArgumentNullException(nameof(settingsStore));
        _eventLog = new LocalContextEventLog(LocalContextEventLog.ResolvePath(_settingsStore.SettingsPath));
        ApplySettings(initialLoad: true);
        if (_persistEventLog)
        {
            LoadPersistedEventLog();
        }
    }

    public void Ingest(AmbientContextSnapshot snapshot)
    {
        List<LocalContextEvent> publishedEvents = [];
        var trimmedAny = false;
        lock (_lock)
        {
            _latestObservedAt = snapshot.ObservedAt;
            _latestStates = snapshot.OutboundStates.ToList();
            _privacyClassifications = snapshot.PrivacyClassifications.ToList();
            _transmissionPolicy = snapshot.TransmissionPolicy;
            _policyVersion = PolicyVersionService.ComputePolicyVersion(
                _privacyClassifications,
                _transmissionPolicy.PathTransmitOverrides);

            // events.jsonl から復元した旧スキーマのイベントは PayloadSensitivity が空のまま
            // _events に乗っているため、scope フィルタが event-level だけにフォールバックして
            // 高機微 payload キーが意図せず流れ続ける。最初に classifications を持つ snapshot が
            // 来たタイミングで一度だけ backfill する (以降は一致するエントリが無く no-op)。
            var backfilled = BackfillLegacyPayloadSensitivity();
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
                var (payloadSensitivity, maxFieldSensitivity) = SensitivityScopeFilter.ComputePayloadSensitivity(
                    outboundEvent.Name,
                    outboundEvent.Payload,
                    _privacyClassifications,
                    outboundEvent.Sensitivity);
                var localEvent = new LocalContextEvent
                {
                    Id = CreateEventId(outboundEvent.ObservedAt, sequence),
                    Sequence = sequence,
                    ObservedAt = outboundEvent.ObservedAt,
                    Name = outboundEvent.Name,
                    Value = outboundEvent.Value,
                    Payload = outboundEvent.Payload,
                    Sensitivity = outboundEvent.Sensitivity,
                    PayloadSensitivity = payloadSensitivity,
                    MaxFieldSensitivity = maxFieldSensitivity
                };
                _events.Add(localEvent);
                publishedEvents.Add(localEvent);
            }

            trimmedAny = TrimEvents(DateTimeOffset.Now);

            if (_persistEventLog)
            {
                if (trimmedAny || backfilled)
                {
                    // 古いイベントが落ちたか、または旧スキーマの backfill が走ったので
                    // JSONL を _events から書き直す (compaction)。
                    // 同一トランザクションの新規イベントもこの 1 回の書き出しに含まれる。
                    RewriteEventLogUnlocked();
                }
                else if (publishedEvents.Count > 0)
                {
                    AppendEventsUnlocked(publishedEvents);
                }
            }
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
                .Where(state => SensitivityScopeFilter.IsSensitivityAllowed(state.Sensitivity, request.Scopes))
                .Select(state => ToLocalContextState(state, request.IncludeMetadata))
                .ToList();

            return new LocalContextStateResponse
            {
                ObservedAt = _latestObservedAt,
                States = states,
                PolicyVersion = _policyVersion
            };
        }
    }

    public LocalContextPollResponse PollEvents(LocalContextPollRequest request)
    {
        lock (_lock)
        {
            TrimEvents(DateTimeOffset.Now);

            var limit = NormalizeLimit(request.Limit);
            var isHistoryQuery = request.Since.HasValue || request.Until.HasValue;
            var cursorResult = _cursorTracker.Resolve(
                request.ClientId,
                request.Cursor,
                isHistoryQuery,
                FirstSequence(),
                LatestSequence());

            var matchingEvents = _events
                .Where(item => item.Sequence > cursorResult.Sequence)
                .Where(item => !request.Since.HasValue || item.ObservedAt >= request.Since.Value)
                .Where(item => !request.Until.HasValue || item.ObservedAt <= request.Until.Value)
                .Where(item => IsNameIncluded(item.Name, request.Names))
                .Select(item => SensitivityScopeFilter.FilterEventForScope(item, request.Scopes))
                .Where(item => item is not null)
                .Select(item => request.IncludePayload ? item! : StripPayload(item!))
                .Take(limit + 1)
                .ToList();

            var returnedEvents = matchingEvents.Take(limit).ToList();
            var lastSequence = returnedEvents.Count > 0
                ? returnedEvents[^1].Sequence
                : cursorResult.Sequence;

            // history query (since/until 指定) は副作用なしの stateless 取得。
            // クライアント位置を進めない (= 同じ範囲で再取得しても結果が消えない)。
            // pagination は呼び出し側が NextCursor を渡すことで行う。
            if (!isHistoryQuery)
            {
                _cursorTracker.Advance(request.ClientId, lastSequence);
            }

            return new LocalContextPollResponse
            {
                Events = returnedEvents,
                NextCursor = LocalContextCursorTracker.Encode(lastSequence),
                HasMore = matchingEvents.Count > limit,
                CursorExpired = cursorResult.Expired,
                Retention = new LocalContextRetentionInfo
                {
                    MaxAgeHours = _maxEventAgeHours,
                    MaxEvents = _maxEventCount
                },
                PolicyVersion = _policyVersion
            };
        }
    }

    public LocalContextEventSchemasResponse GetEventSchemas()
    {
        return new LocalContextEventSchemasResponse
        {
            Events = EventSchemaCatalog.GetAll()
        };
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
        ApplySettings(initialLoad: false);
    }

    /// <summary>
    /// 設定の読み込みと、永続化フラグ遷移に応じたファイル操作を一箇所にまとめる。
    /// initialLoad = true (= コンストラクタからの初回呼び出し) の場合、
    /// 「OFF→ON / ON→OFF 同期」分岐を**意図的にスキップ**する。
    /// 初回時点で _persistEventLog は default false で初期化されているため、
    /// ユーザーが永続化を ON にした保存設定をロードすると false→true に見えてしまうが、
    /// それを「ユーザーが ON に切替えた」と誤認して空の _events をファイルに書き戻すと、
    /// 既存の events.jsonl を消してしまう (これが過去のバグ要因)。
    /// 初回の events.jsonl 復元はコンストラクタ側の <see cref="LoadPersistedEventLog"/> に任せる。
    /// </summary>
    private void ApplySettings(bool initialLoad)
    {
        var settings = _settingsStore.LoadLocalContextSettings();
        lock (_lock)
        {
            var previousPersist = _persistEventLog;
            _maxEventAgeHours = NormalizeMaxEventAgeHours(settings.MaxEventAgeHours);
            _maxEventCount = NormalizeMaxEventCount(settings.MaxEventCount);
            _persistEventLog = settings.PersistEventLog;
            var trimmed = TrimEvents(DateTimeOffset.Now);

            if (initialLoad)
            {
                return;
            }

            if (_persistEventLog)
            {
                if (!previousPersist || trimmed)
                {
                    // OFF → ON: 在席中の opt-in。in-memory の _events をファイルに同期する。
                    // trimmed: 古いイベントが落ちたので compaction する。
                    RewriteEventLogUnlocked();
                }
            }
            else if (previousPersist)
            {
                // ON → OFF: ユーザーが明示的に opt-out したのでファイルを削除する。
                DeleteEventLogUnlocked();
            }
        }
    }

    /// <summary>
    /// 戻り値は「実際にイベントを 1 件以上落としたか」。永続化が ON の場合、
    /// 呼び出し側はこのフラグを見て events.jsonl を rewrite するか判定する。
    /// </summary>
    /// <summary>
    /// PayloadSensitivity / MaxFieldSensitivity が空のままの _events エントリを
    /// 現在の _privacyClassifications から再計算して詰め直す。
    /// アップグレード直後の events.jsonl 復元エントリ (= 旧スキーマ) を新フィルタが正しく
    /// 間引けるようにする目的。返り値は実際に 1 件以上書き換えたかどうか。
    /// </summary>
    private bool BackfillLegacyPayloadSensitivity()
    {
        var backfilled = false;
        for (var i = 0; i < _events.Count; i++)
        {
            var current = _events[i];
            if (!string.IsNullOrEmpty(current.MaxFieldSensitivity))
            {
                continue;
            }

            var (perKey, max) = SensitivityScopeFilter.ComputePayloadSensitivity(
                current.Name,
                current.Payload,
                _privacyClassifications,
                current.Sensitivity);
            _events[i] = new LocalContextEvent
            {
                Id = current.Id,
                Sequence = current.Sequence,
                ObservedAt = current.ObservedAt,
                Name = current.Name,
                Value = current.Value,
                Payload = current.Payload,
                Sensitivity = current.Sensitivity,
                PayloadSensitivity = perKey,
                MaxFieldSensitivity = max
            };
            backfilled = true;
        }

        return backfilled;
    }

    private bool TrimEvents(DateTimeOffset now)
    {
        var trimmed = false;
        var cutoff = now - TimeSpan.FromHours(_maxEventAgeHours);
        while (_events.Count > 0 && _events[0].ObservedAt < cutoff)
        {
            _eventFingerprints.Remove(GetFingerprint(_events[0]));
            _events.RemoveAt(0);
            trimmed = true;
        }

        while (_events.Count > _maxEventCount)
        {
            _eventFingerprints.Remove(GetFingerprint(_events[0]));
            _events.RemoveAt(0);
            trimmed = true;
        }

        return trimmed;
    }

    /// <summary>
    /// 起動時に既存 events.jsonl を読み込んで _events / _eventFingerprints / _nextSequence を再構築する。
    /// 読み込み後、現在の age/count 制限で trim する。
    /// </summary>
    private void LoadPersistedEventLog()
    {
        lock (_lock)
        {
            foreach (var loaded in _eventLog.Load())
            {
                var fingerprint = GetFingerprint(loaded);
                if (!_eventFingerprints.Add(fingerprint))
                {
                    continue;
                }

                _events.Add(loaded);
                if (loaded.Sequence > _nextSequence)
                {
                    _nextSequence = loaded.Sequence;
                }
            }

            _events.Sort((a, b) => a.Sequence.CompareTo(b.Sequence));

            if (TrimEvents(DateTimeOffset.Now))
            {
                RewriteEventLogUnlocked();
            }
        }
    }

    private void AppendEventsUnlocked(IReadOnlyList<LocalContextEvent> events)
    {
        _eventLog.Append(events);
    }

    private void RewriteEventLogUnlocked()
    {
        _eventLog.Rewrite(_events);
    }

    private void DeleteEventLogUnlocked()
    {
        _eventLog.Delete();
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

    private long FirstSequence()
    {
        return _events.Count == 0 ? 0 : _events[0].Sequence;
    }

    private long LatestSequence()
    {
        return _events.Count == 0 ? 0 : _events[^1].Sequence;
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

    private static LocalContextState ToLocalContextState(AmbientState state, bool includeMetadata)
    {
        return new LocalContextState
        {
            ObservedAt = includeMetadata ? state.ObservedAt : null,
            Name = state.Name,
            Value = state.Value,
            Sensitivity = includeMetadata ? state.Sensitivity : null
        };
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
            RequiredScope = "context." + SensitivityScopeFilter.NormalizeSensitivity(classification.Sensitivity) + ":read",
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

    /// <summary>
    /// 要約モードで返すために payload と payloadSensitivity を空にした複製を作る。
    /// id / sequence / observedAt / name / value / sensitivity / maxFieldSensitivity は保持する。
    /// </summary>
    private static LocalContextEvent StripPayload(LocalContextEvent ev)
    {
        return new LocalContextEvent
        {
            Id = ev.Id,
            Sequence = ev.Sequence,
            ObservedAt = ev.ObservedAt,
            Name = ev.Name,
            Value = ev.Value,
            Sensitivity = ev.Sensitivity,
            MaxFieldSensitivity = ev.MaxFieldSensitivity
            // Payload / PayloadSensitivity は init 既定の空 dict のまま
        };
    }

    private static string CreateEventId(DateTimeOffset observedAt, long sequence)
    {
        return $"evt_{observedAt.UtcDateTime:yyyyMMddHHmmssfff}_{sequence:D6}";
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
}
