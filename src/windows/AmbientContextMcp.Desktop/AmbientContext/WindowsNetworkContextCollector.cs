using System.Net.NetworkInformation;
using AmbientContextMcp.Core.Models;

namespace AmbientContextMcp.AmbientContext;

public static class WindowsNetworkContextCollector
{
    public static NetworkContext GetNetwork()
    {
        return new NetworkContext
        {
            IsAvailable = NetworkInterface.GetIsNetworkAvailable()
        };
    }
}
