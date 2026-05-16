using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class EventSchemaCatalogTests
{
    [Fact]
    public void Catalog_contains_core_event_names()
    {
        var all = EventSchemaCatalog.GetAll();
        var names = all.Select(s => s.Name).ToHashSet(StringComparer.OrdinalIgnoreCase);

        Assert.Contains("foreground_changed", names);
        Assert.Contains("media_session_changed", names);
        Assert.Contains("first_activity_today", names);
        Assert.Contains("session_locked", names);
        Assert.Contains("battery_low", names);
        Assert.Contains("power_source_changed", names);
    }

    [Fact]
    public void Schema_names_are_unique()
    {
        var all = EventSchemaCatalog.GetAll();
        var names = all.Select(s => s.Name).ToList();
        var distinct = names.Distinct(StringComparer.OrdinalIgnoreCase).ToList();

        Assert.Equal(distinct.Count, names.Count);
    }

    [Fact]
    public void Media_session_changed_marks_title_and_artist_as_high()
    {
        var schema = EventSchemaCatalog.GetAll()
            .Single(s => s.Name == "media_session_changed");

        Assert.Equal("medium", schema.Sensitivity);

        var title = schema.PayloadKeys.Single(p => p.Key == "title");
        var artist = schema.PayloadKeys.Single(p => p.Key == "artist");
        Assert.Equal("high", title.Sensitivity);
        Assert.Equal("high", artist.Sensitivity);
    }

    [Fact]
    public void Every_schema_has_non_empty_description()
    {
        var all = EventSchemaCatalog.GetAll();

        foreach (var schema in all)
        {
            Assert.False(string.IsNullOrWhiteSpace(schema.Description),
                $"Event {schema.Name} has no description");
        }
    }

    [Fact]
    public void Every_payload_key_has_non_empty_description()
    {
        var all = EventSchemaCatalog.GetAll();

        foreach (var schema in all)
        {
            foreach (var key in schema.PayloadKeys)
            {
                Assert.False(string.IsNullOrWhiteSpace(key.Description),
                    $"Event {schema.Name} key {key.Key} has no description");
            }
        }
    }

    [Fact]
    public void GetEventSchemas_via_hub_returns_catalog()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();

        var response = hub.GetEventSchemas();

        Assert.Equal("eventSchemaCatalog", response.Source);
        Assert.NotEmpty(response.Events);
    }
}
