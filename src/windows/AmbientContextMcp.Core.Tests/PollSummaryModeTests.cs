using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class PollSummaryModeTests
{
    [Fact]
    public void Default_poll_request_includes_payload()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        var observedAt = DateTimeOffset.UtcNow;

        hub.Ingest(BuildSingleEventSnapshot(observedAt));

        var poll = hub.PollEvents(new LocalContextPollRequest
        {
            ClientId = "test",
            Scopes = ["context.high:read"],
            Since = observedAt.AddMinutes(-1)
        });

        var ev = Assert.Single(poll.Events);
        Assert.Equal("Imagine", ev.Payload["title"]);
        Assert.Equal("Chrome", ev.Payload["source_app"]);
    }

    [Fact]
    public void Summary_mode_strips_payload_and_payload_sensitivity()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        var observedAt = DateTimeOffset.UtcNow;

        hub.Ingest(BuildSingleEventSnapshot(observedAt));

        var poll = hub.PollEvents(new LocalContextPollRequest
        {
            ClientId = "test",
            Scopes = ["context.high:read"],
            Since = observedAt.AddMinutes(-1),
            IncludePayload = false
        });

        var ev = Assert.Single(poll.Events);
        Assert.Empty(ev.Payload);
        Assert.Empty(ev.PayloadSensitivity);
    }

    [Fact]
    public void Summary_mode_preserves_top_level_metadata()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        var observedAt = DateTimeOffset.UtcNow;

        hub.Ingest(BuildSingleEventSnapshot(observedAt));

        var poll = hub.PollEvents(new LocalContextPollRequest
        {
            ClientId = "test",
            Scopes = ["context.high:read"],
            Since = observedAt.AddMinutes(-1),
            IncludePayload = false
        });

        var ev = Assert.Single(poll.Events);
        Assert.False(string.IsNullOrEmpty(ev.Id));
        Assert.Equal("media_session_changed", ev.Name);
        Assert.Equal("Imagine", ev.Value);
        Assert.Equal("medium", ev.Sensitivity);
        Assert.Equal("high", ev.MaxFieldSensitivity);
    }

    private static AmbientContextSnapshot BuildSingleEventSnapshot(DateTimeOffset observedAt) =>
        new()
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
}
