using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Settings;

namespace AmbientContextMcp.Core.Tests;

internal static class LocalContextHubTestFactory
{
    public static LocalContextHub CreateInMemory() =>
        new(new InMemorySettingsStore());

    private sealed class InMemorySettingsStore : ISettingsStore
    {
        public string SettingsPath { get; } =
            Path.Combine(Path.GetTempPath(), "ambient-context-mcp-test", Guid.NewGuid() + ".json");

        public AmbientTransmissionSettings LoadAmbientTransmissionSettings() => new();
        public void SaveAmbientTransmissionSettings(AmbientTransmissionSettings settings) { }

        public LocalContextSettings LoadLocalContextSettings() => new();
        public void SaveLocalContextSettings(LocalContextSettings settings) { }

        public McpServerSettings LoadMcpServerSettings() => new();
        public void SaveMcpServerSettings(McpServerSettings settings) { }

        public SettingsWindowStatus? LoadSettingsWindowStatus() => null;
        public void SaveSettingsWindowStatus(SettingsWindowStatus status) { }

        public UiSettings LoadUiSettings() => new();
        public void SaveUiSettings(UiSettings settings) { }
    }
}
