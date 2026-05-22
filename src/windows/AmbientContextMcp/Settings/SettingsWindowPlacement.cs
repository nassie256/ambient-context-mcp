using System.Windows;
using AmbientContextMcp.Core.Settings;

namespace AmbientContextMcp.Settings;

public static class SettingsWindowPlacement
{
    private const double MinVisibleDip = 32.0;

    public static void Restore(Window window, ISettingsStore settingsStore)
    {
        try
        {
            var status = settingsStore.LoadSettingsWindowStatus();
            if (status is null)
            {
                return;
            }

            window.Width = Math.Max(window.MinWidth, status.Width);
            window.Height = Math.Max(window.MinHeight, status.Height);

            if (IsFinite(status.Left) && IsFinite(status.Top))
            {
                window.WindowStartupLocation = WindowStartupLocation.Manual;
                window.Left = status.Left;
                window.Top = status.Top;
                KeepOnScreen(window);
            }
        }
        catch
        {
            // Ignore invalid placement files.
        }
    }

    /// <summary>
    /// Brings an already-open settings window to the foreground without re-applying saved placement.
    /// </summary>
    public static void EnsureVisible(Window window)
    {
        window.WindowState = WindowState.Normal;
        KeepOnScreen(window);
    }

    public static void Save(Window window, ISettingsStore settingsStore)
    {
        if (window.WindowState == WindowState.Minimized)
        {
            return;
        }

        try
        {
            settingsStore.SaveSettingsWindowStatus(new SettingsWindowStatus
            {
                SchemaVersion = 1,
                Left = window.RestoreBounds.Left,
                Top = window.RestoreBounds.Top,
                Width = window.RestoreBounds.Width,
                Height = window.RestoreBounds.Height
            });
        }
        catch
        {
            // Window placement persistence is best effort.
        }
    }

    private static void KeepOnScreen(Window window)
    {
        var virtualLeft = SystemParameters.VirtualScreenLeft;
        var virtualTop = SystemParameters.VirtualScreenTop;
        var virtualRight = virtualLeft + SystemParameters.VirtualScreenWidth;
        var virtualBottom = virtualTop + SystemParameters.VirtualScreenHeight;

        if (window.Left + window.Width < virtualLeft)
        {
            window.Left = virtualLeft;
        }
        else if (window.Left > virtualRight - MinVisibleDip)
        {
            window.Left = virtualRight - Math.Min(window.Width, SystemParameters.VirtualScreenWidth);
        }

        if (window.Top + window.Height < virtualTop)
        {
            window.Top = virtualTop;
        }
        else if (window.Top > virtualBottom - MinVisibleDip)
        {
            window.Top = virtualBottom - Math.Min(window.Height, SystemParameters.VirtualScreenHeight);
        }
    }

    private static bool IsFinite(double value)
    {
        return !double.IsNaN(value) && !double.IsInfinity(value);
    }
}
