using AmbientContextMcp.Core.Models;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class TransmissionUiCatalogTests
{
    [Fact]
    public void Every_ui_option_links_only_classified_paths()
    {
        var classifications = AmbientContextCatalog.GetPrivacyClassifications()
            .Select(item => item.Path)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        foreach (var group in AmbientContextCatalog.GetTransmissionUiGroups())
        {
            foreach (var option in group.Options)
            {
                Assert.NotEmpty(option.LinkedPaths);
                foreach (var path in option.LinkedPaths)
                {
                    Assert.Contains(path, classifications);
                }
            }
        }
    }

    [Fact]
    public void Flattened_transmission_options_cover_all_ui_linked_paths()
    {
        var uiPaths = AmbientContextCatalog.GetTransmissionUiGroups()
            .SelectMany(group => group.Options)
            .SelectMany(option => option.LinkedPaths)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);
        var flatPaths = AmbientContextCatalog.GetTransmissionOptions()
            .Select(option => option.Path)
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        Assert.Equal(uiPaths, flatPaths);
    }

    [Fact]
    public void Ui_groups_have_expected_structure()
    {
        var groups = AmbientContextCatalog.GetTransmissionUiGroups();

        Assert.Equal(4, groups.Count);
        Assert.Equal(["foregroundApp", "activity", "media", "environment"], groups.Select(group => group.Id));
        Assert.Equal(11, groups.SelectMany(group => group.Options).Count());
        Assert.All(
            groups.SelectMany(group => group.Options),
            option => Assert.False(string.IsNullOrWhiteSpace(option.PrimaryPath)));
    }
}
