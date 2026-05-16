using AmbientContextMcp.Core.Settings;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class TransientStateSettingsTests : IDisposable
{
    private readonly string _tempDir;
    private readonly string _settingsPath;

    public TransientStateSettingsTests()
    {
        _tempDir = Path.Combine(Path.GetTempPath(), "ambient-context-mcp-test", Guid.NewGuid().ToString());
        Directory.CreateDirectory(_tempDir);
        _settingsPath = Path.Combine(_tempDir, "settings.json");
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

    [Fact]
    public void Save_then_load_round_trips_LastActivityDate()
    {
        var store = new JsonFileSettingsStore(_settingsPath);
        var today = new DateOnly(2026, 5, 17);

        store.SaveTransientStateSettings(new TransientStateSettings { LastActivityDate = today });

        var reopened = new JsonFileSettingsStore(_settingsPath);
        var loaded = reopened.LoadTransientStateSettings();

        Assert.Equal(today, loaded.LastActivityDate);
    }

    [Fact]
    public void Load_returns_default_when_section_absent()
    {
        var store = new JsonFileSettingsStore(_settingsPath);
        // 別セクションだけ保存し、TransientState は触らない
        store.SaveUiSettings(new UiSettings());

        var loaded = store.LoadTransientStateSettings();

        Assert.Null(loaded.LastActivityDate);
    }

    [Fact]
    public void Save_does_not_clobber_other_sections()
    {
        var store = new JsonFileSettingsStore(_settingsPath);
        var customWindow = new SettingsWindowStatus { Left = 123, Top = 456, Width = 789, Height = 321 };
        store.SaveSettingsWindowStatus(customWindow);

        store.SaveTransientStateSettings(new TransientStateSettings { LastActivityDate = new DateOnly(2026, 5, 17) });

        var reopened = new JsonFileSettingsStore(_settingsPath);
        var windowAfter = reopened.LoadSettingsWindowStatus();

        Assert.NotNull(windowAfter);
        Assert.Equal(123, windowAfter!.Left);
        Assert.Equal(456, windowAfter.Top);
    }
}
