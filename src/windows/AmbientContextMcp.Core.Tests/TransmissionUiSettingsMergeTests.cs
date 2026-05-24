using AmbientContextMcp.Core.Models;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class TransmissionUiSettingsMergeTests
{
    [Fact]
    public void MergeOverrides_keeps_shared_parent_path_when_one_media_option_is_enabled()
    {
        var options = AmbientContextCatalog.GetTransmissionUiGroups()
            .SelectMany(group => group.Options)
            .ToList();

        var merged = TransmissionUiSettingsMerge.MergeOverrides(
            new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase),
            options,
            new HashSet<string>(StringComparer.OrdinalIgnoreCase) { "media.overview" });

        Assert.True(merged["events.media_session_changed"]);
        Assert.True(merged["media.isAvailable"]);
        Assert.False(merged.ContainsKey("events.media_session_changed.title"));
    }

    [Fact]
    public void MergeOverrides_unions_paths_from_multiple_enabled_options()
    {
        var options = AmbientContextCatalog.GetTransmissionUiGroups()
            .SelectMany(group => group.Options)
            .ToList();

        var merged = TransmissionUiSettingsMerge.MergeOverrides(
            new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase),
            options,
            new HashSet<string>(StringComparer.OrdinalIgnoreCase)
            {
                "media.overview",
                "media.title"
            });

        Assert.True(merged["events.media_session_changed"]);
        Assert.True(merged["events.media_session_changed.title"]);
        Assert.False(merged.ContainsKey("events.media_session_changed.artist"));
    }

    [Fact]
    public void MergeOverrides_does_not_remove_unmanaged_overrides()
    {
        var options = AmbientContextCatalog.GetTransmissionUiGroups()
            .SelectMany(group => group.Options)
            .ToList();
        var existing = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase)
        {
            ["legacy.custom.path"] = true
        };

        var merged = TransmissionUiSettingsMerge.MergeOverrides(
            existing,
            options,
            new HashSet<string>(StringComparer.OrdinalIgnoreCase));

        Assert.True(merged["legacy.custom.path"]);
    }

    [Fact]
    public void IsOptionEnabled_uses_primary_path_only()
    {
        var options = AmbientContextCatalog.GetTransmissionUiGroups()
            .SelectMany(group => group.Options)
            .ToList();
        var mediaTitle = options.Single(option => option.Id == "media.title");
        var overrides = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase)
        {
            ["events.media_session_changed"] = true
        };

        Assert.False(TransmissionUiSettingsMerge.IsOptionEnabled(mediaTitle, overrides));

        overrides["media.title"] = true;
        Assert.True(TransmissionUiSettingsMerge.IsOptionEnabled(mediaTitle, overrides));
    }

    [Fact]
    public void Every_option_primary_path_is_in_linked_paths()
    {
        foreach (var option in AmbientContextCatalog.GetTransmissionUiGroups()
            .SelectMany(group => group.Options))
        {
            Assert.Contains(
                option.PrimaryPath,
                option.LinkedPaths,
                StringComparer.OrdinalIgnoreCase);
        }
    }
}
