using AmbientContextMcp.Core.Models;
using AmbientContextMcp.Core.Policy;
using AmbientContextMcp.Core.Settings;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class ForegroundTitleTransmissionPolicyTests
{
    [Fact]
    public void FilterEvents_strips_high_payload_until_raw_title_opt_in()
    {
        var store = new TestSettingsStore(new AmbientTransmissionSettings
        {
            SchemaVersion = 1,
            PathTransmitOverrides = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase)
            {
                ["events.foreground_title_changed"] = true,
                ["events.foreground_title_changed.titleSummary"] = true
            }
        });
        var policy = AmbientTransmissionPolicy.Load(store, AmbientContextCatalog.GetPrivacyClassifications());

        var filtered = policy.FilterEvents(
        [
            new AmbientOutboundEvent
            {
                ObservedAt = DateTimeOffset.Parse("2026-05-23T12:00:00+09:00"),
                Name = "foreground_title_changed",
                Value = "true",
                Sensitivity = "medium",
                Payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                {
                    ["process_name"] = "Code.exe",
                    ["titleSummary.file_ext"] = "cs",
                    ["raw_window_title"] = "Program.cs - demo"
                }
            }
        ],
        AmbientContextCatalog.GetPrivacyClassifications());

        var payload = Assert.Single(filtered).Payload;
        Assert.Equal("Code.exe", payload["process_name"]);
        Assert.Equal("cs", payload["titleSummary.file_ext"]);
        Assert.False(payload.ContainsKey("raw_window_title"));
    }

    private sealed class TestSettingsStore(AmbientTransmissionSettings settings) : ISettingsStore
    {
        public string SettingsPath { get; } = Path.Combine(Path.GetTempPath(), "ambient-context-mcp-test", Guid.NewGuid() + ".json");

        public AmbientTransmissionSettings LoadAmbientTransmissionSettings() => settings;

        public void SaveAmbientTransmissionSettings(AmbientTransmissionSettings value) { }

        public LocalContextSettings LoadLocalContextSettings() => new();

        public void SaveLocalContextSettings(LocalContextSettings value) { }

        public McpServerSettings LoadMcpServerSettings() => new();

        public void SaveMcpServerSettings(McpServerSettings value) { }

        public SettingsWindowStatus? LoadSettingsWindowStatus() => null;

        public void SaveSettingsWindowStatus(SettingsWindowStatus status) { }

        public UiSettings LoadUiSettings() => new();

        public void SaveUiSettings(UiSettings value) { }

        public TransientStateSettings LoadTransientStateSettings() => new();

        public void SaveTransientStateSettings(TransientStateSettings value) { }
    }
}
