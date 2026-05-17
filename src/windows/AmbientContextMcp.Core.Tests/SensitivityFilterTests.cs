using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class SensitivityFilterTests
{
    private static readonly IReadOnlyList<PrivacyClassification> Classifications =
    [
        new() { Path = "events.media_session_changed", Sensitivity = "medium", DefaultTransmit = false },
        new() { Path = "events.media_session_changed.title", Sensitivity = "high", DefaultTransmit = false },
        new() { Path = "events.media_session_changed.artist", Sensitivity = "high", DefaultTransmit = false },
    ];

    [Fact]
    public void LookupPayloadFieldSensitivity_returns_exact_match()
    {
        var result = SensitivityScopeFilter.LookupPayloadFieldSensitivity(
            eventName: "media_session_changed",
            payloadKey: "title",
            classifications: Classifications,
            fallbackSensitivity: "medium");

        Assert.Equal("high", result);
    }

    [Fact]
    public void LookupPayloadFieldSensitivity_falls_back_to_event_level()
    {
        var result = SensitivityScopeFilter.LookupPayloadFieldSensitivity(
            eventName: "media_session_changed",
            payloadKey: "source_app",
            classifications: Classifications,
            fallbackSensitivity: "medium");

        Assert.Equal("medium", result);
    }

    [Fact]
    public void ComputePayloadSensitivity_returns_max_high_when_any_field_is_high()
    {
        var payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "title", "Imagine" },
            { "artist", "John Lennon" },
            { "source_app", "Chrome" }
        };

        var (perKey, max) = SensitivityScopeFilter.ComputePayloadSensitivity(
            eventName: "media_session_changed",
            payload: payload,
            classifications: Classifications,
            eventSensitivity: "medium");

        Assert.Equal("high", perKey["title"]);
        Assert.Equal("high", perKey["artist"]);
        Assert.Equal("medium", perKey["source_app"]);
        Assert.Equal("high", max);
    }

    [Fact]
    public void ComputePayloadSensitivity_returns_event_level_when_all_fields_inherit()
    {
        var payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            { "from", "battery" },
            { "to", "ac" }
        };

        var (perKey, max) = SensitivityScopeFilter.ComputePayloadSensitivity(
            eventName: "ac_power_connected",
            payload: payload,
            classifications: Classifications,
            eventSensitivity: "low");

        Assert.Equal("low", perKey["from"]);
        Assert.Equal("low", perKey["to"]);
        Assert.Equal("low", max);
    }

    [Fact]
    public void FilterEventForScope_keeps_event_drops_high_keys_when_scope_is_medium()
    {
        var ev = new LocalContextEvent
        {
            Id = "evt_x",
            Sequence = 1,
            ObservedAt = DateTimeOffset.UtcNow,
            Name = "media_session_changed",
            Value = "Imagine",
            Payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "title", "Imagine" },
                { "source_app", "Chrome" }
            },
            PayloadSensitivity = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "title", "high" },
                { "source_app", "medium" }
            },
            Sensitivity = "medium",
            MaxFieldSensitivity = "high"
        };

        var filtered = SensitivityScopeFilter.FilterEventForScope(ev, ["context.medium:read"]);

        Assert.NotNull(filtered);
        Assert.False(filtered!.Payload.ContainsKey("title"));
        Assert.True(filtered.Payload.ContainsKey("source_app"));
        Assert.Equal("medium", filtered.MaxFieldSensitivity);
        Assert.Equal("medium", filtered.PayloadSensitivity["source_app"]);
    }

    [Fact]
    public void FilterEventForScope_drops_event_when_event_level_exceeds_scope()
    {
        var ev = new LocalContextEvent
        {
            Id = "evt_x",
            Sequence = 1,
            ObservedAt = DateTimeOffset.UtcNow,
            Name = "media_session_changed",
            Sensitivity = "medium",
            MaxFieldSensitivity = "medium",
            Payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "source_app", "Chrome" }
            },
            PayloadSensitivity = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "source_app", "medium" }
            }
        };

        var filtered = SensitivityScopeFilter.FilterEventForScope(ev, ["context.low:read"]);

        Assert.Null(filtered);
    }

    [Fact]
    public void FilterEventForScope_passes_through_when_payload_sensitivity_is_empty()
    {
        // 古い events.jsonl から復元したケース。PayloadSensitivity が空でも event-level でフィルタが効く。
        var ev = new LocalContextEvent
        {
            Id = "evt_x",
            Sequence = 1,
            ObservedAt = DateTimeOffset.UtcNow,
            Name = "ac_power_connected",
            Sensitivity = "low",
            MaxFieldSensitivity = "",
            Payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
            {
                { "to", "ac" }
            }
        };

        var filtered = SensitivityScopeFilter.FilterEventForScope(ev, ["context.low:read"]);

        Assert.NotNull(filtered);
        Assert.True(filtered!.Payload.ContainsKey("to"));
    }
}

public class HubIngestTests
{
    [Fact]
    public void Ingest_populates_payload_sensitivity_from_classifications()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        var observedAt = DateTimeOffset.UtcNow;

        var snapshot = new AmbientContextSnapshot
        {
            ObservedAt = observedAt,
            PrivacyClassifications =
            [
                new() { Path = "events.media_session_changed", Sensitivity = "medium", DefaultTransmit = false },
                new() { Path = "events.media_session_changed.title", Sensitivity = "high", DefaultTransmit = false }
            ],
            OutboundEvents =
            [
                new()
                {
                    ObservedAt = observedAt,
                    Name = "media_session_changed",
                    Value = "Imagine",
                    Payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                    {
                        { "title", "Imagine" },
                        { "source_app", "Chrome" }
                    },
                    Sensitivity = "medium"
                }
            ]
        };

        hub.Ingest(snapshot);

        var poll = hub.PollEvents(new LocalContextPollRequest
        {
            ClientId = "test",
            Scopes = ["context.high:read"],
            Since = observedAt.AddMinutes(-1)
        });

        var ev = Assert.Single(poll.Events);
        Assert.Equal("high", ev.PayloadSensitivity["title"]);
        Assert.Equal("medium", ev.PayloadSensitivity["source_app"]);
        Assert.Equal("high", ev.MaxFieldSensitivity);
    }

    [Fact]
    public void PollEvents_with_medium_scope_strips_high_payload_keys_but_keeps_event()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        var observedAt = DateTimeOffset.UtcNow;

        hub.Ingest(new AmbientContextSnapshot
        {
            ObservedAt = observedAt,
            PrivacyClassifications =
            [
                new() { Path = "events.media_session_changed", Sensitivity = "medium", DefaultTransmit = false },
                new() { Path = "events.media_session_changed.title", Sensitivity = "high", DefaultTransmit = false }
            ],
            OutboundEvents =
            [
                new()
                {
                    ObservedAt = observedAt,
                    Name = "media_session_changed",
                    Value = "Imagine",
                    Payload = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
                    {
                        { "title", "Imagine" },
                        { "source_app", "Chrome" }
                    },
                    Sensitivity = "medium"
                }
            ]
        });

        var poll = hub.PollEvents(new LocalContextPollRequest
        {
            ClientId = "test",
            Scopes = ["context.medium:read"],
            Since = observedAt.AddMinutes(-1)
        });

        var ev = Assert.Single(poll.Events);
        Assert.False(ev.Payload.ContainsKey("title"));
        Assert.Equal("Chrome", ev.Payload["source_app"]);
        Assert.Equal("medium", ev.MaxFieldSensitivity);
    }
}
