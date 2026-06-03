using System.Runtime.InteropServices;
using AmbientContextMcp.Core.Models;

namespace AmbientContextMcp.AmbientContext;

public sealed class WindowsSystemContextCollector
{
    private ulong? _lastSystemIdleTime;
    private ulong? _lastSystemTotalTime;

    public static SystemContext GetSystem()
    {
        var now = DateTimeOffset.Now;
        return new SystemContext
        {
            TimeZoneId = TimeZoneInfo.Local.Id,
            UtcOffsetMinutes = (int)TimeZoneInfo.Local.GetUtcOffset(now).TotalMinutes,
            UptimeSeconds = Environment.TickCount64 / 1000,
            Is64BitOperatingSystem = Environment.Is64BitOperatingSystem,
            ProcessArchitecture = RuntimeInformation.ProcessArchitecture.ToString()
        };
    }

    public SystemLoadContext GetSystemLoad()
    {
        var cpuUsagePercent = GetCpuUsagePercent();
        var memoryUsedPercent = GetMemoryUsedPercent();

        return new SystemLoadContext
        {
            CpuUsagePercent = cpuUsagePercent,
            CpuPressureBucket = AmbientTier1Rules.GetCpuPressureBucket(cpuUsagePercent),
            MemoryUsedPercent = memoryUsedPercent,
            MemoryPressureBucket = AmbientTier1Rules.GetMemoryPressureBucket(memoryUsedPercent)
        };
    }

    private int? GetCpuUsagePercent()
    {
        if (!GetSystemTimes(out var idle, out var kernel, out var user))
        {
            return null;
        }

        var idleTime = ToUInt64(idle);
        var totalTime = ToUInt64(kernel) + ToUInt64(user);
        if (_lastSystemIdleTime is not ulong lastIdleTime ||
            _lastSystemTotalTime is not ulong lastTotalTime ||
            totalTime <= lastTotalTime ||
            idleTime < lastIdleTime)
        {
            _lastSystemIdleTime = idleTime;
            _lastSystemTotalTime = totalTime;
            return null;
        }

        var idleDelta = idleTime - lastIdleTime;
        var totalDelta = totalTime - lastTotalTime;
        _lastSystemIdleTime = idleTime;
        _lastSystemTotalTime = totalTime;
        if (totalDelta == 0)
        {
            return null;
        }

        var usage = 100.0 * (totalDelta - idleDelta) / totalDelta;
        return (int)Math.Clamp(Math.Round(usage), 0, 100);
    }

    private static int? GetMemoryUsedPercent()
    {
        var status = new MemoryStatusEx
        {
            Length = (uint)Marshal.SizeOf<MemoryStatusEx>()
        };
        return GlobalMemoryStatusEx(ref status)
            ? (int)Math.Clamp(status.MemoryLoad, 0, 100)
            : null;
    }

    private static ulong ToUInt64(FileTime value)
    {
        return ((ulong)value.HighDateTime << 32) | value.LowDateTime;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemTimes(
        out FileTime lpIdleTime,
        out FileTime lpKernelTime,
        out FileTime lpUserTime);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatusEx lpBuffer);

    [StructLayout(LayoutKind.Sequential)]
    private struct FileTime
    {
        public uint LowDateTime;

        public uint HighDateTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatusEx
    {
        public uint Length;

        public uint MemoryLoad;

        public ulong TotalPhys;

        public ulong AvailPhys;

        public ulong TotalPageFile;

        public ulong AvailPageFile;

        public ulong TotalVirtual;

        public ulong AvailVirtual;

        public ulong AvailExtendedVirtual;
    }
}
