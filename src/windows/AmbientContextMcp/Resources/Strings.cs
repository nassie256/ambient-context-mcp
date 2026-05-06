using System.Globalization;

namespace AmbientContextMcp.Resources;

/// <summary>
/// UI 表示文字列を culture 別に持つ静的リソース。アプリ起動時の
/// <see cref="CultureInfo.CurrentUICulture"/> を 1 度だけ参照し、以降は固定。
/// 言語切替にはアプリ再起動が必要 (XAML の <c>x:Static</c> バインドは parse 時に
/// 確定するため)。.resx を使わないのは、Designer.cs 生成が VS / dotnet 双方で
/// 安定して動く保証を避け、CI / dotnet build だけで完結させるため。
/// </summary>
public static class Strings
{
    // 日本語環境のみ日本語、それ以外は全部英語にフォールバックする方針。
    // 英語環境はもちろん、ドイツ語/中国語/韓国語など第三言語の OS でも、
    // 日本語より英語の方が読める可能性が高いという前提。
    // 明示的に "ja" を選ぶには Settings → Display language で UiSettings.Language = "ja"。
    private static readonly bool IsJapanese = string.Equals(
        CultureInfo.CurrentUICulture.TwoLetterISOLanguageName,
        "ja",
        StringComparison.OrdinalIgnoreCase);

    private static string T(string ja, string en) => IsJapanese ? ja : en;

    // ----- SettingsWindow.xaml -----
    public static string WindowTitle { get; } = T(
        "Ambient Context MCP 設定",
        "Ambient Context MCP — Settings");

    public static string TabMcpServer { get; } = T(
        "MCPサーバ",
        "MCP Server");

    public static string McpServerGroup { get; } = T(
        "MCP サーバ",
        "MCP Server");

    public static string LabelStatus { get; } = T(
        "状態",
        "Status");

    public static string LabelEndpoint { get; } = T(
        "Endpoint",
        "Endpoint");

    public static string LabelToken { get; } = T(
        "Token",
        "Token");

    public static string LabelPort { get; } = T(
        "ポート",
        "Port");

    public static string ButtonCopy { get; } = T(
        "コピー",
        "Copy");

    public static string PortChangeNote { get; } = T(
        "変更はアプリ再起動後に反映",
        "Changes apply after restart");

    public static string AutoStartCheckbox { get; } = T(
        "Windows ログイン時に自動起動",
        "Start automatically on Windows login");

    public static string CopyClaudeCodeSnippet { get; } = T(
        "Claude Code 用設定スニペットをコピー",
        "Copy Claude Code config snippet");

    public static string TabTransmission { get; } = T(
        "送信設定",
        "Transmission");

    public static string TransmissionExplanation { get; } = T(
        "MCPクライアントへ公開してよいコンテキストにチェックを入れてください。未チェックの項目は、クライアントが高い権限を要求しても送信されません。",
        "Check the contexts you allow MCP clients to read. Unchecked items are never transmitted, even if a client requests a higher scope.");

    public static string AllowAllCheckbox { get; } = T(
        "すべてのコンテキストを許可する",
        "Allow every context");

    public static string EventHistoryGroup { get; } = T(
        "イベント履歴",
        "Event history");

    public static string LabelRetention { get; } = T(
        "保持期間",
        "Retention");

    public static string LabelMaxCount { get; } = T(
        "最大件数",
        "Max events");

    public static string Retention1Hour { get; } = T(
        "1時間",
        "1 hour");

    public static string Retention6Hours { get; } = T(
        "6時間",
        "6 hours");

    public static string Retention24Hours { get; } = T(
        "24時間",
        "24 hours");

    public static string Retention7Days { get; } = T(
        "7日",
        "7 days");

    public static string Count100 { get; } = T(
        "100件",
        "100");

    public static string Count500 { get; } = T(
        "500件",
        "500");

    public static string Count1000 { get; } = T(
        "1000件",
        "1,000");

    public static string Count5000 { get; } = T(
        "5000件",
        "5,000");

    public static string ButtonSave { get; } = T(
        "保存",
        "Save");

    public static string ButtonClose { get; } = T(
        "閉じる",
        "Close");

    // ----- Language picker -----
    public static string LabelLanguage { get; } = T(
        "表示言語",
        "Display language");

    public static string LanguageSystemDefault { get; } = T(
        "システムに従う",
        "System default");

    public static string LanguageJapanese { get; } = T(
        "日本語",
        "Japanese (日本語)");

    public static string LanguageEnglish { get; } = T(
        "English",
        "English");

    // ----- Status messages (SettingsWindow.xaml.cs) -----
    public static string StatusSaved { get; } = T(
        "保存しました。送信設定は次回の文脈更新から反映されます。ポート変更はアプリ再起動後に有効になります。",
        "Saved. Transmission settings take effect at the next context refresh. Port changes apply after restart.");

    public static string StatusSavedNeedsRestart { get; } = T(
        "保存しました。言語とポートの変更はアプリ再起動後に反映されます。",
        "Saved. Language and port changes take effect after restart.");

    public static string StatusClaudeCodeCopied { get; } = T(
        "Claude Code 用のコマンドをクリップボードにコピーしました。",
        "Copied the Claude Code command to the clipboard.");

    /// <summary>Format: {0} = port number.</summary>
    public static string StatusMcpRunningFormat { get; } = T(
        "起動中 :{0}",
        "Running :{0}");

    // ----- Transmission options (SettingsWindow.xaml.cs CreateTransmissionOptions) -----
    public static string TxOptForegroundCategory { get; } = T(
        "作業カテゴリ",
        "Work category");

    public static string TxOptForegroundAppName { get; } = T(
        "アプリ名",
        "App name");

    public static string TxOptForegroundProcessName { get; } = T(
        "プロセス名",
        "Process name");

    public static string TxOptForegroundTitleSummary { get; } = T(
        "ウィンドウタイトル要約",
        "Window title summary");

    public static string TxOptForegroundRawWindowTitle { get; } = T(
        "ウィンドウタイトル原文",
        "Raw window title");

    public static string TxOptEventForegroundCategoryChanged { get; } = T(
        "作業カテゴリの遷移イベント",
        "Work category transition event");

    public static string TxOptActivityContextSwitches { get; } = T(
        "アプリ切替頻度",
        "App switch rate");

    public static string TxOptEventContextSwitchBurst { get; } = T(
        "アプリ切替増加イベント",
        "App switch burst event");

    public static string TxOptMediaIsAvailable { get; } = T(
        "メディアセッション有無",
        "Media session presence");

    public static string TxOptMediaPlaybackStatus { get; } = T(
        "メディア再生状態",
        "Media playback status");

    public static string TxOptMediaSourceApp { get; } = T(
        "メディア再生元アプリ",
        "Media source app");

    public static string TxOptMediaTitle { get; } = T(
        "メディアタイトル",
        "Media title");

    public static string TxOptMediaArtist { get; } = T(
        "メディアアーティスト",
        "Media artist");

    public static string TxOptMediaAlbumTitle { get; } = T(
        "メディアアルバム",
        "Media album");

    public static string TxOptEventMediaPlaybackStarted { get; } = T(
        "メディア再生開始イベント",
        "Media playback started event");

    public static string TxOptEventMediaPlaybackPaused { get; } = T(
        "メディア一時停止イベント",
        "Media playback paused event");

    public static string TxOptEventMediaSessionChanged { get; } = T(
        "メディアセッション変更イベント",
        "Media session changed event");

    public static string TxOptEventMediaSessionChangedTitle { get; } = T(
        "メディアセッション変更イベント: タイトル",
        "Media session changed: title");

    public static string TxOptEventMediaSessionChangedArtist { get; } = T(
        "メディアセッション変更イベント: アーティスト",
        "Media session changed: artist");

    public static string TxOptSystemTimeZone { get; } = T(
        "タイムゾーン",
        "Time zone");

    public static string TxOptDisplayCount { get; } = T(
        "ディスプレイ数",
        "Display count");

    public static string TxOptDisplays { get; } = T(
        "ディスプレイ構成",
        "Display layout");

    // ----- Tray (TrayHost.cs) -----
    public static string TraySettings { get; } = T(
        "設定...",
        "Settings...");

    public static string TrayCopyMcpUrl { get; } = T(
        "MCP URL をコピー",
        "Copy MCP URL");

    public static string TrayCopyMcpToken { get; } = T(
        "MCP トークンをコピー",
        "Copy MCP token");

    public static string TrayCopyClaudeCodeSnippet { get; } = T(
        "Claude Code 用設定をコピー",
        "Copy Claude Code config");

    public static string TrayPause { get; } = T(
        "一時停止",
        "Pause");

    public static string TrayResume { get; } = T(
        "再開",
        "Resume");

    public static string TrayPausedSuffix { get; } = T(
        " (一時停止中)",
        " (paused)");

    public static string TrayExit { get; } = T(
        "終了",
        "Exit");

    // ----- Program.cs startup error -----
    /// <summary>Format: {0} = exception type/message, {1} = port number.</summary>
    public static string StartupErrorFormat { get; } = T(
        "Ambient Context MCP の起動に失敗しました。\n\n{0}\n\nポート {1} が他プロセスで使用中の可能性があります。\n%LOCALAPPDATA%\\AmbientContextMcp\\settings.json の mcpServer.port を変更するか、同ファイルを削除して再起動してください。",
        "Ambient Context MCP failed to start.\n\n{0}\n\nPort {1} may be in use by another process. Edit mcpServer.port in %LOCALAPPDATA%\\AmbientContextMcp\\settings.json, or delete the file and restart.");
}
