using AmbientContextMcp.Core.Settings;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;
using WinRT.Interop;

namespace AmbientContextMcp.Settings;

public static class SettingsWindowPlacement
{
    private const int DefaultWidth = 600;
    private const int DefaultHeight = 540;

    public static void Apply(Window window, ISettingsStore store)
    {
        var hwnd = WindowNative.GetWindowHandle(window);
        var id = Win32Interop.GetWindowIdFromWindow(hwnd);
        var appWindow = AppWindow.GetFromWindowId(id);

        appWindow.SetIcon("Resources/AppIcon.ico");
        appWindow.Resize(new SizeInt32(DefaultWidth, DefaultHeight));

        var area = DisplayArea.GetFromWindowId(id, DisplayAreaFallback.Primary);
        var workArea = area.WorkArea;
        var x = workArea.X + (workArea.Width - DefaultWidth) / 2;
        var y = workArea.Y + (workArea.Height - DefaultHeight) / 2;
        appWindow.Move(new PointInt32(x, y));

        if (appWindow.Presenter is OverlappedPresenter p)
        {
            p.IsResizable = true;
            p.IsMaximizable = false;
            p.IsMinimizable = false;
        }
    }

    public static void EnsureVisible(Window window)
    {
        var hwnd = WindowNative.GetWindowHandle(window);
        var id = Win32Interop.GetWindowIdFromWindow(hwnd);
        var appWindow = AppWindow.GetFromWindowId(id);
        if (appWindow.Presenter is OverlappedPresenter p && p.State == OverlappedPresenterState.Minimized)
        {
            p.Restore();
        }
        window.Activate();
    }
}
