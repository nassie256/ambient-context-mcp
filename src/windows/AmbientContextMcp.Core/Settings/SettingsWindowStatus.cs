namespace AmbientContextMcp.Core.Settings;

public sealed class SettingsWindowStatus
{
    public int SchemaVersion { get; init; } = 1;

    public double Left { get; init; }

    public double Top { get; init; }

    public double Width { get; init; } = 560;

    public double Height { get; init; } = 460;
}
