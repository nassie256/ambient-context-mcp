using System.Runtime.InteropServices;
using AmbientContextMcp.Core.Models;

namespace AmbientContextMcp.AmbientContext;

public static class WindowsBatteryContextCollector
{
    public static BatteryContext GetBattery()
    {
        if (!GetSystemPowerStatus(out var status))
        {
            return new BatteryContext();
        }

        var percent = status.BatteryLifePercent == 255 ? null : (int?)status.BatteryLifePercent;
        var onAcPower = status.AcLineStatus switch
        {
            0 => false,
            1 => true,
            _ => (bool?)null
        };
        var charging = status.BatteryFlag == 255
            ? null
            : (bool?)((status.BatteryFlag & 0x08) == 0x08);

        return new BatteryContext
        {
            Present = percent is not null || status.BatteryFlag != 128,
            Percent = percent,
            OnAcPower = onAcPower,
            Charging = charging,
            BatterySaver = status.SystemStatusFlag == 1,
            Bucket = AmbientTier1Rules.GetBatteryBucket(percent, charging)
        };
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetSystemPowerStatus(out SystemPowerStatus lpSystemPowerStatus);

    [StructLayout(LayoutKind.Sequential)]
    private struct SystemPowerStatus
    {
        public byte AcLineStatus;

        public byte BatteryFlag;

        public byte BatteryLifePercent;

        public byte SystemStatusFlag;

        public int BatteryLifeTime;

        public int BatteryFullLifeTime;
    }
}
