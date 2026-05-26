using Microsoft.Win32;

namespace AmbientContextMcp.Autostart;

/// <summary>
/// Reads and writes the per-user "Run" key entry that auto-starts
/// ambient-mcp.exe at Windows logon.
/// </summary>
public sealed class AutostartManager
{
    private const string RunKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "AmbientContextMcp";

    public bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: false);
        return key?.GetValue(ValueName) is string;
    }

    public void Enable(string executablePath)
    {
        if (string.IsNullOrWhiteSpace(executablePath))
        {
            return;
        }

        using var key = Registry.CurrentUser.CreateSubKey(RunKeyPath, writable: true);
        key.SetValue(ValueName, $"\"{executablePath}\"", RegistryValueKind.String);
    }

    public void Disable()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKeyPath, writable: true);
        if (key?.GetValue(ValueName) is not null)
        {
            key.DeleteValue(ValueName, throwOnMissingValue: false);
        }
    }

    public static string GetExecutablePath()
    {
        return Environment.ProcessPath ?? "";
    }
}
