using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class StateMetadataTests
{
    [Fact]
    public void GetContextStates_omits_metadata_when_requested()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        var observedAt = DateTimeOffset.UtcNow;

        hub.Ingest(new AmbientContextSnapshot
        {
            ObservedAt = observedAt,
            OutboundStates =
            [
                new()
                {
                    ObservedAt = observedAt,
                    Name = "battery.bucket",
                    Value = "ok",
                    Sensitivity = "low"
                }
            ]
        });

        var response = hub.GetContextStates(new LocalContextStateRequest
        {
            IncludeMetadata = false
        });

        var state = Assert.Single(response.States);
        Assert.Equal("battery.bucket", state.Name);
        Assert.Equal("ok", state.Value);
        Assert.Null(state.ObservedAt);
        Assert.Null(state.Sensitivity);
    }
}
