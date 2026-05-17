using Clipboard = System.Windows.Clipboard;

namespace AmbientContextMcp.Settings;

public static class ClipboardHelper
{
    public static void SafeCopy(string value)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            return;
        }

        try
        {
            Clipboard.SetText(value);
        }
        catch
        {
            // Best effort.
        }
    }
}
