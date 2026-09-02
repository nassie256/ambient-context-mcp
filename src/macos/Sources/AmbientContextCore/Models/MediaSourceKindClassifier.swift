import Foundation

/// SMTC の AppUserModelId / bundle id / 実行ファイル名から、メディアセッションの種別を粗く推定する。
/// 戻り値は `"music"` / `"video"` / `"browser"` / `"unknown"` の 4 種類。
/// `"browser"` は Chrome タブ等で実体が音楽か動画か判定できないケース。
/// 値はヒューリスティック (部分文字列マッチ) であり、誤分類はあり得る前提でクライアント側で扱うこと。
public enum MediaSourceKindClassifier {
    public static func classify(_ sourceApp: String?) -> String {
        guard let sourceApp,
              !sourceApp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "unknown"
        }

        let lower = sourceApp.lowercased()

        // 動画特化 (Zune は music/video が別 path で存在するので video を先にチェック)
        if lower.contains("zunevideo") ||
            lower.contains("netflix") ||
            lower.contains("primevideo") ||
            lower.contains("amazon.video") ||
            lower.contains("hulu") ||
            lower.contains("disney") ||
            lower.contains("vlc") ||
            lower.contains("mpv") ||
            lower.contains("mpc") {
            return "video"
        }

        // 音楽特化
        if lower.contains("spotify") ||
            lower.contains("itunes") ||
            lower.contains("applemusic") ||
            lower.contains("amazonmusic") ||
            lower.contains("tidal") ||
            lower.contains("zunemusic") ||
            lower.contains("youtubemusic") {
            return "music"
        }

        // ブラウザ (タブの中身が音楽か動画か判定不能)
        if lower.contains("chrome") ||
            lower.contains("msedge") ||
            lower.contains("firefox") ||
            lower.contains("opera") ||
            lower.contains("vivaldi") ||
            lower.contains("brave") {
            return "browser"
        }

        return "unknown"
    }
}
