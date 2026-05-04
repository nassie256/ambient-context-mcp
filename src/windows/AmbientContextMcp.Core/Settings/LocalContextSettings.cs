namespace AmbientContextMcp.Core.Settings;

public sealed class LocalContextSettings
{
    public int SchemaVersion { get; init; } = 1;

    public int MaxEventAgeHours { get; init; } = 24;

    public int MaxEventCount { get; init; } = 500;
}
