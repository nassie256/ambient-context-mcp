using System.Runtime.InteropServices;
using AmbientContextMcp.Core.Models;

namespace AmbientContextMcp.Win32;

/// <summary>
/// Enumerates connected displays via EnumDisplayMonitors / GetMonitorInfo.
/// Replaces System.Windows.Forms.Screen.AllScreens so the collection layer
/// does not depend on WinForms.
/// </summary>
public static class DisplayEnumerator
{
    private const int MonitorinfofPrimary = 0x00000001;
    private const int CCHDeviceName = 32;
    private const int BitsPerPixelDefault = 32;

    public static IReadOnlyList<DisplayContext> GetAll()
    {
        var displays = new List<DisplayContext>();
        bool Callback(IntPtr hMonitor, IntPtr hdcMonitor, ref Rect lprcMonitor, IntPtr dwData)
        {
            var info = new MonitorInfoEx
            {
                cbSize = (uint)Marshal.SizeOf<MonitorInfoEx>()
            };

            if (!GetMonitorInfo(hMonitor, ref info))
            {
                return true;
            }

            displays.Add(new DisplayContext
            {
                DeviceName = info.szDevice ?? "",
                Primary = (info.dwFlags & MonitorinfofPrimary) == MonitorinfofPrimary,
                Left = info.rcMonitor.Left,
                Top = info.rcMonitor.Top,
                Width = info.rcMonitor.Right - info.rcMonitor.Left,
                Height = info.rcMonitor.Bottom - info.rcMonitor.Top,
                WorkAreaLeft = info.rcWork.Left,
                WorkAreaTop = info.rcWork.Top,
                WorkAreaWidth = info.rcWork.Right - info.rcWork.Left,
                WorkAreaHeight = info.rcWork.Bottom - info.rcWork.Top,
                BitsPerPixel = BitsPerPixelDefault
            });
            return true;
        }

        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, Callback, IntPtr.Zero);
        return displays;
    }

    private delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdcMonitor, ref Rect lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumProc lpfnEnum, IntPtr dwData);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr hMonitor, ref MonitorInfoEx lpmi);

    [StructLayout(LayoutKind.Sequential)]
    private struct Rect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct MonitorInfoEx
    {
        public uint cbSize;
        public Rect rcMonitor;
        public Rect rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = CCHDeviceName)]
        public string szDevice;
    }
}
