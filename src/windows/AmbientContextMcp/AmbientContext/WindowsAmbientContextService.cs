using System.Diagnostics;
using System.IO;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;
using AmbientContextMcp.Core.Mcp;
using AmbientContextMcp.Core.Models;
using AmbientContextMcp.Core.Policy;
using AmbientContextMcp.Core.Settings;
using AmbientContextMcp.Win32;
using Microsoft.Extensions.Logging;
using Windows.Media.Control;
using ActivityContext = AmbientContextMcp.Core.Models.ActivityContext;

namespace AmbientContextMcp.AmbientContext;

public sealed partial class WindowsAmbientContextService : IDisposable
{
    private const int MaxRecentEvents = 500;
    private const int SnapshotIntervalSeconds = 60;
    private const int ForegroundCaptureThrottleMilliseconds = 1000;
    private const int ContextSwitchBurstThresholdPerMinute = 12;
    private const int ContextSwitchBurstResetThresholdPerMinute = 8;
    private const int LongSessionWarningMinutes = 90;
    private static readonly TimeSpan RecentEventRetention = TimeSpan.FromHours(24);

    private const int WmWtsSessionChange = 0x02B1;
    private const int WmPowerBroadcast = 0x0218;
    private const int WtsSessionLock = 0x7;
    private const int WtsSessionUnlock = 0x8;
    private const int WtsSessionLogon = 0x5;
    private const int WtsSessionLogoff = 0x6;
    private const int PbtApmSuspend = 0x0004;
    private const int PbtApmResumeSuspend = 0x0007;
    private const int PbtApmResumeAutomatic = 0x0012;
    private const int PbtPowerSettingChange = 0x8013;
    private const int ExpectedInitialPowerSettingCount = 8;
    private const uint NotifyForThisSession = 0;
    private const uint EventSystemForeground = 0x0003;
    private const uint WinEventOutOfContext = 0x0000;
    private const uint WinEventSkipOwnProcess = 0x0002;
    private const int DeviceNotifyWindowHandle = 0;

    private static readonly Guid GuidAcDcPowerSource = new("5D3E9A59-E9D5-4B00-A6BD-FF34FF516548");
    private static readonly Guid GuidBatteryPercentageRemaining = new("A7AD8041-B45A-4CAE-87A3-EECBB468A9E1");
    private static readonly Guid GuidConsoleDisplayState = new("6FE69556-704A-47A0-8F24-C28D936FDA47");
    private static readonly Guid GuidGlobalUserPresence = new("786E8A1D-B427-4344-9207-09E70BDCBEA9");
    private static readonly Guid GuidLidSwitchStateChange = new("BA3E0F4D-B817-4094-A2D1-D56379E6A0F3");
    private static readonly Guid GuidMonitorPowerOn = new("02731015-4510-4526-99E6-E5A17EBD1AEA");
    private static readonly Guid GuidPowerSavingStatus = new("E00958C0-C213-4ACE-AC77-FECCED2EEEA5");
    private static readonly Guid GuidSessionDisplayStatus = new("2B84C20E-AD23-4DDF-93DB-05FFBD7EFCA5");

    private static readonly JsonSerializerOptions JsonOptions = new(AmbientContextJson.Options)
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping
    };

    private readonly MessageOnlyWindow _messageWindow;
    private readonly ISettingsStore _settingsStore;
    private readonly ILogger<WindowsAmbientContextService> _logger;
    private readonly string _snapshotPath;
    private readonly List<AmbientEvent> _recentEvents = [];
    private readonly List<IntPtr> _powerNotificationHandles = [];
    private readonly WinEventProc _foregroundProc;
    private readonly object _eventLock = new();
    private readonly Dictionary<string, string> _lastPowerSettings = new(StringComparer.OrdinalIgnoreCase);
    private readonly List<DateTimeOffset> _foregroundSwitchTimes = [];
    private AmbientTransmissionPolicy _transmissionPolicy;

    private IntPtr _foregroundHook;
    private DateTimeOffset _lastForegroundCapture = DateTimeOffset.MinValue;
    private bool _disposed;
    private bool _started;
    private bool _monitorsRegistered;
    private bool _powerSettingsInitialized;
    private int _initialPowerSettingsSeen;
    private bool _sessionLocked;
    private string _lastPresenceBucket = "";
    private string _lastForegroundCategory = "";
    private string _lastBatteryBucket = "unknown";
    private int? _lastBatteryPercent;
    private bool? _lastCharging;
    private string _lastPowerSource = "";
    private bool? _lastNetworkAvailable;
    private string _lastMediaKey = "";
    private string _lastMediaPlaybackStatus = "";
    private string _lastTimeZoneId = "";
    private int _lastDisplayCount = -1;
    private ulong? _lastSystemIdleTime;
    private ulong? _lastSystemTotalTime;
    private bool _systemUnderLoadActive;
    private bool _contextSwitchBurstActive;
    private DateTimeOffset? _continuousActiveStartedAt;
    private DateTimeOffset? _lastBreakEndedAt;
    private bool _wasInBreak = true;
    private bool _longSessionWarningActive;
    private DateOnly? _lastActivityDate;

    public WindowsAmbientContextService(
        ISettingsStore settingsStore,
        ILogger<WindowsAmbientContextService> logger,
        MessageOnlyWindow messageWindow,
        string? snapshotPath = null)
    {
        _settingsStore = settingsStore ?? throw new ArgumentNullException(nameof(settingsStore));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _messageWindow = messageWindow ?? throw new ArgumentNullException(nameof(messageWindow));
        _snapshotPath = snapshotPath ?? GetDefaultSnapshotPath();
        _foregroundProc = OnForegroundEvent;
        _transmissionPolicy = AmbientTransmissionPolicy.Load(_settingsStore, GetPrivacyClassificationsForUi());
        _lastActivityDate = _settingsStore.LoadTransientStateSettings().LastActivityDate;
        _messageWindow.MessageReceived += OnMessageReceived;
    }

    public static int CaptureIntervalSeconds => SnapshotIntervalSeconds;

    public AmbientContextSnapshot LatestSnapshot { get; private set; } = new();

    public event EventHandler<AmbientContextSnapshot>? SnapshotUpdated;

    public static string GetDefaultSnapshotPath()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "AmbientContextMcp",
            "ambient-context.json");
    }

    public void Start()
    {
        if (_started)
        {
            return;
        }

        _started = true;
        _messageWindow.PostCallback(() =>
        {
            RegisterWindowMonitors();
            CaptureAndStore("startup");
        });
    }

    /// <summary>
    /// Triggered by the periodic capture host. Posts the capture work to the
    /// message-only window thread so it serializes with WTS / power / hook events.
    /// </summary>
    public void RequestPeriodicCapture()
    {
        if (!_started)
        {
            return;
        }

        _messageWindow.PostCallback(() => CaptureAndStore("timer"));
    }

    private void OnMessageReceived(object? sender, WindowMessageEventArgs e)
    {
        HandleWindowMessage(e.Message, e.WParam, e.LParam);
    }

    public void ReloadTransmissionPolicy()
    {
        _transmissionPolicy = AmbientTransmissionPolicy.Load(_settingsStore, GetPrivacyClassificationsForUi());
        if (_started)
        {
            CaptureAndStore("transmission_policy_reloaded");
        }
    }

    private void RegisterWindowMonitors()
    {
        if (_monitorsRegistered || _messageWindow.Hwnd == IntPtr.Zero)
        {
            return;
        }

        WTSRegisterSessionNotification(_messageWindow.Hwnd, NotifyForThisSession);
        RegisterPowerSettingNotifications(_messageWindow.Hwnd);

        _foregroundHook = SetWinEventHook(
            EventSystemForeground,
            EventSystemForeground,
            IntPtr.Zero,
            _foregroundProc,
            0,
            0,
            WinEventOutOfContext | WinEventSkipOwnProcess);

        AddEvent("ambient_monitor_attached", new Dictionary<string, string>
        {
            ["session"] = "registered",
            ["foreground"] = _foregroundHook == IntPtr.Zero ? "unavailable" : "registered",
            ["power_setting_notifications"] = _powerNotificationHandles.Count.ToString()
        }, initializationOnly: true);
        _monitorsRegistered = true;
    }

    public void HandleWindowMessage(int msg, IntPtr wParam, IntPtr lParam)
    {
        if (_disposed)
        {
            return;
        }

        switch (msg)
        {
            case WmWtsSessionChange:
                HandleSessionChange(wParam.ToInt32());
                break;
            case WmPowerBroadcast:
                HandlePowerBroadcast(wParam.ToInt32(), lParam);
                break;
        }
    }

    public AmbientContextSnapshot Capture()
    {
        var observedAt = DateTimeOffset.Now;
        var presence = GetPresence();
        var foreground = GetForegroundApp();
        var battery = GetBattery();
        var network = GetNetwork();
        var media = GetMedia();
        var power = GetPower();
        var system = GetSystem();
        var systemLoad = GetSystemLoad();
        var activity = GetActivity(observedAt);
        var wellness = GetWellness(presence, observedAt);
        var displays = GetDisplays();

        var snapshot = new AmbientContextSnapshot
        {
            ObservedAt = observedAt,
            Presence = presence,
            ForegroundApp = foreground,
            Battery = battery,
            Network = network,
            Media = media,
            Power = power,
            System = system,
            SystemLoad = systemLoad,
            Activity = activity,
            Wellness = wellness,
            Displays = displays,
            RecentEvents = GetRecentEvents()
        };

        EvaluatePresenceTransitions(presence);
        EvaluateForegroundTransitions(foreground);
        EvaluateBatteryTransitions(snapshot);
        EvaluateMediaTransitions(media);
        EvaluateNetworkTransitions(network);
        EvaluateSystemTransitions(system);
        EvaluateSystemLoadTransitions(systemLoad);
        EvaluateActivityTransitions(activity);
        EvaluateWellnessTransitions(wellness, presence, observedAt);
        EvaluateDisplayTransitions(displays);

        var events = GetRecentEvents();
        var outboundSnapshot = new AmbientContextSnapshot
        {
            ObservedAt = observedAt,
            Presence = presence,
            ForegroundApp = foreground,
            Battery = battery,
            Network = network,
            Media = media,
            Power = power,
            System = system,
            SystemLoad = systemLoad,
            Activity = activity,
            Wellness = wellness,
            Displays = displays,
            RecentEvents = events,
            States = BuildStates(
                observedAt,
                presence,
                foreground,
                battery,
                network,
                media,
                power,
                system,
                systemLoad,
                activity,
                wellness,
                displays),
            Events = BuildEvents(events),
            PrivacyClassifications = GetPrivacyClassifications()
        };
        return ApplyTransmissionPolicy(outboundSnapshot);
    }

    public string FormatSummary()
    {
        var snapshot = LatestSnapshot.ObservedAt == default ? Capture() : LatestSnapshot;
        var builder = new StringBuilder();

        builder.AppendLine($"observed_at: {snapshot.ObservedAt:yyyy-MM-dd HH:mm:ss zzz}");
        builder.AppendLine("source: outboundStates (MCP-visible)");
        builder.AppendLine($"states: {snapshot.OutboundStates.Count}/{snapshot.States.Count}");
        builder.AppendLine($"events: {snapshot.OutboundEvents.Count}/{snapshot.Events.Count}");
        builder.AppendLine($"transmission_settings: {snapshot.TransmissionPolicy.SettingsPath}");
        builder.AppendLine($"snapshot_file: {_snapshotPath}");
        builder.AppendLine();

        builder.AppendLine("[states]");
        if (snapshot.OutboundStates.Count == 0)
        {
            builder.AppendLine("(none)");
        }
        else
        {
            foreach (var state in snapshot.OutboundStates.OrderBy(item => item.Name, StringComparer.OrdinalIgnoreCase))
            {
                builder.AppendLine($"{state.Name}: {state.Value} ({state.Sensitivity})");
            }
        }

        builder.AppendLine();
        builder.AppendLine("[events]");
        if (snapshot.OutboundEvents.Count == 0)
        {
            builder.AppendLine("(none)");
        }
        else
        {
            foreach (var outboundEvent in snapshot.OutboundEvents.OrderBy(item => item.ObservedAt))
            {
                builder.AppendLine(
                    $"{outboundEvent.ObservedAt:yyyy-MM-dd HH:mm:ss zzz} {outboundEvent.Name}: {outboundEvent.Value} ({outboundEvent.Sensitivity})");
            }
        }

        return builder.ToString().TrimEnd();
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _messageWindow.MessageReceived -= OnMessageReceived;

        using var done = new ManualResetEventSlim(initialState: false);
        _messageWindow.PostCallback(() =>
        {
            try
            {
                if (_foregroundHook != IntPtr.Zero)
                {
                    UnhookWinEvent(_foregroundHook);
                    _foregroundHook = IntPtr.Zero;
                }

                foreach (var handle in _powerNotificationHandles)
                {
                    UnregisterPowerSettingNotification(handle);
                }

                _powerNotificationHandles.Clear();

                if (_messageWindow.Hwnd != IntPtr.Zero)
                {
                    WTSUnRegisterSessionNotification(_messageWindow.Hwnd);
                }

                _monitorsRegistered = false;
            }
            finally
            {
                done.Set();
            }
        });
        done.Wait(TimeSpan.FromSeconds(2));
    }

    private void CaptureAndStore(string reason)
    {
        if (!_started)
        {
            return;
        }

        try
        {
            LatestSnapshot = Capture();
            WriteSnapshot(LatestSnapshot);
            SnapshotUpdated?.Invoke(this, LatestSnapshot);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Ambient context capture failed for reason {Reason}", reason);
        }
    }

    private AmbientContextSnapshot ApplyTransmissionPolicy(AmbientContextSnapshot snapshot)
    {
        return new AmbientContextSnapshot
        {
            ObservedAt = snapshot.ObservedAt,
            Presence = snapshot.Presence,
            ForegroundApp = snapshot.ForegroundApp,
            Battery = snapshot.Battery,
            Network = snapshot.Network,
            Media = snapshot.Media,
            Power = snapshot.Power,
            System = snapshot.System,
            SystemLoad = snapshot.SystemLoad,
            Activity = snapshot.Activity,
            Wellness = snapshot.Wellness,
            Displays = snapshot.Displays,
            RecentEvents = snapshot.RecentEvents,
            States = snapshot.States,
            Events = snapshot.Events,
            OutboundStates = _transmissionPolicy.FilterStates(snapshot.States, snapshot.PrivacyClassifications),
            OutboundEvents = _transmissionPolicy.FilterEvents(snapshot.Events, snapshot.PrivacyClassifications),
            PrivacyClassifications = snapshot.PrivacyClassifications,
            TransmissionPolicy = _transmissionPolicy.Snapshot
        };
    }

    private void WriteSnapshot(AmbientContextSnapshot snapshot)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_snapshotPath)!);
        var tempPath = _snapshotPath + ".tmp";
        File.WriteAllText(tempPath, SerializeReadableJson(snapshot), Encoding.UTF8);
        File.Move(tempPath, _snapshotPath, true);
    }

    private static string SerializeReadableJson(AmbientContextSnapshot snapshot)
    {
        var json = JsonSerializer.Serialize(snapshot, JsonOptions);
        return Regex.Replace(
            json,
            @"\\u([0-9a-fA-F]{4})",
            match =>
            {
                var value = Convert.ToInt32(match.Groups[1].Value, 16);
                var character = (char)value;
                return char.IsControl(character) || character is '"' or '\\'
                    ? match.Value
                    : character.ToString();
            },
            RegexOptions.CultureInvariant);
    }

    private PresenceContext GetPresence()
    {
        var idleSeconds = GetIdleSeconds();
        return new PresenceContext
        {
            IdleSeconds = idleSeconds,
            SessionLocked = _sessionLocked,
            Bucket = _sessionLocked ? "locked" : AmbientTier1Rules.GetPresenceBucket(idleSeconds)
        };
    }

    private static int? GetIdleSeconds()
    {
        var info = new LastInputInfo
        {
            CbSize = (uint)Marshal.SizeOf<LastInputInfo>()
        };

        if (!GetLastInputInfo(ref info))
        {
            return null;
        }

        var currentTick = unchecked((uint)Environment.TickCount);
        var elapsedMilliseconds = unchecked(currentTick - info.DwTime);
        return (int)Math.Max(0, elapsedMilliseconds / 1000);
    }

    private static ForegroundAppContext GetForegroundApp()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero)
        {
            return new ForegroundAppContext();
        }

        _ = GetWindowThreadProcessId(hwnd, out var processId);
        var processName = GetProcessName(processId);
        var executableName = string.IsNullOrWhiteSpace(processName) ? "" : processName + ".exe";
        var app = AmbientTier1Rules.ClassifyApp(executableName);
        var title = GetWindowTitle(hwnd);

        return new ForegroundAppContext
        {
            ProcessId = processId == 0 ? null : (int)processId,
            ProcessName = executableName,
            AppName = app.AppName,
            Category = app.Category,
            HasWindowTitle = !string.IsNullOrWhiteSpace(title),
            RawWindowTitle = title,
            TitleSummary = AmbientTier1Rules.SummarizeWindowTitle(app.Category, title)
        };
    }

    private static string GetProcessName(uint processId)
    {
        if (processId == 0)
        {
            return "";
        }

        try
        {
            using var process = Process.GetProcessById((int)processId);
            return process.ProcessName;
        }
        catch
        {
            return "";
        }
    }

    private static string GetWindowTitle(IntPtr hwnd)
    {
        var length = GetWindowTextLength(hwnd);
        if (length <= 0)
        {
            return "";
        }

        var builder = new StringBuilder(Math.Min(length + 1, 1024));
        _ = GetWindowText(hwnd, builder, builder.Capacity);
        return builder.ToString();
    }

    private static BatteryContext GetBattery()
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

    private static NetworkContext GetNetwork()
    {
        return new NetworkContext
        {
            IsAvailable = NetworkInterface.GetIsNetworkAvailable()
        };
    }

    // SMTC API は WinRT のセッションプロセス (各 media app) を経由するため、
    // 相手アプリがハング/未応答の場合、await が永久に返らないことがある。
    // 取得スレッドは MessageOnlyWindow の単一スレッドで、ここが詰まると
    // foreground hook など全イベント処理が止まる (= 過去に observed)。
    // 短い timeout でタスクが返らなければ「media 不明」として続行する。
    private static readonly TimeSpan MediaApiTimeout = TimeSpan.FromMilliseconds(1500);

    private static MediaContext GetMedia()
    {
        try
        {
            var requestTask = GlobalSystemMediaTransportControlsSessionManager.RequestAsync().AsTask();
            if (!requestTask.Wait(MediaApiTimeout))
            {
                return new MediaContext { Error = "GetMedia.RequestAsync timed out" };
            }
            var manager = requestTask.Result;
            var allSessions = manager.GetSessions()
                .Select(ToMediaSessionContext)
                .ToList();
            var currentSession = manager.GetCurrentSession();
            var currentSource = currentSession?.SourceAppUserModelId ?? "";
            var selectedSession = allSessions.FirstOrDefault(item => item.IsPlaying)
                ?? allSessions.FirstOrDefault(item => item.SourceAppUserModelId.Equals(currentSource, StringComparison.OrdinalIgnoreCase))
                ?? allSessions.FirstOrDefault();

            var sessions = allSessions.Select(item => CopyMediaSession(item, ReferenceEquals(item, selectedSession))).ToList();
            var session = selectedSession is null ? null : FindSessionBySource(manager, selectedSession.SourceAppUserModelId);
            if (session is null)
            {
                return new MediaContext
                {
                    Sessions = sessions
                };
            }

            var playbackInfo = session.GetPlaybackInfo();
            var playbackStatus = playbackInfo.PlaybackStatus.ToString();
            var timeline = session.GetTimelineProperties();
            var propsTask = session.TryGetMediaPropertiesAsync().AsTask();
            if (!propsTask.Wait(MediaApiTimeout))
            {
                return new MediaContext
                {
                    IsAvailable = true,
                    SourceAppUserModelId = session.SourceAppUserModelId,
                    PlaybackStatus = playbackStatus,
                    IsPlaying = playbackStatus.Equals("Playing", StringComparison.OrdinalIgnoreCase),
                    PositionMilliseconds = (long)timeline.Position.TotalMilliseconds,
                    StartTimeMilliseconds = (long)timeline.StartTime.TotalMilliseconds,
                    EndTimeMilliseconds = (long)timeline.EndTime.TotalMilliseconds,
                    TimelineLastUpdatedAt = timeline.LastUpdatedTime,
                    Sessions = sessions,
                    Error = "GetMedia.TryGetMediaPropertiesAsync timed out"
                };
            }
            var mediaProperties = propsTask.Result;

            return new MediaContext
            {
                IsAvailable = true,
                SourceAppUserModelId = session.SourceAppUserModelId,
                PlaybackStatus = playbackStatus,
                IsPlaying = playbackStatus.Equals("Playing", StringComparison.OrdinalIgnoreCase),
                Title = mediaProperties.Title,
                Artist = mediaProperties.Artist,
                AlbumTitle = mediaProperties.AlbumTitle,
                AlbumArtist = mediaProperties.AlbumArtist,
                TrackNumber = (int)mediaProperties.TrackNumber,
                Genres = mediaProperties.Genres?.ToList() ?? [],
                PositionMilliseconds = (long)timeline.Position.TotalMilliseconds,
                StartTimeMilliseconds = (long)timeline.StartTime.TotalMilliseconds,
                EndTimeMilliseconds = (long)timeline.EndTime.TotalMilliseconds,
                TimelineLastUpdatedAt = timeline.LastUpdatedTime,
                Sessions = sessions
            };
        }
        catch (Exception ex)
        {
            return new MediaContext
            {
                Error = ex.GetType().Name + ": " + ex.Message
            };
        }
    }

    private static GlobalSystemMediaTransportControlsSession? FindSessionBySource(
        GlobalSystemMediaTransportControlsSessionManager manager,
        string sourceAppUserModelId)
    {
        return manager.GetSessions()
            .FirstOrDefault(item => item.SourceAppUserModelId.Equals(sourceAppUserModelId, StringComparison.OrdinalIgnoreCase));
    }

    private static MediaSessionContext ToMediaSessionContext(GlobalSystemMediaTransportControlsSession session)
    {
        try
        {
            var playbackInfo = session.GetPlaybackInfo();
            var playbackStatus = playbackInfo.PlaybackStatus.ToString();
            var timeline = session.GetTimelineProperties();
            var propsTask = session.TryGetMediaPropertiesAsync().AsTask();
            if (!propsTask.Wait(MediaApiTimeout))
            {
                return new MediaSessionContext
                {
                    SourceAppUserModelId = session.SourceAppUserModelId,
                    PlaybackStatus = playbackStatus,
                    IsPlaying = playbackStatus.Equals("Playing", StringComparison.OrdinalIgnoreCase),
                    PositionMilliseconds = (long)timeline.Position.TotalMilliseconds,
                    EndTimeMilliseconds = (long)timeline.EndTime.TotalMilliseconds,
                    Error = "ToMediaSessionContext.TryGetMediaPropertiesAsync timed out"
                };
            }
            var mediaProperties = propsTask.Result;

            return new MediaSessionContext
            {
                SourceAppUserModelId = session.SourceAppUserModelId,
                PlaybackStatus = playbackStatus,
                IsPlaying = playbackStatus.Equals("Playing", StringComparison.OrdinalIgnoreCase),
                Title = mediaProperties.Title,
                Artist = mediaProperties.Artist,
                AlbumTitle = mediaProperties.AlbumTitle,
                PositionMilliseconds = (long)timeline.Position.TotalMilliseconds,
                EndTimeMilliseconds = (long)timeline.EndTime.TotalMilliseconds
            };
        }
        catch (Exception ex)
        {
            return new MediaSessionContext
            {
                SourceAppUserModelId = session.SourceAppUserModelId,
                Error = ex.GetType().Name + ": " + ex.Message
            };
        }
    }

    private static MediaSessionContext CopyMediaSession(MediaSessionContext session, bool selected)
    {
        return new MediaSessionContext
        {
            Selected = selected,
            SourceAppUserModelId = session.SourceAppUserModelId,
            PlaybackStatus = session.PlaybackStatus,
            IsPlaying = session.IsPlaying,
            Title = session.Title,
            Artist = session.Artist,
            AlbumTitle = session.AlbumTitle,
            PositionMilliseconds = session.PositionMilliseconds,
            EndTimeMilliseconds = session.EndTimeMilliseconds,
            Error = session.Error
        };
    }

    private PowerContext GetPower()
    {
        AmbientEvent? lastPowerEvent;
        lock (_eventLock)
        {
            lastPowerEvent = _recentEvents.LastOrDefault(item =>
                item.Kind.Equals("power_setting_changed", StringComparison.OrdinalIgnoreCase));
        }

        return new PowerContext
        {
            LastKnownSettings = new Dictionary<string, string>(_lastPowerSettings, StringComparer.OrdinalIgnoreCase),
            LastPowerSettingEvent = lastPowerEvent
        };
    }

    private static SystemContext GetSystem()
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

    private SystemLoadContext GetSystemLoad()
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

    private ActivityContext GetActivity(DateTimeOffset observedAt)
    {
        lock (_eventLock)
        {
            TrimForegroundSwitchTimes(observedAt);
            return new ActivityContext
            {
                ContextSwitchesPerMin = _foregroundSwitchTimes.Count
            };
        }
    }

    private WellnessContext GetWellness(PresenceContext presence, DateTimeOffset observedAt)
    {
        var inBreak = IsBreakPresence(presence.Bucket);
        if (inBreak)
        {
            _continuousActiveStartedAt = null;
            _wasInBreak = true;
            _longSessionWarningActive = false;
            return new WellnessContext();
        }

        _continuousActiveStartedAt ??= observedAt;
        if (_wasInBreak || _lastBreakEndedAt is null)
        {
            _lastBreakEndedAt = observedAt;
        }

        _wasInBreak = false;
        return new WellnessContext
        {
            ContinuousActiveMinutes = GetWholeMinutes(observedAt - _continuousActiveStartedAt.Value),
            MinutesSinceLastBreak = GetWholeMinutes(observedAt - _lastBreakEndedAt.Value)
        };
    }

    private static IReadOnlyList<DisplayContext> GetDisplays()
    {
        return DisplayEnumerator.GetAll();
    }

    private void HandleSessionChange(int change)
    {
        switch (change)
        {
            case WtsSessionLock:
                _sessionLocked = true;
                AddEvent("session_locked");
                CaptureAndStore("session_locked");
                break;
            case WtsSessionUnlock:
                _sessionLocked = false;
                AddEvent("session_unlocked");
                CaptureAndStore("session_unlocked");
                break;
            case WtsSessionLogon:
                AddEvent("session_logon");
                CaptureAndStore("session_logon");
                break;
            case WtsSessionLogoff:
                AddEvent("session_logoff");
                CaptureAndStore("session_logoff");
                break;
        }
    }

    private void HandlePowerBroadcast(int change, IntPtr lParam)
    {
        if (change == PbtPowerSettingChange)
        {
            var powerSetting = ReadPowerSetting(lParam);
            if (powerSetting.Data.TryGetValue("setting", out var setting) &&
                powerSetting.Data.TryGetValue("value", out var value))
            {
                if (!_powerSettingsInitialized)
                {
                    InitializePowerSetting(setting, value);
                    CaptureAndStore("power_setting_initialized");
                    return;
                }

                AddEvent("power_setting_changed", powerSetting.Data);
                if (setting.Equals("ac_dc_power_source", StringComparison.OrdinalIgnoreCase))
                {
                    AddPowerSourceTransitionEvents(_lastPowerSource, value);
                    _lastPowerSource = value;
                }

                _lastPowerSettings[setting] = value;
            }

            CaptureAndStore("power_setting_changed");
            return;
        }

        var kind = change switch
        {
            PbtApmSuspend => "system_suspend",
            PbtApmResumeSuspend => "system_resume_user",
            PbtApmResumeAutomatic => "system_resume_automatic",
            _ => ""
        };

        if (!string.IsNullOrWhiteSpace(kind))
        {
            AddEvent(kind);
            CaptureAndStore(kind);
        }
    }

    private void InitializePowerSetting(string setting, string value)
    {
        if (!_lastPowerSettings.ContainsKey(setting))
        {
            _initialPowerSettingsSeen++;
        }

        _lastPowerSettings[setting] = value;
        if (setting.Equals("ac_dc_power_source", StringComparison.OrdinalIgnoreCase))
        {
            _lastPowerSource = value;
        }

        if (_initialPowerSettingsSeen >= Math.Min(ExpectedInitialPowerSettingCount, _powerNotificationHandles.Count))
        {
            _powerSettingsInitialized = true;
            AddEvent("power_settings_initialized", new Dictionary<string, string>
            {
                ["count"] = _initialPowerSettingsSeen.ToString(System.Globalization.CultureInfo.InvariantCulture)
            }, initializationOnly: true);
        }
    }

    private void RegisterPowerSettingNotifications(IntPtr windowHandle)
    {
        foreach (var guid in new[]
        {
            GuidAcDcPowerSource,
            GuidBatteryPercentageRemaining,
            GuidConsoleDisplayState,
            GuidGlobalUserPresence,
            GuidLidSwitchStateChange,
            GuidMonitorPowerOn,
            GuidPowerSavingStatus,
            GuidSessionDisplayStatus
        })
        {
            var powerSetting = guid;
            var handle = RegisterPowerSettingNotification(windowHandle, ref powerSetting, DeviceNotifyWindowHandle);
            if (handle != IntPtr.Zero)
            {
                _powerNotificationHandles.Add(handle);
            }
        }
    }

    private void AddPowerSourceTransitionEvents(string previous, string current)
    {
        if (string.IsNullOrWhiteSpace(current) ||
            string.Equals(previous, current, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        var data = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["from"] = string.IsNullOrWhiteSpace(previous) ? "unknown" : previous,
            ["to"] = current
        };
        AddEvent("power_source_changed", data);

        var eventName = current switch
        {
            "ac" => "ac_power_connected",
            "battery" => "battery_power_active",
            "short_term" => "short_term_power_active",
            _ => ""
        };

        if (!string.IsNullOrWhiteSpace(eventName))
        {
            AddEvent(eventName, data);
        }
    }

    private static (string Name, IReadOnlyDictionary<string, string> Data) ReadPowerSetting(IntPtr lParam)
    {
        if (lParam == IntPtr.Zero)
        {
            return ("unknown", new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
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
            return (name, new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                ["setting"] = name,
                ["guid"] = header.PowerSetting.ToString("D"),
                ["value"] = FormatPowerSettingValue(header.PowerSetting, value),
                ["raw_value"] = value.ToString(System.Globalization.CultureInfo.InvariantCulture),
                ["data_length"] = header.DataLength.ToString(System.Globalization.CultureInfo.InvariantCulture)
            });
        }
        catch (Exception ex)
        {
            return ("unknown", new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
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
                _ => value.ToString(System.Globalization.CultureInfo.InvariantCulture)
            };
        }

        if (guid == GuidConsoleDisplayState || guid == GuidSessionDisplayStatus)
        {
            return value switch
            {
                0 => "off",
                1 => "on",
                2 => "dimmed",
                _ => value.ToString(System.Globalization.CultureInfo.InvariantCulture)
            };
        }

        if (guid == GuidGlobalUserPresence)
        {
            return value switch
            {
                0 => "present",
                2 => "inactive",
                _ => value.ToString(System.Globalization.CultureInfo.InvariantCulture)
            };
        }

        if (guid == GuidLidSwitchStateChange || guid == GuidMonitorPowerOn || guid == GuidPowerSavingStatus)
        {
            return value == 0 ? "off" : "on";
        }

        return value.ToString(System.Globalization.CultureInfo.InvariantCulture);
    }

    private void OnForegroundEvent(
        IntPtr hook,
        uint eventType,
        IntPtr hwnd,
        int idObject,
        int idChild,
        uint eventThread,
        uint eventTime)
    {
        var now = DateTimeOffset.Now;
        if (now - _lastForegroundCapture < TimeSpan.FromMilliseconds(ForegroundCaptureThrottleMilliseconds))
        {
            return;
        }

        _lastForegroundCapture = now;
        lock (_eventLock)
        {
            _foregroundSwitchTimes.Add(now);
            TrimForegroundSwitchTimes(now);
        }

        // payload key は media_session_changed と同様に親 event の許可を継承する。
        // category/app_name/process_name は medium (foregroundApp.* と同分類) なので、
        // events.foreground_changed を ON にしたユーザーには、そのまま流れる。
        var foreground = GetForegroundApp();
        AddEvent("foreground_changed", new Dictionary<string, string>
        {
            ["category"] = foreground.Category,
            ["app_name"] = foreground.AppName,
            ["process_name"] = foreground.ProcessName
        }, "medium");
        CaptureAndStore("foreground_changed");
    }

    private void AddEvent(
        string kind,
        IReadOnlyDictionary<string, string>? data = null,
        string sensitivity = "low",
        bool initializationOnly = false)
    {
        lock (_eventLock)
        {
            _recentEvents.Add(new AmbientEvent
            {
                ObservedAt = DateTimeOffset.Now,
                Kind = kind,
                Sensitivity = sensitivity,
                InitializationOnly = initializationOnly,
                Data = data ?? new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            });

            TrimRecentEvents(DateTimeOffset.Now);
        }
    }

    private IReadOnlyList<AmbientEvent> GetRecentEvents()
    {
        lock (_eventLock)
        {
            TrimRecentEvents(DateTimeOffset.Now);
            return _recentEvents.ToList();
        }
    }

    private void TrimRecentEvents(DateTimeOffset now)
    {
        var cutoff = now - RecentEventRetention;
        _recentEvents.RemoveAll(item => item.ObservedAt < cutoff);

        if (_recentEvents.Count > MaxRecentEvents)
        {
            _recentEvents.RemoveRange(0, _recentEvents.Count - MaxRecentEvents);
        }
    }

    private void TrimForegroundSwitchTimes(DateTimeOffset now)
    {
        var cutoff = now - TimeSpan.FromMinutes(1);
        _foregroundSwitchTimes.RemoveAll(item => item < cutoff);
    }

    private static bool IsBreakPresence(string bucket)
    {
        return bucket.Equals("away_short", StringComparison.OrdinalIgnoreCase) ||
               bucket.Equals("away_long", StringComparison.OrdinalIgnoreCase) ||
               bucket.Equals("locked", StringComparison.OrdinalIgnoreCase);
    }

    private static int GetWholeMinutes(TimeSpan value)
    {
        return Math.Max(0, (int)Math.Floor(value.TotalMinutes));
    }

    private static ulong ToUInt64(FileTime value)
    {
        return ((ulong)value.HighDateTime << 32) | value.LowDateTime;
    }
}
