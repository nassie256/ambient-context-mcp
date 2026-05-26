using System.Diagnostics;
using System.Runtime.InteropServices;

namespace AmbientContextMcp.Bootstrap;

/// <summary>
/// Windows App Runtime (WinAppSDK) を Unpackaged アプリで初期化するラッパー。
/// プロセス起動直後 (Application.Start より前) に <see cref="TryInitialize"/> を呼ぶ。
/// 失敗時は <see cref="ShowMissingRuntimeMessage"/> で Win32 MessageBox を出して
/// 公式 DL ページに誘導し、プロセスは exit 1 する。
/// </summary>
public static class RuntimeBootstrap
{
    private const uint MinMajor = 1;
    private const uint MinMinor = 6;
    private const string DownloadUrl =
        "https://aka.ms/windowsappsdk/1.6/latest/windowsappruntimeinstall-x64.exe";

    public static bool TryInitialize(out string? error)
    {
        try
        {
            Microsoft.Windows.ApplicationModel.DynamicDependency.Bootstrap.Initialize(MinMajor);
            error = null;
            return true;
        }
        catch (Exception ex)
        {
            error = $"Windows App Runtime {MinMajor}.{MinMinor}+ is required. ({ex.GetType().Name}: {ex.Message})";
            return false;
        }
    }

    public static void Shutdown()
    {
        try
        {
            Microsoft.Windows.ApplicationModel.DynamicDependency.Bootstrap.Shutdown();
        }
        catch
        {
            // Bootstrapper 未初期化での Shutdown は無視 (TryInitialize が失敗した直後など)。
        }
    }

    public static void ShowMissingRuntimeMessage(string error)
    {
        const uint MB_OKCANCEL = 0x00000001;
        const uint MB_ICONERROR = 0x00000010;
        const int IDOK = 1;

        var message =
            "Ambient Context MCP requires Windows App Runtime.\n\n" +
            error + "\n\n" +
            "Press OK to open the download page, or Cancel to exit.";

        var result = MessageBoxW(IntPtr.Zero, message, "Ambient Context MCP", MB_OKCANCEL | MB_ICONERROR);
        if (result == IDOK)
        {
            try
            {
                Process.Start(new ProcessStartInfo
                {
                    FileName = DownloadUrl,
                    UseShellExecute = true
                });
            }
            catch
            {
                // ブラウザ起動失敗時は best-effort。ユーザーは README 経由で URL を確認可能。
            }
        }
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int MessageBoxW(IntPtr hWnd, string lpText, string lpCaption, uint uType);
}
