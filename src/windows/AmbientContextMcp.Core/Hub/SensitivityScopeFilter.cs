using AmbientContextMcp.Core.Models;

namespace AmbientContextMcp.Core.Hub;

public static class SensitivityScopeFilter
{
    public static bool IsSensitivityAllowed(string sensitivity, IReadOnlyList<string> scopes)
    {
        var requestedLevel = GetSensitivityLevel(sensitivity);
        var allowedLevel = GetAllowedLevel(scopes);
        return requestedLevel <= allowedLevel;
    }

    public static string NormalizeSensitivity(string sensitivity)
    {
        return sensitivity.ToLowerInvariant() switch
        {
            "high" => "high",
            "medium" => "medium",
            _ => "low"
        };
    }

    public static string LookupPayloadFieldSensitivity(
        string eventName,
        string payloadKey,
        IReadOnlyList<PrivacyClassification> classifications,
        string fallbackSensitivity)
    {
        var keyPath = $"events.{eventName}.{payloadKey}";

        foreach (var item in classifications)
        {
            if (item.Path.Equals(keyPath, StringComparison.OrdinalIgnoreCase))
            {
                return NormalizeSensitivity(item.Sensitivity);
            }
        }

        PrivacyClassification? bestParent = null;
        foreach (var item in classifications)
        {
            if (keyPath.StartsWith(item.Path + ".", StringComparison.OrdinalIgnoreCase) &&
                (bestParent is null || item.Path.Length > bestParent.Path.Length))
            {
                bestParent = item;
            }
        }

        return bestParent is not null
            ? NormalizeSensitivity(bestParent.Sensitivity)
            : NormalizeSensitivity(fallbackSensitivity);
    }

    public static (IReadOnlyDictionary<string, string> PerKey, string Max) ComputePayloadSensitivity(
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

    public static LocalContextEvent? FilterEventForScope(
        LocalContextEvent ev,
        IReadOnlyList<string> scopes)
    {
        var allowedLevel = GetAllowedLevel(scopes);

        if (GetSensitivityLevel(ev.Sensitivity) > allowedLevel)
        {
            return null;
        }

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

    private static int GetSensitivityLevel(string sensitivity)
    {
        return NormalizeSensitivity(sensitivity) switch
        {
            "high" => 3,
            "medium" => 2,
            _ => 1
        };
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
}
