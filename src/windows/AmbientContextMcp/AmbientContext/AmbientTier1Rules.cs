using System.IO;
using System.Text.RegularExpressions;

namespace AmbientContextMcp.AmbientContext;

public static class AmbientTier1Rules
{
    public static readonly int[] BatteryPercentThresholds = [80, 50, 30, 20];

    private static readonly IReadOnlyDictionary<string, (string Category, string AppName)> AppClassifications =
        new Dictionary<string, (string Category, string AppName)>(StringComparer.OrdinalIgnoreCase)
        {
            ["code.exe"] = ("editor", "Visual Studio Code"),
            ["cursor.exe"] = ("editor", "Cursor"),
            ["devenv.exe"] = ("editor", "Visual Studio"),
            ["idea64.exe"] = ("editor", "IntelliJ IDEA"),
            ["rider64.exe"] = ("editor", "Rider"),
            ["pycharm64.exe"] = ("editor", "PyCharm"),
            ["webstorm64.exe"] = ("editor", "WebStorm"),
            ["chrome.exe"] = ("browser", "Chrome"),
            ["msedge.exe"] = ("browser", "Edge"),
            ["firefox.exe"] = ("browser", "Firefox"),
            ["vivaldi.exe"] = ("browser", "Vivaldi"),
            ["brave.exe"] = ("browser", "Brave"),
            ["slack.exe"] = ("communication", "Slack"),
            ["discord.exe"] = ("communication", "Discord"),
            ["teams.exe"] = ("communication", "Teams"),
            ["ms-teams.exe"] = ("communication", "Teams"),
            ["spotify.exe"] = ("media", "Spotify"),
            ["vlc.exe"] = ("media", "VLC"),
            ["wmplayer.exe"] = ("media", "Windows Media Player"),
            ["windowsterminal.exe"] = ("terminal", "Windows Terminal"),
            ["powershell.exe"] = ("terminal", "PowerShell"),
            ["pwsh.exe"] = ("terminal", "PowerShell"),
            ["cmd.exe"] = ("terminal", "Command Prompt"),
            ["winword.exe"] = ("document", "Word"),
            ["excel.exe"] = ("document", "Excel"),
            ["powerpnt.exe"] = ("document", "PowerPoint"),
            ["explorer.exe"] = ("shell", "File Explorer")
        };

    private static readonly string[] KnownBrowserSites =
    [
        "GitHub",
        "Gmail",
        "Google",
        "YouTube",
        "Slack",
        "Notion",
        "Microsoft Learn",
        "ChatGPT",
        "Supabase"
    ];

    public static string GetPresenceBucket(int? idleSeconds)
    {
        return idleSeconds switch
        {
            null => "unknown",
            < 10 => "active",
            < 120 => "idle",
            < 600 => "away_short",
            _ => "away_long"
        };
    }

    public static string GetBatteryBucket(int? percent, bool? charging)
    {
        if (percent is null)
        {
            return "unknown";
        }

        if (charging == true)
        {
            return "charging";
        }

        return percent switch
        {
            < 10 => "critical",
            < 20 => "low",
            < 50 => "medium",
            _ => "ok"
        };
    }

    public static string GetCpuPressureBucket(int? usagePercent)
    {
        return usagePercent switch
        {
            null => "unknown",
            >= 90 => "critical",
            >= 75 => "high",
            >= 50 => "moderate",
            _ => "low"
        };
    }

    public static string GetMemoryPressureBucket(int? usedPercent)
    {
        return usedPercent switch
        {
            null => "unknown",
            >= 95 => "critical",
            >= 85 => "high",
            >= 70 => "moderate",
            _ => "low"
        };
    }

    public static (string Category, string AppName) ClassifyApp(string executableName)
    {
        if (string.IsNullOrWhiteSpace(executableName))
        {
            return ("unknown", "unknown");
        }

        return AppClassifications.TryGetValue(executableName, out var app)
            ? app
            : ("other", Path.GetFileNameWithoutExtension(executableName));
    }

    public static IReadOnlyDictionary<string, string> SummarizeWindowTitle(string category, string title)
    {
        var summary = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrWhiteSpace(title))
        {
            return summary;
        }

        summary["has_title"] = "true";

        var extension = ExtractLikelyExtension(title);
        if (!string.IsNullOrWhiteSpace(extension))
        {
            var key = category switch
            {
                "editor" => "file_ext",
                "document" => "document_ext",
                _ => "title_ext"
            };
            summary[key] = extension;
        }

        if (category == "browser")
        {
            foreach (var knownSite in KnownBrowserSites)
            {
                if (title.Contains(knownSite, StringComparison.OrdinalIgnoreCase))
                {
                    summary["known_site"] = knownSite;
                    break;
                }
            }
        }
        else if (category == "terminal")
        {
            if (title.Contains("PowerShell", StringComparison.OrdinalIgnoreCase) ||
                title.Contains("pwsh", StringComparison.OrdinalIgnoreCase))
            {
                summary["shell"] = "powershell";
            }
            else if (title.Contains("cmd", StringComparison.OrdinalIgnoreCase))
            {
                summary["shell"] = "cmd";
            }
            else if (title.Contains("wsl", StringComparison.OrdinalIgnoreCase) ||
                     title.Contains("ubuntu", StringComparison.OrdinalIgnoreCase))
            {
                summary["shell"] = "wsl";
            }
        }

        return summary;
    }

    private static string ExtractLikelyExtension(string title)
    {
        var match = Regex.Match(
            title,
            @"\.([A-Za-z0-9]{1,8})(?:\s|$|\-|\x2014|\|)",
            RegexOptions.CultureInvariant);

        return match.Success ? match.Groups[1].Value.ToLowerInvariant() : "";
    }
}
