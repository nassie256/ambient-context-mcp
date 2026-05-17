using System.Security.Cryptography;
using System.Text.Json;
using AmbientContextMcp.Core.Mcp;

namespace AmbientContextMcp.Core.Settings;

public sealed class JsonFileSettingsStore : ISettingsStore
{
    private readonly object _lock = new();
    private readonly string _path;

    public JsonFileSettingsStore(string? path = null)
    {
        _path = path ?? GetDefaultPath();
    }

    public string SettingsPath => _path;

    public AmbientTransmissionSettings LoadAmbientTransmissionSettings()
    {
        return Load().AmbientTransmission ?? new AmbientTransmissionSettings();
    }

    public void SaveAmbientTransmissionSettings(AmbientTransmissionSettings settings)
    {
        Save(current => current.AmbientTransmission = new AmbientTransmissionSettings
        {
            SchemaVersion = 1,
            PathTransmitOverrides = new Dictionary<string, bool>(
                settings.PathTransmitOverrides,
                StringComparer.OrdinalIgnoreCase)
        });
    }

    public LocalContextSettings LoadLocalContextSettings()
    {
        return Load().LocalContext ?? new LocalContextSettings();
    }

    public void SaveLocalContextSettings(LocalContextSettings settings)
    {
        Save(current => current.LocalContext = settings);
    }

    public McpServerSettings LoadMcpServerSettings()
    {
        var settings = Load().McpServer;
        if (settings is not null && !string.IsNullOrWhiteSpace(settings.Token))
        {
            return settings;
        }

        var created = new McpServerSettings
        {
            SchemaVersion = 1,
            AutoStart = settings?.AutoStart ?? false,
            Port = settings?.Port is > 0 and < 65536 ? settings.Port : 37690,
            Token = string.IsNullOrWhiteSpace(settings?.Token) ? CreateToken() : settings!.Token
        };
        SaveMcpServerSettings(created);
        return created;
    }

    public void SaveMcpServerSettings(McpServerSettings settings)
    {
        Save(current => current.McpServer = settings);
    }

    public SettingsWindowStatus? LoadSettingsWindowStatus()
    {
        return Load().SettingsWindow;
    }

    public void SaveSettingsWindowStatus(SettingsWindowStatus status)
    {
        Save(current => current.SettingsWindow = status);
    }

    public UiSettings LoadUiSettings()
    {
        return Load().Ui ?? new UiSettings();
    }

    public void SaveUiSettings(UiSettings settings)
    {
        Save(current => current.Ui = settings);
    }

    public TransientStateSettings LoadTransientStateSettings()
    {
        return Load().TransientState ?? new TransientStateSettings();
    }

    public void SaveTransientStateSettings(TransientStateSettings settings)
    {
        Save(current => current.TransientState = settings);
    }

    public static string GetDefaultPath()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AmbientContextMcp",
            "settings.json");
    }

    private UnifiedSettings Load()
    {
        lock (_lock)
        {
            return LoadUnlocked();
        }
    }

    private void Save(Action<UnifiedSettings> update)
    {
        lock (_lock)
        {
            var settings = LoadUnlocked();
            update(settings);
            settings.SchemaVersion = 1;

            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var tempPath = _path + ".tmp";
            File.WriteAllText(tempPath, JsonSerializer.Serialize(settings, AmbientContextJson.Options));
            File.Move(tempPath, _path, overwrite: true);
        }
    }

    private UnifiedSettings LoadUnlocked()
    {
        if (!File.Exists(_path))
        {
            return new UnifiedSettings();
        }

        try
        {
            return JsonSerializer.Deserialize<UnifiedSettings>(
                File.ReadAllText(_path),
                AmbientContextJson.Options) ?? new UnifiedSettings();
        }
        catch
        {
            return new UnifiedSettings();
        }
    }

    private static string CreateToken()
    {
        Span<byte> bytes = stackalloc byte[32];
        RandomNumberGenerator.Fill(bytes);
        return Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }

    private sealed class UnifiedSettings
    {
        public int SchemaVersion { get; set; } = 1;

        public McpServerSettings? McpServer { get; set; }

        public AmbientTransmissionSettings? AmbientTransmission { get; set; }

        public LocalContextSettings? LocalContext { get; set; }

        public SettingsWindowStatus? SettingsWindow { get; set; }

        public UiSettings? Ui { get; set; }

        public TransientStateSettings? TransientState { get; set; }
    }
}
