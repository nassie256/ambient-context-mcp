using System.IO;
using System.Text;
using System.Text.Json;

namespace AmbientContextMcp.Core.Diagnostics;

/// <summary>
/// Append-only JSONL diagnostic log for tray/UI/capture troubleshooting.
/// Release WinExe builds have no console; this file is the primary audit trail.
/// Rotates when the file exceeds <see cref="MaxFileBytes"/> (keeps one .old backup).
/// </summary>
public static class AppDiagnosticLog
{
    private const long MaxFileBytes = 5 * 1024 * 1024;

    private static readonly JsonSerializerOptions JsonlOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = false
    };

    private static readonly object Lock = new();
    private static string? _path;

    public static void Configure(string settingsPath)
    {
        var directory = Path.GetDirectoryName(settingsPath);
        _path = string.IsNullOrWhiteSpace(directory)
            ? "app-diagnostics.jsonl"
            : Path.Combine(directory, "app-diagnostics.jsonl");
    }

    public static string? LogPath => _path;

    public static void Log(
        string category,
        string eventName,
        IReadOnlyDictionary<string, object?>? detail = null)
    {
        if (string.IsNullOrWhiteSpace(_path))
        {
            return;
        }

        var entry = new Dictionary<string, object?>(StringComparer.Ordinal)
        {
            ["observedAt"] = DateTimeOffset.Now,
            ["category"] = category,
            ["event"] = eventName,
            ["threadId"] = Environment.CurrentManagedThreadId,
            ["threadName"] = Thread.CurrentThread.Name ?? ""
        };

        if (detail is not null && detail.Count > 0)
        {
            entry["detail"] = detail;
        }

        AppendLine(JsonSerializer.Serialize(entry, JsonlOptions));
    }

    public static void LogException(
        string category,
        string eventName,
        Exception exception,
        IReadOnlyDictionary<string, object?>? detail = null)
    {
        var merged = detail is null
            ? new Dictionary<string, object?>(StringComparer.Ordinal)
            : new Dictionary<string, object?>(detail, StringComparer.Ordinal);
        merged["exceptionType"] = exception.GetType().FullName;
        merged["exceptionMessage"] = exception.Message;
        Log(category, eventName, merged);
    }

    private static void AppendLine(string line)
    {
        lock (Lock)
        {
            try
            {
                var directory = Path.GetDirectoryName(_path!);
                if (!string.IsNullOrWhiteSpace(directory))
                {
                    Directory.CreateDirectory(directory);
                }

                RotateIfOversized();

                using var stream = new FileStream(_path!, FileMode.Append, FileAccess.Write, FileShare.Read);
                using var writer = new StreamWriter(stream, new UTF8Encoding(false));
                writer.WriteLine(line);
            }
            catch (IOException)
            {
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    private static void RotateIfOversized()
    {
        if (!File.Exists(_path!))
        {
            return;
        }

        var info = new FileInfo(_path!);
        if (info.Length < MaxFileBytes)
        {
            return;
        }

        var backupPath = _path + ".old";
        if (File.Exists(backupPath))
        {
            File.Delete(backupPath);
        }

        File.Move(_path!, backupPath);
    }
}
