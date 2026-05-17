using System.ComponentModel;
using System.Runtime.CompilerServices;
using AmbientContextMcp.Core.Models;
using AmbientContextMcp.Resources;

namespace AmbientContextMcp.Settings;

public sealed class TransmissionOptionViewModel : INotifyPropertyChanged
{
    private bool _isAllowed;

    public string Path { get; init; } = "";

    public string Label { get; init; } = "";

    public string Sensitivity { get; init; } = "medium";

    public bool IsAllowed
    {
        get => _isAllowed;
        set
        {
            if (_isAllowed == value)
            {
                return;
            }

            _isAllowed = value;
            OnPropertyChanged();
        }
    }

    public event PropertyChangedEventHandler? PropertyChanged;

    public static List<TransmissionOptionViewModel> CreateAll()
    {
        return AmbientContextCatalog.GetTransmissionOptions()
            .Select(option => new TransmissionOptionViewModel
            {
                Path = option.Path,
                Label = GetLabel(option.Path),
                Sensitivity = option.Sensitivity
            })
            .ToList();
    }

    private static string GetLabel(string path)
    {
        return path switch
        {
            "foregroundApp.category" => Strings.TxOptForegroundCategory,
            "foregroundApp.appName" => Strings.TxOptForegroundAppName,
            "foregroundApp.processName" => Strings.TxOptForegroundProcessName,
            "foregroundApp.titleSummary" => Strings.TxOptForegroundTitleSummary,
            "foregroundApp.rawWindowTitle" => Strings.TxOptForegroundRawWindowTitle,
            "events.foreground_changed" => Strings.TxOptEventForegroundChanged,
            "activity.contextSwitchesPerMin" => Strings.TxOptActivityContextSwitches,
            "events.context_switch_burst" => Strings.TxOptEventContextSwitchBurst,
            "media.isAvailable" => Strings.TxOptMediaIsAvailable,
            "media.playbackStatus" => Strings.TxOptMediaPlaybackStatus,
            "media.sourceAppUserModelId" => Strings.TxOptMediaSourceApp,
            "media.title" => Strings.TxOptMediaTitle,
            "media.artist" => Strings.TxOptMediaArtist,
            "media.albumTitle" => Strings.TxOptMediaAlbumTitle,
            "events.media_playback_started" => Strings.TxOptEventMediaPlaybackStarted,
            "events.media_playback_paused" => Strings.TxOptEventMediaPlaybackPaused,
            "events.media_session_changed" => Strings.TxOptEventMediaSessionChanged,
            "events.media_session_changed.title" => Strings.TxOptEventMediaSessionChangedTitle,
            "events.media_session_changed.artist" => Strings.TxOptEventMediaSessionChangedArtist,
            "system.timeZoneId" => Strings.TxOptSystemTimeZone,
            "display.count" => Strings.TxOptDisplayCount,
            "displays" => Strings.TxOptDisplays,
            _ => path
        };
    }

    private void OnPropertyChanged([CallerMemberName] string? propertyName = null)
    {
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));
    }
}
