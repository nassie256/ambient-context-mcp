namespace AmbientContextMcp.Win32;

/// <summary>
/// Routes async continuations back to the <see cref="MessageOnlyWindow"/>
/// thread via <see cref="MessageOnlyWindow.PostCallback"/>. Installed on the
/// window thread so <c>await</c> in code that started on that thread resumes
/// there — analogous to WPF's <c>DispatcherSynchronizationContext</c>. This
/// keeps the "internal state is only mutated on the window thread" invariant
/// intact even after awaiting WinRT APIs.
/// </summary>
internal sealed class MessageWindowSynchronizationContext : SynchronizationContext
{
    private readonly MessageOnlyWindow _window;

    public MessageWindowSynchronizationContext(MessageOnlyWindow window)
    {
        _window = window ?? throw new ArgumentNullException(nameof(window));
    }

    public override void Post(SendOrPostCallback d, object? state)
    {
        ArgumentNullException.ThrowIfNull(d);
        _window.PostCallback(() => d(state));
    }

    public override void Send(SendOrPostCallback d, object? state)
    {
        throw new NotSupportedException(
            "Synchronous Send is not supported on the message-window context to avoid deadlocks.");
    }

    public override SynchronizationContext CreateCopy() => this;
}
