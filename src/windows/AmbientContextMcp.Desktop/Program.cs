using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace AmbientContextMcp;

public static class Program
{
    [STAThread]
    public static int Main(string[] args)
    {
        Application.Start(p =>
        {
            var context = new DispatcherQueueSynchronizationContext(
                DispatcherQueue.GetForCurrentThread());
            SynchronizationContext.SetSynchronizationContext(context);
            _ = new App();
        });
        return 0;
    }
}
