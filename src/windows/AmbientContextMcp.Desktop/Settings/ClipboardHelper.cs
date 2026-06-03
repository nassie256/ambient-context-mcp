namespace AmbientContextMcp.Settings;

public static class ClipboardHelper
{
    public static void SafeCopy(string value)
    {
        if (string.IsNullOrWhiteSpace(value)) return;
        try
        {
            var dp = new Windows.ApplicationModel.DataTransfer.DataPackage();
            dp.SetText(value);
            Windows.ApplicationModel.DataTransfer.Clipboard.SetContent(dp);
        }
        catch
        {
            // クリップボードが他プロセスにロックされている場合は best-effort で諦める。
        }
    }
}
