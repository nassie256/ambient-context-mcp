using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Settings;

namespace AmbientContextMcp.Core.Tests;

internal static class LocalContextHubTestFactory
{
    public static LocalContextHub CreateInMemory() =>
        new(new InMemorySettingsStore(persistEventLog: false));

    public static LocalContextHub CreateWithPersistentLog(string settingsPath) =>
        new(new InMemorySettingsStore(persistEventLog: true, overrideSettingsPath: settingsPath));

    private sealed class InMemorySettingsStore : ISettingsStore
    {
        private readonly bool _persistEventLog;

        public InMemorySettingsStore(bool persistEventLog, string? overrideSettingsPath = null)
        {
            _persistEventLog = persistEventLog;
            SettingsPath = overrideSettingsPath ??
                Path.Combine(Path.GetTempPath(), "ambient-context-mcp-test", Guid.NewGuid() + ".json");
        }

        public string SettingsPath { get; }

        public AmbientTransmissionSettings LoadAmbientTransmissionSettings() => new();
        public void SaveAmbientTransmissionSettings(AmbientTransmissionSettings settings) { }

        public LocalContextSettings LoadLocalContextSettings() =>
            new() { PersistEventLog = _persistEventLog };
        public void SaveLocalContextSettings(LocalContextSettings settings) { }

        public McpServerSettings LoadMcpServerSettings() => new();
        public void SaveMcpServerSettings(McpServerSettings settings) { }

        public SettingsWindowStatus? LoadSettingsWindowStatus() => null;
        public void SaveSettingsWindowStatus(SettingsWindowStatus status) { }

        public UiSettings LoadUiSettings() => new();
        public void SaveUiSettings(UiSettings settings) { }
    }
}
