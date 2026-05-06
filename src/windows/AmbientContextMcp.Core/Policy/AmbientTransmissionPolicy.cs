using AmbientContextMcp.Core.Models;
using AmbientContextMcp.Core.Settings;

namespace AmbientContextMcp.Core.Policy;

public sealed class AmbientTransmissionPolicy
{
    private readonly AmbientTransmissionSettings _settings;
    private readonly string _settingsPath;

    private AmbientTransmissionPolicy(AmbientTransmissionSettings settings, string settingsPath)
    {
        _settings = settings;
        _settingsPath = settingsPath;
    }

    public AmbientTransmissionPolicySnapshot Snapshot => new()
    {
        SettingsPath = _settingsPath,
        ExplicitOverrideCount = _settings.PathTransmitOverrides.Count,
        PathTransmitOverrides = new Dictionary<string, bool>(
            _settings.PathTransmitOverrides,
            StringComparer.OrdinalIgnoreCase)
    };

    public static AmbientTransmissionPolicy Load(
        ISettingsStore store,
        IReadOnlyList<PrivacyClassification> privacyClassifications)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(privacyClassifications);

        var raw = store.LoadAmbientTransmissionSettings();
        var cleansed = new AmbientTransmissionSettings
        {
            SchemaVersion = raw.SchemaVersion,
            PathTransmitOverrides = CleanseOverrides(raw.PathTransmitOverrides, privacyClassifications)
        };
        return new AmbientTransmissionPolicy(cleansed, store.SettingsPath);
    }

    public static void Save(
        ISettingsStore store,
        AmbientTransmissionSettings settings,
        IReadOnlyList<PrivacyClassification> privacyClassifications)
    {
        ArgumentNullException.ThrowIfNull(store);
        ArgumentNullException.ThrowIfNull(settings);
        ArgumentNullException.ThrowIfNull(privacyClassifications);

        store.SaveAmbientTransmissionSettings(new AmbientTransmissionSettings
        {
            SchemaVersion = 1,
            PathTransmitOverrides = CleanseOverrides(settings.PathTransmitOverrides, privacyClassifications)
        });
    }

    public IReadOnlyList<AmbientState> FilterStates(
        IReadOnlyList<AmbientState> states,
        IReadOnlyList<PrivacyClassification> privacyClassifications)
    {
        return states
            .Where(state => IsAllowed(state.Name, privacyClassifications))
            .ToList();
    }

    public IReadOnlyList<AmbientOutboundEvent> FilterEvents(
        IReadOnlyList<AmbientOutboundEvent> events,
        IReadOnlyList<PrivacyClassification> privacyClassifications)
    {
        var result = new List<AmbientOutboundEvent>(events.Count);
        foreach (var item in events)
        {
            var eventPath = "events." + item.Name;
            if (!IsAllowed(eventPath, privacyClassifications))
            {
                continue;
            }

            // event 本体が許可されたら、payload キーを 1 つずつフィルタする。
            // 高機微キー (例: events.media_session_changed.title) は親 event を ON にしただけでは流さず、
            // 個別の opt-in を要求する設計。
            var filtered = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var pair in item.Payload)
            {
                var keyPath = $"{eventPath}.{pair.Key}";
                if (IsPayloadKeyAllowed(keyPath, privacyClassifications))
                {
                    filtered[pair.Key] = pair.Value;
                }
            }

            result.Add(new AmbientOutboundEvent
            {
                ObservedAt = item.ObservedAt,
                Name = item.Name,
                Value = item.Value,
                Payload = filtered,
                Sensitivity = item.Sensitivity
            });
        }

        return result;
    }

    private bool IsAllowed(string path, IReadOnlyList<PrivacyClassification> privacyClassifications)
    {
        if (TryGetOverride(path, out var allowed))
        {
            return allowed;
        }

        var classification = FindClassification(path, privacyClassifications);
        return classification?.DefaultTransmit ?? false;
    }

    /// <summary>
    /// payload キーの送信可否を判定する。
    /// 1. 自身に明示 override があれば最優先 (親 event の override を継承させない)。
    /// 2. 自身に明示 classification があれば DefaultTransmit を採用する。
    ///    高機微 payload (例: events.media_session_changed.title) はここで弾かれる。
    /// 3. それ以外は親 event の許可状態を継承する。
    ///    source_app / playback_status のような平常 payload キーは event を ON にしただけで流れる。
    /// </summary>
    private bool IsPayloadKeyAllowed(
        string path,
        IReadOnlyList<PrivacyClassification> privacyClassifications)
    {
        if (_settings.PathTransmitOverrides.TryGetValue(path, out var explicitOverride))
        {
            return explicitOverride;
        }

        var explicitClass = privacyClassifications.FirstOrDefault(c =>
            c.Path.Equals(path, StringComparison.OrdinalIgnoreCase));
        if (explicitClass is not null)
        {
            return explicitClass.DefaultTransmit;
        }

        var lastDot = path.LastIndexOf('.');
        if (lastDot < 0)
        {
            return false;
        }

        return IsAllowed(path[..lastDot], privacyClassifications);
    }

    private bool TryGetOverride(string path, out bool allowed)
    {
        var current = path;
        while (!string.IsNullOrWhiteSpace(current))
        {
            if (_settings.PathTransmitOverrides.TryGetValue(current, out allowed))
            {
                return true;
            }

            var lastDot = current.LastIndexOf('.');
            if (lastDot < 0)
            {
                break;
            }

            current = current[..lastDot];
        }

        allowed = false;
        return false;
    }

    private static PrivacyClassification? FindClassification(
        string path,
        IReadOnlyList<PrivacyClassification> privacyClassifications)
    {
        return privacyClassifications
            .OrderByDescending(item => item.Path.Length)
            .FirstOrDefault(item =>
                path.Equals(item.Path, StringComparison.OrdinalIgnoreCase) ||
                path.StartsWith(item.Path + ".", StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>
    /// 既知の <see cref="PrivacyClassification"/> path に一致しない override を捨てる。
    ///
    /// 例えば <c>"events"</c> のような親キー一括許可を弾く目的。<see cref="TryGetOverride"/> は
    /// 親方向に階層遡上して一致を返すため、もし <c>"events"</c> = true が紛れ込むと
    /// 全イベントが暗黙的に許可されてしまう。Save / Load 双方でこの cleanse を通すことで、
    /// hand-edit / 旧スキーマからのアップグレードでも不正 override が永続化されない。
    /// </summary>
    internal static Dictionary<string, bool> CleanseOverrides(
        IReadOnlyDictionary<string, bool> overrides,
        IReadOnlyList<PrivacyClassification> privacyClassifications)
    {
        var validPaths = privacyClassifications
            .Select(item => item.Path)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        var result = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        foreach (var pair in overrides)
        {
            if (validPaths.Contains(pair.Key))
            {
                result[pair.Key] = pair.Value;
            }
        }

        return result;
    }
}
