using AmbientContextMcp.Core.Diagnostics;
using AmbientContextMcp.Core.Models;
using Windows.Media.Control;

namespace AmbientContextMcp.AmbientContext;

public static class WindowsMediaContextCollector
{
    // SMTC API は WinRT のセッションプロセス (各 media app) を経由するため、
    // 相手アプリがハング/未応答の場合、await が永久に返らないことがある。
    // 短い timeout でタスクが返らなければ「media 不明」として続行する。
    private static readonly TimeSpan MediaApiTimeout = TimeSpan.FromMilliseconds(1500);

    public static async Task<MediaContext> GetMediaAsync()
    {
        try
        {
            GlobalSystemMediaTransportControlsSessionManager manager;
            try
            {
                manager = await GlobalSystemMediaTransportControlsSessionManager
                    .RequestAsync()
                    .AsTask()
                    .WaitAsync(MediaApiTimeout)
                    .ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
                AppDiagnosticLog.Log("media", "get_media_request_timed_out", new Dictionary<string, object?>
                {
                    ["timeoutMs"] = (int)MediaApiTimeout.TotalMilliseconds
                });
                return new MediaContext { Error = "GetMedia.RequestAsync timed out" };
            }

            var rawSessions = manager.GetSessions().ToList();
            var allSessions = new List<MediaSessionContext>(rawSessions.Count);
            foreach (var rawSession in rawSessions)
            {
                allSessions.Add(await ToMediaSessionContextAsync(rawSession).ConfigureAwait(false));
            }

            var currentSession = manager.GetCurrentSession();
            var currentSource = currentSession?.SourceAppUserModelId ?? "";
            var selectedSession = allSessions.FirstOrDefault(item => item.IsPlaying)
                ?? allSessions.FirstOrDefault(item => item.SourceAppUserModelId.Equals(currentSource, StringComparison.OrdinalIgnoreCase))
                ?? allSessions.FirstOrDefault();

            // SMTC 検出問題 (例: Spotify が再生中なのに sessions が空) の切り分け用。
            // AUMID は Spotify.exe / chrome.exe / SpotifyAB...!Spotify など識別子であり
            // 個人情報を含まない。Title/Artist など payload は意図的に記録しない。
            AppDiagnosticLog.Log("media", "get_media_sessions", new Dictionary<string, object?>
            {
                ["count"] = allSessions.Count,
                ["aumids"] = allSessions.Select(item => item.SourceAppUserModelId).ToList(),
                ["currentSource"] = currentSource,
                ["selectedSource"] = selectedSession?.SourceAppUserModelId ?? "",
                ["selectedIsPlaying"] = selectedSession?.IsPlaying ?? false,
                ["playingCount"] = allSessions.Count(item => item.IsPlaying),
                ["sessionErrors"] = allSessions.Count(item => !string.IsNullOrEmpty(item.Error))
            });

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
            GlobalSystemMediaTransportControlsSessionMediaProperties mediaProperties;
            try
            {
                mediaProperties = await session.TryGetMediaPropertiesAsync()
                    .AsTask()
                    .WaitAsync(MediaApiTimeout)
                    .ConfigureAwait(false);
            }
            catch (TimeoutException)
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
            AppDiagnosticLog.LogException("media", "get_media_failed", ex);
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

    private static async Task<MediaSessionContext> ToMediaSessionContextAsync(GlobalSystemMediaTransportControlsSession session)
    {
        try
        {
            var playbackInfo = session.GetPlaybackInfo();
            var playbackStatus = playbackInfo.PlaybackStatus.ToString();
            var timeline = session.GetTimelineProperties();
            GlobalSystemMediaTransportControlsSessionMediaProperties mediaProperties;
            try
            {
                mediaProperties = await session.TryGetMediaPropertiesAsync()
                    .AsTask()
                    .WaitAsync(MediaApiTimeout)
                    .ConfigureAwait(false);
            }
            catch (TimeoutException)
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
}
