using AmbientContextMcp.Core.Models;
using AmbientContextMcp.Core.Settings;

namespace AmbientContextMcp.AmbientContext;

public sealed partial class WindowsAmbientContextService
{
    private void EvaluatePresenceTransitions(PresenceContext presence)
    {
        if (string.IsNullOrWhiteSpace(_lastPresenceBucket))
        {
            _lastPresenceBucket = presence.Bucket;
            return;
        }

        if (presence.Bucket.Equals(_lastPresenceBucket, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        var data = TransitionData(_lastPresenceBucket, presence.Bucket);
        AddEvent("presence_bucket_changed", data);

        if (presence.Bucket.Equals("active", StringComparison.OrdinalIgnoreCase) &&
            _lastPresenceBucket is "idle" or "away_short" or "away_long" or "locked")
        {
            AddEvent("user_returned", data);
        }
        else if (presence.Bucket.Equals("idle", StringComparison.OrdinalIgnoreCase) &&
                 _lastPresenceBucket.Equals("active", StringComparison.OrdinalIgnoreCase))
        {
            AddEvent("user_became_idle", data);
        }

        _lastPresenceBucket = presence.Bucket;
    }

    private void EvaluateForegroundTransitions(ForegroundAppContext foreground)
    {
        // Category="" は「該当データなし」の正規値なので空文字で未初期化判定をしてはいけない。
        // 初期化フラグでベースライン取得と通常遷移を分ける。
        if (!_foregroundCategoryInitialized)
        {
            _lastForegroundCategory = foreground.Category;
            _foregroundCategoryInitialized = true;
            return;
        }

        if (foreground.Category.Equals(_lastForegroundCategory, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        // foreground_changed は HigherLevelEventsBySuppressedEvent (Projection.cs:13-16) によって
        // この event 発火時に outbound から落とされるため、後から「何のアプリだったか」を辿れるよう
        // app_name / process_name もここに載せる (media_session_changed と同設計)。
        var data = TransitionData(_lastForegroundCategory, foreground.Category);
        data["app_name"] = foreground.AppName;
        data["process_name"] = foreground.ProcessName;
        AddEvent("foreground_app_category_changed", data, "medium");
        _lastForegroundCategory = foreground.Category;
    }

    private void EvaluateBatteryTransitions(AmbientContextSnapshot snapshot)
    {
        EvaluateBatteryThresholds(snapshot.Battery.Percent);

        if (snapshot.Battery.Bucket != _lastBatteryBucket)
        {
            if (snapshot.Battery.Bucket is "medium" or "low" or "critical")
            {
                AddEvent("battery_" + snapshot.Battery.Bucket, new Dictionary<string, string>
                {
                    ["percent"] = snapshot.Battery.Percent?.ToString() ?? "unknown"
                });
            }

            _lastBatteryBucket = snapshot.Battery.Bucket;
        }

        if (_lastCharging is not null && snapshot.Battery.Charging != _lastCharging)
        {
            AddEvent(snapshot.Battery.Charging == true ? "charger_connected" : "charger_disconnected");
        }

        _lastCharging = snapshot.Battery.Charging;
    }

    private void EvaluateBatteryThresholds(int? currentPercent)
    {
        if (_lastBatteryPercent is null)
        {
            _lastBatteryPercent = currentPercent;
            return;
        }

        if (currentPercent is null)
        {
            _lastBatteryPercent = null;
            return;
        }

        foreach (var threshold in AmbientTier1Rules.BatteryPercentThresholds)
        {
            var previous = _lastBatteryPercent.Value;
            if (previous > threshold && currentPercent <= threshold)
            {
                AddEvent("battery_percent_crossed_threshold", new Dictionary<string, string>
                {
                    ["threshold"] = threshold.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    ["direction"] = "down",
                    ["from"] = previous.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    ["to"] = currentPercent.Value.ToString(System.Globalization.CultureInfo.InvariantCulture)
                });
            }
            else if (previous < threshold && currentPercent >= threshold)
            {
                AddEvent("battery_percent_crossed_threshold", new Dictionary<string, string>
                {
                    ["threshold"] = threshold.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    ["direction"] = "up",
                    ["from"] = previous.ToString(System.Globalization.CultureInfo.InvariantCulture),
                    ["to"] = currentPercent.Value.ToString(System.Globalization.CultureInfo.InvariantCulture)
                });
            }
        }

        _lastBatteryPercent = currentPercent;
    }

    private void EvaluateMediaTransitions(MediaContext media)
    {
        if (!string.IsNullOrWhiteSpace(_lastMediaPlaybackStatus) &&
            !media.PlaybackStatus.Equals(_lastMediaPlaybackStatus, StringComparison.OrdinalIgnoreCase))
        {
            var data = TransitionData(_lastMediaPlaybackStatus, media.PlaybackStatus);
            var eventName = media.PlaybackStatus switch
            {
                "Playing" => "media_playback_started",
                "Paused" => "media_playback_paused",
                "Stopped" => "media_playback_stopped",
                _ => "media_playback_status_changed"
            };
            AddEvent(eventName, data, "medium");
        }

        _lastMediaPlaybackStatus = media.PlaybackStatus;

        var key = media.IsAvailable
            ? string.Join("|", media.SourceAppUserModelId, media.PlaybackStatus, media.Title, media.Artist)
            : "";

        if (key == _lastMediaKey)
        {
            return;
        }

        if (!string.IsNullOrWhiteSpace(key))
        {
            // event 本体は medium (タイミング信号 + 再生元アプリ程度)。
            // title / artist は AmbientTransmissionPolicy の payload key 単位フィルタで個別判定される。
            AddEvent("media_session_changed", new Dictionary<string, string>
            {
                ["source_app"] = media.SourceAppUserModelId,
                ["playback_status"] = media.PlaybackStatus,
                ["title"] = media.Title,
                ["artist"] = media.Artist
            }, "medium");
        }

        _lastMediaKey = key;
    }

    private void EvaluateNetworkTransitions(NetworkContext network)
    {
        if (_lastNetworkAvailable is null)
        {
            _lastNetworkAvailable = network.IsAvailable;
            return;
        }

        if (_lastNetworkAvailable == network.IsAvailable)
        {
            return;
        }

        AddEvent("network_connectivity_changed", new Dictionary<string, string>
        {
            ["from"] = _lastNetworkAvailable.Value ? "online" : "offline",
            ["to"] = network.IsAvailable ? "online" : "offline"
        });
        _lastNetworkAvailable = network.IsAvailable;
    }

    private void EvaluateSystemTransitions(SystemContext system)
    {
        if (string.IsNullOrWhiteSpace(_lastTimeZoneId))
        {
            _lastTimeZoneId = system.TimeZoneId;
            return;
        }

        if (system.TimeZoneId.Equals(_lastTimeZoneId, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        AddEvent("timezone_changed", TransitionData(_lastTimeZoneId, system.TimeZoneId), "medium");
        _lastTimeZoneId = system.TimeZoneId;
    }

    private void EvaluateSystemLoadTransitions(SystemLoadContext systemLoad)
    {
        var underLoad = IsHighPressureBucket(systemLoad.CpuPressureBucket) ||
                        IsHighPressureBucket(systemLoad.MemoryPressureBucket);
        if (underLoad && !_systemUnderLoadActive)
        {
            AddEvent("system_under_load", new Dictionary<string, string>
            {
                ["cpu_pressure"] = systemLoad.CpuPressureBucket,
                ["memory_pressure"] = systemLoad.MemoryPressureBucket
            });
        }

        _systemUnderLoadActive = underLoad;
    }

    private void EvaluateActivityTransitions(ActivityContext activity)
    {
        if (activity.ContextSwitchesPerMin >= ContextSwitchBurstThresholdPerMinute && !_contextSwitchBurstActive)
        {
            AddEvent("context_switch_burst", new Dictionary<string, string>
            {
                ["switches_per_min"] = activity.ContextSwitchesPerMin.ToString(System.Globalization.CultureInfo.InvariantCulture)
            }, "medium");
            _contextSwitchBurstActive = true;
        }
        else if (activity.ContextSwitchesPerMin < ContextSwitchBurstResetThresholdPerMinute)
        {
            _contextSwitchBurstActive = false;
        }
    }

    private void EvaluateWellnessTransitions(WellnessContext wellness, PresenceContext presence, DateTimeOffset observedAt)
    {
        if (!IsBreakPresence(presence.Bucket) && _lastActivityDate != DateOnly.FromDateTime(observedAt.DateTime))
        {
            _lastActivityDate = DateOnly.FromDateTime(observedAt.DateTime);
            PersistLastActivityDate(_lastActivityDate.Value);
            AddEvent("first_activity_today");
        }

        if (wellness.ContinuousActiveMinutes >= LongSessionWarningMinutes && !_longSessionWarningActive)
        {
            AddEvent("long_session_warning", new Dictionary<string, string>
            {
                ["continuous_active_minutes"] = wellness.ContinuousActiveMinutes.ToString(System.Globalization.CultureInfo.InvariantCulture)
            });
            _longSessionWarningActive = true;
        }
        else if (wellness.ContinuousActiveMinutes < LongSessionWarningMinutes)
        {
            _longSessionWarningActive = false;
        }
    }

    /// <summary>
    /// first_activity_today を発火したローカル日を永続化する。プロセス再起動を跨いで
    /// 同日中の再発火を抑止する。永続化に失敗してもイベント発火自体は止めない (best-effort)。
    /// </summary>
    private void PersistLastActivityDate(DateOnly date)
    {
        try
        {
            _settingsStore.SaveTransientStateSettings(new TransientStateSettings
            {
                SchemaVersion = 1,
                LastActivityDate = date
            });
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to persist LastActivityDate; first_activity_today may re-fire on next restart.");
        }
    }

    private void EvaluateDisplayTransitions(IReadOnlyList<DisplayContext> displays)
    {
        if (_lastDisplayCount < 0)
        {
            _lastDisplayCount = displays.Count;
            return;
        }

        if (_lastDisplayCount == displays.Count)
        {
            return;
        }

        AddEvent("display_count_changed", new Dictionary<string, string>
        {
            ["from"] = _lastDisplayCount.ToString(System.Globalization.CultureInfo.InvariantCulture),
            ["to"] = displays.Count.ToString(System.Globalization.CultureInfo.InvariantCulture)
        }, "medium");
        _lastDisplayCount = displays.Count;
    }

    private static Dictionary<string, string> TransitionData(string previous, string current)
    {
        // 「該当データなし」は空文字でそのまま返す。集計時に "" / 欠落 / "unknown" の 3 系統が
        // 混在しないようにする方針 (AmbientTier1Rules.ClassifyApp と同じ整合)。
        return new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["from"] = previous,
            ["to"] = current
        };
    }

    private static bool IsHighPressureBucket(string bucket)
    {
        return bucket.Equals("high", StringComparison.OrdinalIgnoreCase) ||
               bucket.Equals("critical", StringComparison.OrdinalIgnoreCase);
    }
}
