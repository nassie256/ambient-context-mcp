using AmbientContextMcp.Bootstrap;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace AmbientContextMcp;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        if (!RuntimeBootstrap.TryInitialize(out var error))
        {
            RuntimeBootstrap.ShowMissingRuntimeMessage(error ?? "Unknown error");
            return 1;
        }

        try
        {
            Application.Start(p =>
            {
                var context = new DispatcherQueueSynchronizationContext(
                    DispatcherQueue.GetForCurrentThread());
                SynchronizationContext.SetSynchronizationContext(context);
                _ = new App();
            });
        }
        finally
        {
            RuntimeBootstrap.Shutdown();
        }
        return 0;
    }
}
