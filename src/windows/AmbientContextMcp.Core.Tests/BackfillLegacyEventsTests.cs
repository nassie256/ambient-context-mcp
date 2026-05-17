using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class BackfillLegacyEventsTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _settingsPath;
    private readonly string _eventLogPath;

    public BackfillLegacyEventsTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "ambient-context-mcp-test", Guid.NewGuid().ToString());
        Directory.CreateDirectory(_tempDir);
        _settingsPath = Path.Combine(_tempDir, "settings.json");
        _eventLogPath = Path.Combine(_tempDir, "events.jsonl");
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_tempDir, recursive: true);
        }
        catch
        {
            // テストの後片付けで失敗してもアサーション結果には影響させない
        }
    }

    private static string LegacyEventJsonl(DateTimeOffset observedAt)
    {
        // PayloadSensitivity / MaxFieldSensitivity は旧スキーマでは存在しないので含めない。
        var iso = observedAt.ToString("yyyy-MM-ddTHH:mm:ss.fffzzz");
        return "{\"id\":\"evt_legacy_1\",\"sequence\":1," +
               $"\"observedAt\":\"{iso}\"," +
               "\"name\":\"media_session_changed\",\"value\":\"Imagine\"," +
               "\"payload\":{\"title\":\"Imagine\",\"source_app\":\"Chrome\"}," +
               "\"sensitivity\":\"medium\"}" + Environment.NewLine;
    }

    [Fact]
    public void Ingest_backfills_legacy_events_so_high_payload_keys_are_stripped_at_medium_scope()
    {
        // アップグレード前 (= 旧スキーマ) の events.jsonl を再現する。
        // 24h trim 保持窓に収まる新しいタイムスタンプにしないと LoadPersistedEventLog が落とす。
        var legacyObservedAt = DateTimeOffset.UtcNow.AddMinutes(-30);
        File.WriteAllText(_eventLogPath, LegacyEventJsonl(legacyObservedAt));

        var hub = LocalContextHubTestFactory.CreateWithPersistentLog(_settingsPath);

        // アップグレード後の最初の Ingest。classifications が初めて到着するタイミング。
        hub.Ingest(new AmbientContextSnapshot
        {
            ObservedAt = DateTimeOffset.UtcNow,
            PrivacyClassifications =
            [
                new() { Path = "events.media_session_changed", Sensitivity = "medium", DefaultTransmit = false },
                new() { Path = "events.media_session_changed.title", Sensitivity = "high", DefaultTransmit = false }
            ]
        });

        // medium scope で history query。leak が残っているなら title が混入する。
        var poll = hub.PollEvents(new LocalContextPollRequest
        {
            ClientId = "test",
            Scopes = ["context.medium:read"],
            Since = legacyObservedAt.AddMinutes(-1)
        });

        var ev = Assert.Single(poll.Events);
        Assert.False(ev.Payload.ContainsKey("title"));
        Assert.True(ev.Payload.ContainsKey("source_app"));
        Assert.Equal("medium", ev.MaxFieldSensitivity);
    }

    [Fact]
    public void Backfill_rewrites_events_jsonl_so_leak_does_not_return_after_restart()
    {
        var legacyObservedAt = DateTimeOffset.UtcNow.AddMinutes(-30);
        File.WriteAllText(_eventLogPath, LegacyEventJsonl(legacyObservedAt));

        var hub = LocalContextHubTestFactory.CreateWithPersistentLog(_settingsPath);
        hub.Ingest(new AmbientContextSnapshot
        {
            ObservedAt = DateTimeOffset.UtcNow,
            PrivacyClassifications =
            [
                new() { Path = "events.media_session_changed", Sensitivity = "medium", DefaultTransmit = false },
                new() { Path = "events.media_session_changed.title", Sensitivity = "high", DefaultTransmit = false }
            ]
        });

        var contentAfterBackfill = File.ReadAllText(_eventLogPath);
        Assert.Contains("\"maxFieldSensitivity\":\"high\"", contentAfterBackfill);
        Assert.Contains("\"payloadSensitivity\":", contentAfterBackfill);
    }
}
