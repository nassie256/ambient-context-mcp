using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using AmbientContextMcp.Core.Models;

namespace AmbientContextMcp.AmbientContext;

public static class WindowsForegroundAppCollector
{
    public static ForegroundAppContext GetForegroundApp()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero)
        {
            return new ForegroundAppContext();
        }

        _ = GetWindowThreadProcessId(hwnd, out var processId);
        var processName = GetProcessName(processId);
        var executableName = string.IsNullOrWhiteSpace(processName) ? "" : processName + ".exe";
        var app = AmbientTier1Rules.ClassifyApp(executableName);
        var title = GetWindowTitle(hwnd);

        return new ForegroundAppContext
        {
            ProcessId = processId == 0 ? null : (int)processId,
            ProcessName = executableName,
            AppName = app.AppName,
            Category = app.Category,
            HasWindowTitle = !string.IsNullOrWhiteSpace(title),
            RawWindowTitle = title,
            TitleSummary = AmbientTier1Rules.SummarizeWindowTitle(app.Category, title)
        };
    }

    private static string GetProcessName(uint processId)
    {
        if (processId == 0)
        {
            return "";
        }

        try
        {
            using var process = Process.GetProcessById((int)processId);
            return process.ProcessName;
        }
        catch
        {
            return "";
        }
    }

    private static string GetWindowTitle(IntPtr hwnd)
    {
        var length = GetWindowTextLength(hwnd);
        if (length <= 0)
        {
            return "";
        }

        var builder = new StringBuilder(Math.Min(length + 1, 1024));
        _ = GetWindowText(hwnd, builder, builder.Capacity);
        return builder.ToString();
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int GetWindowTextLength(IntPtr hWnd);
}
