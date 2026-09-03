namespace AmbientContextMcp.Core.Models;

/// <summary>
/// SMTC の AppUserModelId / bundle id / 実行ファイル名から、メディアセッションの種別を粗く推定する。
/// 戻り値は <c>"music"</c> / <c>"video"</c> / <c>"browser"</c> / <c>"unknown"</c> の 4 種類。
/// <c>"browser"</c> は Chrome タブ等で実体が音楽か動画か判定できないケース。
/// 値はヒューリスティック (部分文字列マッチ) であり、誤分類はあり得る前提でクライアント側で扱うこと。
/// </summary>
public static class MediaSourceKindClassifier
{
    public static string Classify(string sourceApp)
    {
        if (string.IsNullOrWhiteSpace(sourceApp))
        {
            return "unknown";
        }

        var lower = sourceApp.ToLowerInvariant();

        // 動画特化 (Zune は music/video が別 path で存在するので video を先にチェック)
        if (lower.Contains("zunevideo") ||
            lower.Contains("netflix") ||
            lower.Contains("primevideo") ||
            lower.Contains("amazon.video") ||
            lower.Contains("hulu") ||
            lower.Contains("disney") ||
            lower.Contains("vlc") ||
            lower.Contains("mpv") ||
            lower.Contains("mpc") ||
            lower.Contains("com.apple.tv"))
        {
            return "video";
        }

        // 音楽特化
        if (lower.Contains("spotify") ||
            lower.Contains("itunes") ||
            lower.Contains("applemusic") ||
            lower.Contains("amazonmusic") ||
            lower.Contains("tidal") ||
            lower.Contains("zunemusic") ||
            lower.Contains("youtubemusic") ||
            lower.Contains("com.apple.music") ||
            // Podcasts.app は音声再生専用なので music に寄せる (video/browser のどちらでもない)。
            lower.Contains("com.apple.podcasts"))
        {
            return "music";
        }

        // ブラウザ (タブの中身が音楽か動画か判定不能)
        if (lower.Contains("chrome") ||
            lower.Contains("msedge") ||
            lower.Contains("firefox") ||
            lower.Contains("opera") ||
            lower.Contains("vivaldi") ||
            lower.Contains("brave") ||
            lower.Contains("com.apple.safari") ||
            lower.Contains("com.microsoft.edgemac") ||
            lower.Contains("company.thebrowser.browser"))
        {
            return "browser";
        }

        return "unknown";
    }
}
