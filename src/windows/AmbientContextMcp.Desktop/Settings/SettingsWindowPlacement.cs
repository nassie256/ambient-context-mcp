using AmbientContextMcp.Core.Settings;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Windows.Graphics;
using WinRT.Interop;

namespace AmbientContextMcp.Settings;

public static class SettingsWindowPlacement
{
    private const int DefaultWidth = 720;
    private const int DefaultHeight = 760;
    private const int MinWidth = 480;
    private const int MinHeight = 480;

    public static void Apply(Window window, ISettingsStore store)
    {
        var hwnd = WindowNative.GetWindowHandle(window);
        var id = Win32Interop.GetWindowIdFromWindow(hwnd);
        var appWindow = AppWindow.GetFromWindowId(id);
        appWindow.SetIcon("Resources/AppIcon.ico");

        var status = store.LoadSettingsWindowStatus();
        var hasPos = status is not null && IsFinite(status.Left) && IsFinite(status.Top);

        // 保存位置があればそれを含むディスプレイ、無ければプライマリの作業領域。
        var area = hasPos
            ? DisplayArea.GetFromPoint(new PointInt32((int)status!.Left, (int)status.Top), DisplayAreaFallback.Nearest)
            : DisplayArea.GetFromWindowId(id, DisplayAreaFallback.Primary);
        var workArea = area.WorkArea;

        var width = DefaultWidth;
        var height = DefaultHeight;
        if (status is not null && status.Width > 0 && status.Height > 0)
        {
            width = Math.Clamp((int)Math.Round(status.Width), MinWidth, workArea.Width);
            height = Math.Clamp((int)Math.Round(status.Height), MinHeight, workArea.Height);
        }
        appWindow.Resize(new SizeInt32(width, height));

        int x, y;
        if (hasPos)
        {
            x = (int)Math.Round(status!.Left);
            y = (int)Math.Round(status.Top);
        }
        else
        {
            x = workArea.X + (workArea.Width - width) / 2;
            y = workArea.Y + (workArea.Height - height) / 2;
        }
        // 画面外に出てタイトルバーを掴めなくならないよう作業領域内へ clamp。
        x = Math.Clamp(x, workArea.X, workArea.X + Math.Max(0, workArea.Width - width));
        y = Math.Clamp(y, workArea.Y, workArea.Y + Math.Max(0, workArea.Height - height));
        appWindow.Move(new PointInt32(x, y));

        if (appWindow.Presenter is OverlappedPresenter p)
        {
            p.IsResizable = true;
            p.IsMaximizable = false;
            p.IsMinimizable = false;
        }
    }

    // 閉じる時に現在のサイズ/位置を保存する。AppWindow は物理ピクセル単位。
    public static void Save(Window window, ISettingsStore store)
    {
        try
        {
            var hwnd = WindowNative.GetWindowHandle(window);
            var id = Win32Interop.GetWindowIdFromWindow(hwnd);
            var appWindow = AppWindow.GetFromWindowId(id);
            // 最小化中は復元位置として不適切なので保存しない。
            if (appWindow.Presenter is OverlappedPresenter p && p.State == OverlappedPresenterState.Minimized)
                return;
            var pos = appWindow.Position;
            var size = appWindow.Size;
            if (size.Width <= 0 || size.Height <= 0) return;
            store.SaveSettingsWindowStatus(new SettingsWindowStatus
            {
                Left = pos.X,
                Top = pos.Y,
                Width = size.Width,
                Height = size.Height
            });
        }
        catch
        {
            // 配置永続化は best-effort。失敗してもアプリ動作には影響しない。
        }
    }

    private static bool IsFinite(double v) => !double.IsNaN(v) && !double.IsInfinity(v);

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
