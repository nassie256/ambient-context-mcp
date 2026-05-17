using System.IO;
using System.Text;
using System.Text.Json;

namespace AmbientContextMcp.Core.Hub;

public sealed class LocalContextEventLog
{
    // JSONL は 1 行 1 イベントで grep / tail しやすくするため WriteIndented = false で書き出す。
    private static readonly JsonSerializerOptions JsonlOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };

    private readonly string _path;

    public LocalContextEventLog(string path)
    {
        _path = path;
    }

    public static string ResolvePath(string settingsPath)
    {
        var directory = Path.GetDirectoryName(settingsPath);
        return string.IsNullOrWhiteSpace(directory)
            ? "events.jsonl"
            : Path.Combine(directory, "events.jsonl");
    }

    public IReadOnlyList<LocalContextEvent> Load()
    {
        if (!File.Exists(_path))
        {
            return [];
        }

        var events = new List<LocalContextEvent>();
        try
        {
            using var stream = File.OpenRead(_path);
            using var reader = new StreamReader(stream, Encoding.UTF8);
            string? line;
            while ((line = reader.ReadLine()) is not null)
            {
                if (string.IsNullOrWhiteSpace(line))
                {
                    continue;
                }

                try
                {
                    var loaded = JsonSerializer.Deserialize<LocalContextEvent>(line, JsonlOptions);
                    if (loaded is not null)
                    {
                        events.Add(loaded);
                    }
                }
                catch (JsonException)
                {
                    // 1 行壊れていても続行する。
                }
            }
        }
        catch (IOException)
        {
            return [];
        }
        catch (UnauthorizedAccessException)
        {
            return [];
        }

        return events;
    }

    public void Append(IReadOnlyList<LocalContextEvent> events)
    {
        try
        {
            EnsureDirectory();
            using var stream = new FileStream(_path, FileMode.Append, FileAccess.Write, FileShare.Read);
            using var writer = new StreamWriter(stream, new UTF8Encoding(false));
            foreach (var item in events)
            {
                writer.WriteLine(JsonSerializer.Serialize(item, JsonlOptions));
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    public void Rewrite(IReadOnlyList<LocalContextEvent> events)
    {
        try
        {
            EnsureDirectory();
            var tempPath = _path + ".tmp";
            using (var stream = new FileStream(tempPath, FileMode.Create, FileAccess.Write, FileShare.Read))
            using (var writer = new StreamWriter(stream, new UTF8Encoding(false)))
            {
                foreach (var item in events)
                {
                    writer.WriteLine(JsonSerializer.Serialize(item, JsonlOptions));
                }
            }

            File.Move(tempPath, _path, overwrite: true);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    public void Delete()
    {
        try
        {
            if (File.Exists(_path))
            {
                File.Delete(_path);
            }
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }

    private void EnsureDirectory()
    {
        var directory = Path.GetDirectoryName(_path);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }
    }
}
