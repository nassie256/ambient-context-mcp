using AmbientContextMcp.Core.Models;
using AmbientContextMcp.Resources;

namespace AmbientContextMcp.Settings;

public sealed class TransmissionGroupViewModel
{
    public string Id { get; init; } = "";

    public string Title { get; init; } = "";

    public List<TransmissionOptionViewModel> Options { get; init; } = [];

    public static List<TransmissionGroupViewModel> CreateAll()
    {
        return AmbientContextCatalog.GetTransmissionUiGroups()
            .Select(group => new TransmissionGroupViewModel
            {
                Id = group.Id,
                Title = GetGroupTitle(group.Id),
                Options = group.Options
                    .Select(option => new TransmissionOptionViewModel
                    {
                        Id = option.Id,
                        PrimaryPath = option.PrimaryPath,
                        Label = GetOptionLabel(option.Id),
                        Sensitivity = option.Sensitivity,
                        LinkedPaths = option.LinkedPaths
                    })
                    .ToList()
            })
            .ToList();
    }

    private static string GetGroupTitle(string groupId)
    {
        return groupId switch
        {
            "foregroundApp" => Strings.TxGroupForegroundApp,
            "activity" => Strings.TxGroupActivity,
            "media" => Strings.TxGroupMedia,
            "environment" => Strings.TxGroupEnvironment,
            _ => groupId
        };
    }

    private static string GetOptionLabel(string optionId)
    {
        return optionId switch
        {
            "foreground.identity" => Strings.TxUiForegroundIdentity,
            "foreground.titleSummary" => Strings.TxUiForegroundTitleSummary,
            "foreground.rawTitle" => Strings.TxUiForegroundRawTitle,
            "activity.switchRate" => Strings.TxUiActivitySwitchRate,
            "activity.switchBurst" => Strings.TxUiActivitySwitchBurst,
            "media.overview" => Strings.TxUiMediaOverview,
            "media.title" => Strings.TxUiMediaTitle,
            "media.artist" => Strings.TxUiMediaArtist,
            "media.album" => Strings.TxUiMediaAlbum,
            "environment.timezone" => Strings.TxUiEnvironmentTimezone,
            "environment.displays" => Strings.TxUiEnvironmentDisplays,
            _ => optionId
        };
    }
}
