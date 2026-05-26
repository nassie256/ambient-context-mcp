using System.Collections.Concurrent;
using System.Runtime.InteropServices;

namespace AmbientContextMcp.Win32;

/// <summary>
/// Hosts a hidden HWND_MESSAGE window on a dedicated thread. Clients use
/// the HWND for Win32 notifications (WTSRegisterSessionNotification,
/// RegisterPowerSettingNotification, SetWinEventHook) and post callbacks
/// to run on the window thread so delivered messages arrive on the same
/// thread as the registration.
/// </summary>
public sealed class MessageOnlyWindow : IDisposable
{
    private const int WmClose = 0x0010;
    private const int WmUserDrain = 0x0400; // WM_USER + 0
    private const int CwUseDefault = unchecked((int)0x80000000);
    private const string ClassName = "AmbientContextMcpMessageWindow";
    private static readonly IntPtr HwndMessage = new(-3);

    private readonly Thread _thread;
    private readonly ManualResetEventSlim _ready = new(initialState: false);
    private readonly ConcurrentQueue<Action> _actionQueue = new();
    private readonly WndProcDelegate _wndProc;
    private IntPtr _hwnd;
    private ushort _classAtom;
    private bool _disposed;

    public MessageOnlyWindow()
    {
        _wndProc = WindowProc;
        _thread = new Thread(ThreadMain)
        {
            Name = "AmbientContextMcp.MessageWindow",
            IsBackground = true
        };
        _thread.Start();
        _ready.Wait();
    }

    public IntPtr Hwnd => _hwnd;

    public event EventHandler<WindowMessageEventArgs>? MessageReceived;

    /// <summary>
    /// Schedules an action to run on the window thread.
    /// </summary>
    public void PostCallback(Action action)
    {
        ArgumentNullException.ThrowIfNull(action);
        if (_disposed || _hwnd == IntPtr.Zero)
        {
            return;
        }

        _actionQueue.Enqueue(action);
        PostMessage(_hwnd, WmUserDrain, IntPtr.Zero, IntPtr.Zero);
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        if (_hwnd != IntPtr.Zero)
        {
            PostMessage(_hwnd, WmClose, IntPtr.Zero, IntPtr.Zero);
        }

        _thread.Join(TimeSpan.FromSeconds(5));
        _ready.Dispose();
    }

    private void ThreadMain()
    {
        try
        {
            var moduleHandle = GetModuleHandle(null);
            var wndClass = new WndClassEx
            {
                cbSize = (uint)Marshal.SizeOf<WndClassEx>(),
                lpfnWndProc = _wndProc,
                hInstance = moduleHandle,
                lpszClassName = ClassName
            };

            _classAtom = RegisterClassEx(ref wndClass);
            if (_classAtom == 0)
            {
                _ready.Set();
                return;
            }

            _hwnd = CreateWindowEx(
                0,
                ClassName,
                ClassName,
                0,
                CwUseDefault,
                CwUseDefault,
                CwUseDefault,
                CwUseDefault,
                HwndMessage,
                IntPtr.Zero,
                moduleHandle,
                IntPtr.Zero);

            // Install a SynchronizationContext so async continuations resume on
            // this window thread (mirrors WPF Dispatcher behavior). Required so
            // `_lastXxx` mutations after `await GetMediaAsync()` stay on the
            // single owning thread.
            SynchronizationContext.SetSynchronizationContext(
                new MessageWindowSynchronizationContext(this));

            _ready.Set();

            if (_hwnd == IntPtr.Zero)
            {
                return;
            }

            while (GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0)
            {
                TranslateMessage(ref msg);
                DispatchMessage(ref msg);
            }
        }
        finally
        {
            if (_hwnd != IntPtr.Zero)
            {
                DestroyWindow(_hwnd);
                _hwnd = IntPtr.Zero;
            }

            if (_classAtom != 0)
            {
                UnregisterClass(ClassName, GetModuleHandle(null));
                _classAtom = 0;
            }
        }
    }

    private IntPtr WindowProc(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        if (msg == WmUserDrain)
        {
            while (_actionQueue.TryDequeue(out var action))
            {
                try
                {
                    action();
                }
                catch (Exception ex)
                {
                    // Swallow to keep the message pump alive — but surface to stderr so
                    // we can diagnose silent-action failures via process redirection.
                    try { Console.Error.WriteLine($"[MessageOnlyWindow] action threw: {ex}"); }
                    catch { }
                }
            }

            return IntPtr.Zero;
        }

        if (msg == WmClose)
        {
            PostQuitMessage(0);
            return IntPtr.Zero;
        }

        var args = new WindowMessageEventArgs((int)msg, wParam, lParam);
        MessageReceived?.Invoke(this, args);
        return DefWindowProc(hwnd, msg, wParam, lParam);
    }

    private delegate IntPtr WndProcDelegate(IntPtr hwnd, uint msg, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WndClassEx
    {
        public uint cbSize;
        public uint style;
        public WndProcDelegate lpfnWndProc;
        public int cbClsExtra;
        public int cbWndExtra;
        public IntPtr hInstance;
        public IntPtr hIcon;
        public IntPtr hCursor;
        public IntPtr hbrBackground;
        public string? lpszMenuName;
        public string lpszClassName;
        public IntPtr hIconSm;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Msg
    {
        public IntPtr hwnd;
        public uint message;
        public IntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public POINT pt;
        public uint lPrivate;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct POINT
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern ushort RegisterClassEx(ref WndClassEx lpWndClass);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool UnregisterClass(string lpClassName, IntPtr hInstance);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateWindowEx(
        uint dwExStyle,
        string lpClassName,
        string lpWindowName,
        uint dwStyle,
        int x,
        int y,
        int nWidth,
        int nHeight,
        IntPtr hWndParent,
        IntPtr hMenu,
        IntPtr hInstance,
        IntPtr lpParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetMessage(out Msg lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);

    [DllImport("user32.dll")]
    private static extern bool TranslateMessage(ref Msg lpMsg);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DispatchMessage(ref Msg lpMsg);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr DefWindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    private static extern void PostQuitMessage(int nExitCode);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);
}

public sealed class WindowMessageEventArgs : EventArgs
{
    public WindowMessageEventArgs(int message, IntPtr wParam, IntPtr lParam)
    {
        Message = message;
        WParam = wParam;
        LParam = lParam;
    }

    public int Message { get; }

    public IntPtr WParam { get; }

    public IntPtr LParam { get; }
}
