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

    public static AmbientTransmissionPolicy Load(ISettingsStore store)
    {
        ArgumentNullException.ThrowIfNull(store);
        return new AmbientTransmissionPolicy(store.LoadAmbientTransmissionSettings(), store.SettingsPath);
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
        return events
            .Where(item => IsAllowed("events." + item.Name, privacyClassifications))
            .ToList();
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
}
