using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class ScopeAliasTests
{
    [Fact]
    public void GetStates_with_context_all_returns_all_allowed_states()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        hub.Ingest(new AmbientContextSnapshot
        {
            ObservedAt = DateTimeOffset.UtcNow,
            OutboundStates =
            [
                new() { Name = "presence.bucket", Value = "active", Sensitivity = "low" },
                new() { Name = "foregroundApp.category", Value = "code", Sensitivity = "medium" },
                new() { Name = "media.title", Value = "Imagine", Sensitivity = "high" }
            ]
        });

        var states = hub.GetContextStates(new LocalContextStateRequest
        {
            Scopes = ["context.all:read"]
        });

        Assert.Equal(3, states.States.Count);
    }

    [Fact]
    public void GetStates_with_context_all_equals_high()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        hub.Ingest(new AmbientContextSnapshot
        {
            ObservedAt = DateTimeOffset.UtcNow,
            OutboundStates =
            [
                new() { Name = "presence.bucket", Value = "active", Sensitivity = "low" },
                new() { Name = "media.title", Value = "Imagine", Sensitivity = "high" }
            ]
        });

        var withAll = hub.GetContextStates(new LocalContextStateRequest { Scopes = ["context.all:read"] });
        var withHigh = hub.GetContextStates(new LocalContextStateRequest { Scopes = ["context.high:read"] });

        Assert.Equal(withHigh.States.Count, withAll.States.Count);
    }
}
