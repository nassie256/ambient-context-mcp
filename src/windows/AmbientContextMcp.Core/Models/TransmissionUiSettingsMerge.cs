namespace AmbientContextMcp.Core.Models;

public static class TransmissionUiSettingsMerge
{
    public static Dictionary<string, bool> MergeOverrides(
        IReadOnlyDictionary<string, bool> existingOverrides,
        IReadOnlyList<TransmissionUiOptionDefinition> options,
        IReadOnlySet<string> enabledOptionIds)
    {
        var overrides = new Dictionary<string, bool>(
            existingOverrides,
            StringComparer.OrdinalIgnoreCase);

        var managedPaths = options
            .SelectMany(option => option.LinkedPaths)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var allowedPaths = options
            .Where(option => enabledOptionIds.Contains(option.Id))
            .SelectMany(option => option.LinkedPaths)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        foreach (var path in managedPaths)
        {
            if (allowedPaths.Contains(path))
            {
                overrides[path] = true;
            }
            else
            {
                overrides.Remove(path);
            }
        }

        return overrides;
    }

    public static bool IsOptionEnabled(
        string primaryPath,
        IReadOnlyDictionary<string, bool> overrides)
    {
        return overrides.TryGetValue(primaryPath, out var allowed) && allowed;
    }

    public static bool IsOptionEnabled(
        TransmissionUiOptionDefinition option,
        IReadOnlyDictionary<string, bool> overrides)
    {
        return IsOptionEnabled(option.PrimaryPath, overrides);
    }
}
