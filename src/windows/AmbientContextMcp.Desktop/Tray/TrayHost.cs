using System.IO;
using System.Runtime.InteropServices;
using AmbientContextMcp.Core.Diagnostics;
using AmbientContextMcp.Mcp;
using AmbientContextMcp.Resources;
using Microsoft.Extensions.Hosting;

namespace AmbientContextMcp.Tray;

/// <summary>
/// Win32 Shell_NotifyIcon を直接 P/Invoke で扱うトレイ実装。H.NotifyIcon.WinUI が
/// Unpackaged WinUI 3 1.8 で動作しなかったため。message-only HWND を 1 つ作って
/// アイコンを登録し、WM_USER+1 でマウスイベントを受信、右クリックは TrackPopupMenu。
/// </summary>
public sealed class TrayHost : IDisposable
{
    private const uint WM_USER = 0x0400;
    private const uint WM_TRAYICON = WM_USER + 1;
    private const uint WM_LBUTTONUP = 0x0202;
    private const uint WM_RBUTTONUP = 0x0205;
    private const uint WM_COMMAND = 0x0111;

    private const uint NIM_ADD = 0x00000000;
    private const uint NIM_MODIFY = 0x00000001;
    private const uint NIM_DELETE = 0x00000002;
    private const uint NIM_SETVERSION = 0x00000004;

    private const uint NIF_MESSAGE = 0x00000001;
    private const uint NIF_ICON = 0x00000002;
    private const uint NIF_TIP = 0x00000004;
    private const uint NIF_STATE = 0x00000008;
    private const uint NIF_INFO = 0x00000010;
    private const uint NIF_SHOWTIP = 0x00000080;

    private const uint NOTIFYICON_VERSION_4 = 4;

    private const uint MF_STRING = 0x00000000;
    private const uint MF_SEPARATOR = 0x00000800;
    private const uint MF_GRAYED = 0x00000001;

    private const uint TPM_RIGHTBUTTON = 0x0002;

    private const int IMAGE_ICON = 1;
    private const uint LR_LOADFROMFILE = 0x00000010;
    private const uint LR_DEFAULTSIZE = 0x00000040;

    private const string WindowClassName = "AmbientContextMcp.TrayHostWindow";

    private readonly McpServerHost _mcpHost;
    private readonly IHostApplicationLifetime _lifetime;
    private readonly Action _openSettings;
    private readonly WndProcDelegate _wndProcDelegate;
    private readonly Dictionary<uint, Action> _menuActions = new();
    private IntPtr _hwnd;
    private IntPtr _hIcon;
    private bool _disposed;
    private bool _paused;

    // Menu command IDs (任意の値で OK、衝突しないように)
    private const uint CmdSettings = 1001;
    private const uint CmdCopyUrl = 1002;
    private const uint CmdCopyToken = 1003;
    private const uint CmdCopySnippet = 1004;
    private const uint CmdPauseResume = 1005;
    private const uint CmdExit = 1006;

    public TrayHost(McpServerHost mcpHost, IHostApplicationLifetime lifetime, Action openSettings)
    {
        _mcpHost = mcpHost;
        _lifetime = lifetime;
        _openSettings = openSettings;
        _wndProcDelegate = WndProc;

        RegisterWindowClass();
        CreateMessageWindow();
        LoadIcon();
        AddTrayIcon();

        _menuActions[CmdSettings] = openSettings;
        _menuActions[CmdCopyUrl] = () => SafeCopy(_mcpHost.McpUrl);
        _menuActions[CmdCopyToken] = () => SafeCopy(_mcpHost.Token);
        _menuActions[CmdCopySnippet] = () =>
            SafeCopy(McpClientSnippets.BuildClaudeCodeSnippet(_mcpHost.McpUrl, _mcpHost.Token));
        _menuActions[CmdPauseResume] = TogglePause;
        _menuActions[CmdExit] = () => _lifetime.StopApplication();

        AppDiagnosticLog.Log("tray", "notify_icon_visible");
    }

    public bool IsPaused => _paused;

    public void RefreshStatus() { /* Status text の動的更新は未使用 (右クリックメニュー表示時に再描画) */ }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;

        try
        {
            var nid = new NOTIFYICONDATAW
            {
                cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATAW>(),
                hWnd = _hwnd,
                uID = 1
            };
            Shell_NotifyIconW(NIM_DELETE, ref nid);
        }
        catch { }

        if (_hIcon != IntPtr.Zero) DestroyIcon(_hIcon);
        if (_hwnd != IntPtr.Zero) DestroyWindow(_hwnd);
    }

    private void RegisterWindowClass()
    {
        var wc = new WNDCLASSW
        {
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_wndProcDelegate),
            lpszClassName = WindowClassName,
            hInstance = GetModuleHandleW(null)
        };
        RegisterClassW(ref wc);
        // 既に登録済みでも RegisterClassW は失敗するだけで CreateWindowExW は通る。
    }

    private void CreateMessageWindow()
    {
        const int HWND_MESSAGE = -3;
        _hwnd = CreateWindowExW(
            0, WindowClassName, "",
            0, 0, 0, 0, 0,
            new IntPtr(HWND_MESSAGE), IntPtr.Zero,
            GetModuleHandleW(null), IntPtr.Zero);
        if (_hwnd == IntPtr.Zero)
            throw new InvalidOperationException("Failed to create tray message window.");
    }

    private void LoadIcon()
    {
        var iconPath = Path.Combine(AppContext.BaseDirectory, "Resources", "AppIcon.ico");
        _hIcon = LoadImageW(IntPtr.Zero, iconPath, IMAGE_ICON, 0, 0, LR_LOADFROMFILE | LR_DEFAULTSIZE);
        if (_hIcon == IntPtr.Zero)
            AppDiagnosticLog.Log("tray", "icon_load_failed", new Dictionary<string, object?> { ["path"] = iconPath });
    }

    private void AddTrayIcon()
    {
        var nid = new NOTIFYICONDATAW
        {
            cbSize = (uint)Marshal.SizeOf<NOTIFYICONDATAW>(),
            hWnd = _hwnd,
            uID = 1,
            uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP,
            uCallbackMessage = WM_TRAYICON,
            hIcon = _hIcon,
            szTip = "Ambient Context MCP"
        };
        if (!Shell_NotifyIconW(NIM_ADD, ref nid))
            AppDiagnosticLog.Log("tray", "shell_notify_add_failed");

        nid.uVersion = NOTIFYICON_VERSION_4;
        Shell_NotifyIconW(NIM_SETVERSION, ref nid);
    }

    private IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WM_TRAYICON)
        {
            // V4 notify: lParam の low word が event message
            var notifyEvent = (uint)(lParam.ToInt64() & 0xFFFF);
            switch (notifyEvent)
            {
                case WM_LBUTTONUP:
                    AppDiagnosticLog.Log("tray", "icon_left_click");
                    _openSettings();
                    return IntPtr.Zero;
                case WM_RBUTTONUP:
                    // v4 通知でも右クリックは標準の WM_RBUTTONUP が lParam 下位に届く
                    // (実使用ログで確認済み)。WM_CONTEXTMENU(0x007B) はキーボード起動だけ
                    // でなく右クリックでも併発し ShowContextMenu が二重発火するため扱わない。
                    // 旧コードの 0x0007 / 0x406 は誤り (0x406 は NIN_POPUPOPEN でホバー時に
                    // 発火しメニューが誤って開く) だったため削除。
                    ShowContextMenu();
                    return IntPtr.Zero;
            }
        }
        else if (msg == WM_COMMAND)
        {
            var cmdId = (uint)(wParam.ToInt64() & 0xFFFF);
            if (_menuActions.TryGetValue(cmdId, out var action))
            {
                AppDiagnosticLog.Log("tray", "menu_click", new Dictionary<string, object?> { ["cmd"] = cmdId });
                action();
            }
            return IntPtr.Zero;
        }
        return DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    private void ShowContextMenu()
    {
        var menu = CreatePopupMenu();
        if (menu == IntPtr.Zero) return;

        try
        {
            var statusText = GetStatusText();
            AppendMenuW(menu, MF_STRING | MF_GRAYED, IntPtr.Zero, statusText);
            AppendMenuW(menu, MF_SEPARATOR, IntPtr.Zero, null);
            AppendMenuW(menu, MF_STRING, new IntPtr(CmdSettings), Strings.TraySettings);
            AppendMenuW(menu, MF_SEPARATOR, IntPtr.Zero, null);
            AppendMenuW(menu, MF_STRING, new IntPtr(CmdCopyUrl), Strings.TrayCopyMcpUrl);
            AppendMenuW(menu, MF_STRING, new IntPtr(CmdCopyToken), Strings.TrayCopyMcpToken);
            AppendMenuW(menu, MF_STRING, new IntPtr(CmdCopySnippet), Strings.TrayCopyClaudeCodeSnippet);
            AppendMenuW(menu, MF_SEPARATOR, IntPtr.Zero, null);
            var pauseLabel = _paused ? Strings.TrayResume : Strings.TrayPause;
            AppendMenuW(menu, MF_STRING, new IntPtr(CmdPauseResume), pauseLabel);
            AppendMenuW(menu, MF_SEPARATOR, IntPtr.Zero, null);
            AppendMenuW(menu, MF_STRING, new IntPtr(CmdExit), Strings.TrayExit);

            GetCursorPos(out var pt);
            // TrackPopupMenu の前に SetForegroundWindow しないとメニュー操作後にメニューが残るバグの workaround
            SetForegroundWindow(_hwnd);
            TrackPopupMenu(menu, TPM_RIGHTBUTTON, pt.x, pt.y, 0, _hwnd, IntPtr.Zero);
            PostMessageW(_hwnd, 0, IntPtr.Zero, IntPtr.Zero);
        }
        finally
        {
            DestroyMenu(menu);
        }
    }

    private string GetStatusText()
    {
        var suffix = _paused ? Strings.TrayPausedSuffix : "";
        return $"Ambient Context MCP — :{_mcpHost.Settings.Port}{suffix}";
    }

    private void TogglePause()
    {
        _paused = !_paused;
        AppDiagnosticLog.Log("tray", "pause_toggle", new Dictionary<string, object?> { ["paused"] = _paused });
    }

    private static void SafeCopy(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        try
        {
            var dp = new Windows.ApplicationModel.DataTransfer.DataPackage();
            dp.SetText(value);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(dp);
        }
        catch
        {
            // best-effort
        }
    }

    // --- P/Invoke ---

    private delegate IntPtr WndProcDelegate(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WNDCLASSW
    {
        public uint style;
        public IntPtr lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)]
        public string lpszClassName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT { public int x; public int y; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode, Pack = 8)]
    private struct NOTIFYICONDATAW
    {
        public uint cbSize;
        public IntPtr hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szInfo;
        public uint uVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClassW(ref WNDCLASSW lpWndClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowExW(uint dwExStyle, string lpClassName, string lpWindowName,
        uint dwStyle, int x, int y, int nWidth, int nHeight, IntPtr hWndParent, IntPtr hMenu,
        IntPtr hInstance, IntPtr lpParam);

    [DllImport("user32.dll")]
    private static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DefWindowProcW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool PostMessageW(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandleW(string? lpModuleName);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr LoadImageW(IntPtr hInst, string name, int type, int cx, int cy, uint fuLoad);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr hIcon);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern bool Shell_NotifyIconW(uint dwMessage, ref NOTIFYICONDATAW lpData);

    [DllImport("user32.dll")]
    private static extern IntPtr CreatePopupMenu();

    [DllImport("user32.dll")]
    private static extern bool DestroyMenu(IntPtr hMenu);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool AppendMenuW(IntPtr hMenu, uint uFlags, IntPtr uIDNewItem, string? lpNewItem);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern int TrackPopupMenu(IntPtr hMenu, uint uFlags, int x, int y, int nReserved, IntPtr hWnd, IntPtr prcRect);
}
