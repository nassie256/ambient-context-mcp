using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
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

    // JSONL は 1 行 1 イベントで grep / tail しやすくするため WriteIndented = false で書き出す。
    // AmbientContextJson.Options は WriteIndented = true なので転用しない。
    private static readonly JsonSerializerOptions JsonlOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };

    private readonly object _lock = new();
    private readonly List<LocalContextEvent> _events = [];
    private readonly HashSet<string> _eventFingerprints = new(StringComparer.Ordinal);
    private readonly Dictionary<string, long> _clientPositions = new(StringComparer.OrdinalIgnoreCase);
    private readonly ISettingsStore _settingsStore;
    private readonly string _eventLogPath;

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
        _eventLogPath = ResolveEventLogPath(_settingsStore.SettingsPath);
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
            _policyVersion = ComputePolicyVersion(
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
                var (payloadSensitivity, maxFieldSensitivity) = ComputePayloadSensitivity(
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
                .Where(state => IsSensitivityAllowed(state.Sensitivity, request.Scopes))
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

            var clientId = NormalizeClientId(request.ClientId);
            var limit = NormalizeLimit(request.Limit);
            var isHistoryQuery = request.Since.HasValue || request.Until.HasValue;
            var cursorResult = ResolveCursor(clientId, request.Cursor, isHistoryQuery);

            var matchingEvents = _events
                .Where(item => item.Sequence > cursorResult.Sequence)
                .Where(item => !request.Since.HasValue || item.ObservedAt >= request.Since.Value)
                .Where(item => !request.Until.HasValue || item.ObservedAt <= request.Until.Value)
                .Where(item => IsNameIncluded(item.Name, request.Names))
                .Select(item => FilterEventForScope(item, request.Scopes))
                .Where(item => item is not null)
                .Select(item => item!)
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
                _clientPositions[clientId] = lastSequence;
            }

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
                },
                PolicyVersion = _policyVersion
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

    private CursorResult ResolveCursor(string clientId, string cursor, bool isHistoryQuery)
    {
        if (TryDecodeCursor(cursor, out var cursorSequence))
        {
            return new CursorResult(ClampExpiredCursor(cursorSequence), IsExpired(cursorSequence));
        }

        if (isHistoryQuery)
        {
            // history query は保持範囲の先頭から開始。クライアント位置は触らない。
            return new CursorResult(_events.Count == 0 ? 0 : Math.Max(0, _events[0].Sequence - 1), false);
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

            var (perKey, max) = ComputePayloadSensitivity(
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

    private static string ResolveEventLogPath(string settingsPath)
    {
        var directory = Path.GetDirectoryName(settingsPath);
        return string.IsNullOrWhiteSpace(directory)
            ? "events.jsonl"
            : Path.Combine(directory, "events.jsonl");
    }

    /// <summary>
    /// 起動時に既存 events.jsonl を読み込んで _events / _eventFingerprints / _nextSequence を再構築する。
    /// 読み込み後、現在の age/count 制限で trim する。ファイル破損や JSON エラーは黙って無視する
    /// (Hub には ILogger が無い設計なので、復元失敗で起動が止まらないことを優先)。
    /// </summary>
    private void LoadPersistedEventLog()
    {
        lock (_lock)
        {
            if (!File.Exists(_eventLogPath))
            {
                return;
            }

            try
            {
                using var stream = File.OpenRead(_eventLogPath);
                using var reader = new StreamReader(stream, Encoding.UTF8);
                string? line;
                while ((line = reader.ReadLine()) is not null)
                {
                    if (string.IsNullOrWhiteSpace(line))
                    {
                        continue;
                    }

                    LocalContextEvent? loaded;
                    try
                    {
                        loaded = JsonSerializer.Deserialize<LocalContextEvent>(line, JsonlOptions);
                    }
                    catch (JsonException)
                    {
                        // 1 行壊れていても続行する。
                        continue;
                    }

                    if (loaded is null)
                    {
                        continue;
                    }

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
            }
            catch (IOException)
            {
                return;
            }
            catch (UnauthorizedAccessException)
            {
                return;
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
        try
        {
            EnsureEventLogDirectoryUnlocked();
            using var stream = new FileStream(
                _eventLogPath,
                FileMode.Append,
                FileAccess.Write,
                FileShare.Read);
            using var writer = new StreamWriter(stream, new UTF8Encoding(false));
            foreach (var item in events)
            {
                writer.WriteLine(JsonSerializer.Serialize(item, JsonlOptions));
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private void RewriteEventLogUnlocked()
    {
        try
        {
            EnsureEventLogDirectoryUnlocked();
            var tempPath = _eventLogPath + ".tmp";
            using (var stream = new FileStream(
                tempPath,
                FileMode.Create,
                FileAccess.Write,
                FileShare.Read))
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
            {
                foreach (var item in _events)
                {
                    writer.WriteLine(JsonSerializer.Serialize(item, JsonlOptions));
                }
            }

            File.Move(tempPath, _eventLogPath, overwrite: true);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private void DeleteEventLogUnlocked()
    {
        try
        {
            if (File.Exists(_eventLogPath))
            {
                File.Delete(_eventLogPath);
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private void EnsureEventLogDirectoryUnlocked()
    {
        var directory = Path.GetDirectoryName(_eventLogPath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
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
        var allowedLevel = GetAllowedLevel(scopes);
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

    private static string LookupPayloadFieldSensitivity(
        string eventName,
        string payloadKey,
        IReadOnlyList<PrivacyClassification> classifications,
        string fallbackSensitivity)
    {
        var keyPath = $"events.{eventName}.{payloadKey}";

        // 1. 完全一致を最優先 (例: events.media_session_changed.title)
        foreach (var item in classifications)
        {
            if (item.Path.Equals(keyPath, StringComparison.OrdinalIgnoreCase))
            {
                return NormalizeSensitivity(item.Sensitivity);
            }
        }

        // 2. 親パスを最長一致で探す (例: events.media_session_changed)
        PrivacyClassification? bestParent = null;
        foreach (var item in classifications)
        {
            if (keyPath.StartsWith(item.Path + ".", StringComparison.OrdinalIgnoreCase) &&
                (bestParent is null || item.Path.Length > bestParent.Path.Length))
            {
                bestParent = item;
            }
        }

        if (bestParent is not null)
        {
            return NormalizeSensitivity(bestParent.Sensitivity);
        }

        // 3. event-level Sensitivity にフォールバック
        return NormalizeSensitivity(fallbackSensitivity);
    }

    private static (IReadOnlyDictionary<string, string> PerKey, string Max) ComputePayloadSensitivity(
        string eventName,
        IReadOnlyDictionary<string, string> payload,
        IReadOnlyList<PrivacyClassification> classifications,
        string eventSensitivity)
    {
        var perKey = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var maxLevel = GetSensitivityLevel(eventSensitivity);

        foreach (var key in payload.Keys)
        {
            var fieldSensitivity = LookupPayloadFieldSensitivity(eventName, key, classifications, eventSensitivity);
            perKey[key] = fieldSensitivity;

            var level = GetSensitivityLevel(fieldSensitivity);
            if (level > maxLevel)
            {
                maxLevel = level;
            }
        }

        return (perKey, LevelToSensitivity(maxLevel));
    }

    private static string LevelToSensitivity(int level)
    {
        return level switch
        {
            3 => "high",
            2 => "medium",
            _ => "low"
        };
    }

    /// <summary>
    /// scope フィルタを per-field 化したもの。
    /// event-level Sensitivity が scope を超えたら null を返す (event ごと落とす)。
    /// それ以外は payload を機微度別に間引いた新しい LocalContextEvent を返す。
    /// PayloadSensitivity が空のとき (旧データ復元) は event-level Sensitivity にフォールバック。
    /// </summary>
    private static LocalContextEvent? FilterEventForScope(
        LocalContextEvent ev,
        IReadOnlyList<string> scopes)
    {
        var allowedLevel = GetAllowedLevel(scopes);

        if (GetSensitivityLevel(ev.Sensitivity) > allowedLevel)
        {
            return null;
        }

        // payload キー単位フィルタが不要なら同一参照を返す (アロケーション抑制)
        if (string.IsNullOrEmpty(ev.MaxFieldSensitivity) ||
            GetSensitivityLevel(ev.MaxFieldSensitivity) <= allowedLevel)
        {
            return ev;
        }

        var filteredPayload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var filteredSensitivity = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var maxLevel = GetSensitivityLevel(ev.Sensitivity);

        foreach (var pair in ev.Payload)
        {
            var fieldSensitivity = ev.PayloadSensitivity.TryGetValue(pair.Key, out var s)
                ? s
                : ev.Sensitivity;
            if (GetSensitivityLevel(fieldSensitivity) > allowedLevel)
            {
                continue;
            }

            filteredPayload[pair.Key] = pair.Value;
            filteredSensitivity[pair.Key] = fieldSensitivity;
            var level = GetSensitivityLevel(fieldSensitivity);
            if (level > maxLevel)
            {
                maxLevel = level;
            }
        }

        return new LocalContextEvent
        {
            Id = ev.Id,
            Sequence = ev.Sequence,
            ObservedAt = ev.ObservedAt,
            Name = ev.Name,
            Value = ev.Value,
            Payload = filteredPayload,
            Sensitivity = ev.Sensitivity,
            PayloadSensitivity = filteredSensitivity,
            MaxFieldSensitivity = LevelToSensitivity(maxLevel)
        };
    }

    private static string ComputePolicyVersion(
        IReadOnlyList<PrivacyClassification> classifications,
        IReadOnlyDictionary<string, bool> overrides)
    {
        var sb = new StringBuilder();

        foreach (var item in classifications.OrderBy(c => c.Path, StringComparer.OrdinalIgnoreCase))
        {
            sb.Append("c|").Append(item.Path).Append('|')
              .Append(NormalizeSensitivity(item.Sensitivity)).Append('|')
              .Append(item.DefaultTransmit ? '1' : '0').Append('\n');
        }

        foreach (var pair in overrides.OrderBy(p => p.Key, StringComparer.OrdinalIgnoreCase))
        {
            sb.Append("o|").Append(pair.Key).Append('|')
              .Append(pair.Value ? '1' : '0').Append('\n');
        }

        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(sb.ToString()));
        // 9 バイト = base64url で 12 文字。衝突確率は実用上ゼロで、人間が見ても読みやすい長さ。
        return Convert.ToBase64String(hash, 0, 9)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    public static string ComputePolicyVersionForTest(
        IReadOnlyList<PrivacyClassification> classifications,
        IReadOnlyDictionary<string, bool> overrides) =>
        ComputePolicyVersion(classifications, overrides);

    private static int GetAllowedLevel(IReadOnlyList<string> scopes)
    {
        if (scopes.Contains("context.high:read", StringComparer.OrdinalIgnoreCase) ||
            scopes.Contains("context.all:read", StringComparer.OrdinalIgnoreCase))
        {
            return 3;
        }

        if (scopes.Contains("context.medium:read", StringComparer.OrdinalIgnoreCase))
        {
            return 2;
        }

        return 1;
    }

    // --- Test-only wrappers (tests live in a sister assembly without InternalsVisibleTo) ---

    public static string LookupPayloadFieldSensitivityForTest(
        string eventName,
        string payloadKey,
        IReadOnlyList<PrivacyClassification> classifications,
        string fallbackSensitivity) =>
        LookupPayloadFieldSensitivity(eventName, payloadKey, classifications, fallbackSensitivity);

    public static (IReadOnlyDictionary<string, string> PerKey, string Max) ComputePayloadSensitivityForTest(
        string eventName,
        IReadOnlyDictionary<string, string> payload,
        IReadOnlyList<PrivacyClassification> classifications,
        string eventSensitivity) =>
        ComputePayloadSensitivity(eventName, payload, classifications, eventSensitivity);

    public static LocalContextEvent? FilterEventForScopeForTest(
        LocalContextEvent ev,
        IReadOnlyList<string> scopes) =>
        FilterEventForScope(ev, scopes);

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
