using AmbientContextMcp.Core.Hub;
using AmbientContextMcp.Core.Models;
using Xunit;

namespace AmbientContextMcp.Core.Tests;

public class PolicyVersionTests
{
    [Fact]
    public void Same_policy_produces_same_version()
    {
        var classifications = new List<PrivacyClassification>
        {
            new() { Path = "media.title", Sensitivity = "high", DefaultTransmit = false }
        };
        var overrides = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase)
        {
            { "media.title", true }
        };

        var a = PolicyVersionService.ComputePolicyVersion(classifications, overrides);
        var b = PolicyVersionService.ComputePolicyVersion(classifications, overrides);

        Assert.False(string.IsNullOrEmpty(a));
        Assert.Equal(a, b);
    }

    [Fact]
    public void Changing_override_changes_version()
    {
        var classifications = new List<PrivacyClassification>
        {
            new() { Path = "media.title", Sensitivity = "high", DefaultTransmit = false }
        };

        var beforeOverrides = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        var afterOverrides = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase)
        {
            { "media.title", true }
        };

        var before = PolicyVersionService.ComputePolicyVersion(classifications, beforeOverrides);
        var after = PolicyVersionService.ComputePolicyVersion(classifications, afterOverrides);

        Assert.NotEqual(before, after);
    }

    [Fact]
    public void Override_order_does_not_affect_version()
    {
        var classifications = new List<PrivacyClassification>
        {
            new() { Path = "media.title", Sensitivity = "high", DefaultTransmit = false }
        };
        var ordered1 = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase)
        {
            { "media.title", true },
            { "media.artist", true }
        };
        var ordered2 = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase)
        {
            { "media.artist", true },
            { "media.title", true }
        };

        Assert.Equal(
            PolicyVersionService.ComputePolicyVersion(classifications, ordered1),
            PolicyVersionService.ComputePolicyVersion(classifications, ordered2));
    }

    [Fact]
    public void Hub_exposes_policy_version_via_state_and_poll_responses()
    {
        var hub = LocalContextHubTestFactory.CreateInMemory();
        hub.Ingest(new AmbientContextSnapshot
        {
            ObservedAt = DateTimeOffset.UtcNow,
            PrivacyClassifications =
            [
                new() { Path = "media.title", Sensitivity = "high", DefaultTransmit = false }
            ]
        });

        var state = hub.GetContextStates(new LocalContextStateRequest());
        var poll = hub.PollEvents(new LocalContextPollRequest { ClientId = "test" });

        Assert.False(string.IsNullOrEmpty(state.PolicyVersion));
        Assert.Equal(state.PolicyVersion, poll.PolicyVersion);
    }
}
