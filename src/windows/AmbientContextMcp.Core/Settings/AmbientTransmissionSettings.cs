namespace AmbientContextMcp.Core.Settings;

public sealed class AmbientTransmissionSettings
{
    public int SchemaVersion { get; init; } = 1;

    public Dictionary<string, bool> PathTransmitOverrides { get; init; } =
        new(StringComparer.OrdinalIgnoreCase);
}
