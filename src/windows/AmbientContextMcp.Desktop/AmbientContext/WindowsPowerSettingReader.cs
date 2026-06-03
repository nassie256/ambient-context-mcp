using System.Globalization;
using System.Runtime.InteropServices;

namespace AmbientContextMcp.AmbientContext;

public static class WindowsPowerSettingReader
{
    private static readonly Guid GuidAcDcPowerSource = new("5D3E9A59-E9D5-4B00-A6BD-FF34FF516548");
    private static readonly Guid GuidBatteryPercentageRemaining = new("A7AD8041-B45A-4CAE-87A3-EECBB468A9E1");
    private static readonly Guid GuidConsoleDisplayState = new("6FE69556-704A-47A0-8F24-C28D936FDA47");
    private static readonly Guid GuidGlobalUserPresence = new("786E8A1D-B427-4344-9207-09E70BDCBEA9");
    private static readonly Guid GuidLidSwitchStateChange = new("BA3E0F4D-B817-4094-A2D1-D56379E6A0F3");
    private static readonly Guid GuidMonitorPowerOn = new("02731015-4510-4526-99E6-E5A17EBD1AEA");
    private static readonly Guid GuidPowerSavingStatus = new("E00958C0-C213-4ACE-AC77-FECCED2EEEA5");
    private static readonly Guid GuidSessionDisplayStatus = new("2B84C20E-AD23-4DDF-93DB-05FFBD7EFCA5");

    public static IReadOnlyList<Guid> NotificationGuids { get; } =
    [
        GuidAcDcPowerSource,
        GuidBatteryPercentageRemaining,
        GuidConsoleDisplayState,
        GuidGlobalUserPresence,
        GuidLidSwitchStateChange,
        GuidMonitorPowerOn,
        GuidPowerSavingStatus,
        GuidSessionDisplayStatus
    ];

    public static PowerSettingEvent Read(IntPtr lParam)
    {
        if (lParam == IntPtr.Zero)
        {
            return new PowerSettingEvent(
                "unknown",
                new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                {
                    ["setting"] = "unknown",
                    ["value"] = "unknown"
                });
        }

        try
        {
            var header = Marshal.PtrToStructure<PowerBroadcastSettingHeader>(lParam);
            var dataOffset = Marshal.SizeOf<PowerBroadcastSettingHeader>();
            var value = header.DataLength >= 4 ? Marshal.ReadInt32(IntPtr.Add(lParam, dataOffset)) : 0;
            var name = GetPowerSettingName(header.PowerSetting);
            return new PowerSettingEvent(
                name,
                new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                {
                    ["setting"] = name,
                    ["guid"] = header.PowerSetting.ToString("D"),
                    ["value"] = FormatPowerSettingValue(header.PowerSetting, value),
                    ["raw_value"] = value.ToString(CultureInfo.InvariantCulture),
                    ["data_length"] = header.DataLength.ToString(CultureInfo.InvariantCulture)
                });
        }
        catch (Exception ex)
        {
            return new PowerSettingEvent(
                "unknown",
                new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                {
                    ["setting"] = "unknown",
                    ["value"] = "unreadable",
                    ["error"] = ex.GetType().Name
                });
        }
    }

    private static string GetPowerSettingName(Guid guid)
    {
        if (guid == GuidAcDcPowerSource)
        {
            return "ac_dc_power_source";
        }

        if (guid == GuidBatteryPercentageRemaining)
        {
            return "battery_percentage_remaining";
        }

        if (guid == GuidConsoleDisplayState)
        {
            return "console_display_state";
        }

        if (guid == GuidGlobalUserPresence)
        {
            return "global_user_presence";
        }

        if (guid == GuidLidSwitchStateChange)
        {
            return "lid_switch_state";
        }

        if (guid == GuidMonitorPowerOn)
        {
            return "monitor_power_on";
        }

        if (guid == GuidPowerSavingStatus)
        {
            return "power_saving_status";
        }

        if (guid == GuidSessionDisplayStatus)
        {
            return "session_display_status";
        }

        return "unknown";
    }

    private static string FormatPowerSettingValue(Guid guid, int value)
    {
        if (guid == GuidAcDcPowerSource)
        {
            return value switch
            {
                0 => "ac",
                1 => "battery",
                2 => "short_term",
                _ => value.ToString(CultureInfo.InvariantCulture)
            };
        }

        if (guid == GuidConsoleDisplayState || guid == GuidSessionDisplayStatus)
        {
            return value switch
            {
                0 => "off",
                1 => "on",
                2 => "dimmed",
                _ => value.ToString(CultureInfo.InvariantCulture)
            };
        }

        if (guid == GuidGlobalUserPresence)
        {
            return value switch
            {
                0 => "present",
                2 => "inactive",
                _ => value.ToString(CultureInfo.InvariantCulture)
            };
        }

        if (guid == GuidLidSwitchStateChange || guid == GuidMonitorPowerOn || guid == GuidPowerSavingStatus)
        {
            return value == 0 ? "off" : "on";
        }

        return value.ToString(CultureInfo.InvariantCulture);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PowerBroadcastSettingHeader
    {
        public Guid PowerSetting;

        public int DataLength;
    }
}

public sealed record PowerSettingEvent(string Name, IReadOnlyDictionary<string, string> Data);
