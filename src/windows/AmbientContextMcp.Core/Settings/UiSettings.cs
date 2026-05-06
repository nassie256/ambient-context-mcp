namespace AmbientContextMcp.Core.Settings;

public sealed class UiSettings
{
    public int SchemaVersion { get; init; } = 1;

    /// <summary>
    /// "" / null = OS UI culture を継承。"ja" / "en" = 明示指定。
    /// 起動時に <c>Thread.CurrentThread.CurrentUICulture</c> へ反映され、resx と
    /// <see cref="AmbientContextMcp.Core.Models.PrivacyClassification.Reason"/> の言語が決まる。
    /// </summary>
    public string Language { get; init; } = "";
}
