using AmbientContextMcp.Core.Models;

namespace AmbientContextMcp.AmbientContext;

public sealed partial class WindowsAmbientContextService
{
    /// <summary>
    /// 設定ダイアログなど UI 側で classification 一覧を参照するための公開ラッパ。
    /// </summary>
    public static IReadOnlyList<PrivacyClassification> GetPrivacyClassificationsForUi()
    {
        return AmbientContextCatalog.GetPrivacyClassifications();
    }
}
