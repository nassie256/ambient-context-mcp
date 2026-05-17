using AmbientContextMcp.Core.Models;
using Windows.Media.Control;

namespace AmbientContextMcp.AmbientContext;

public static class WindowsMediaContextCollector
{
    // SMTC API は WinRT のセッションプロセス (各 media app) を経由するため、
    // 相手アプリがハング/未応答の場合、await が永久に返らないことがある。
    // 短い timeout でタスクが返らなければ「media 不明」として続行する。
    private static readonly TimeSpan MediaApiTimeout = TimeSpan.FromMilliseconds(1500);

    public static MediaContext GetMedia()
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
}
