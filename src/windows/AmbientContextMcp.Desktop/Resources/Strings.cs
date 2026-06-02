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

    public static string PersistEventLogCheckbox { get; } = T(
        "イベント履歴をディスクに保存する",
        "Persist event history to disk");

    public static string PersistEventLogNote { get; } = T(
        "再起動後も保持期間内の履歴を保てます。",
        "Keeps history across restarts within the retention window.");

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

    public static string SensitivityLegend { get; } = T(
        "機微度: Low = 公開しても影響が小さい / Medium = 文脈次第で機微になり得る / High = 個人特定や具体的行動を含み得る",
        "Sensitivity: Low = low impact if shared / Medium = context-dependent / High = may identify the user or expose specific behavior");

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

    /// <summary>Format: {0} = exception type, {1} = message.</summary>
    public static string StatusSaveFailedFormat { get; } = T(
        "保存に失敗しました: {0}: {1}",
        "Save failed: {0}: {1}");

    /// <summary>Format: {0} = port number.</summary>
    public static string StatusMcpRunningFormat { get; } = T(
        "起動中 :{0}",
        "Running :{0}");

    // ----- Transmission option groups (SettingsWindow transmission tab) -----
    public static string TxGroupForegroundApp { get; } = T(
        "フォアグラウンドアプリ",
        "Foreground app");

    public static string TxGroupActivity { get; } = T(
        "作業リズム",
        "Work rhythm");

    public static string TxGroupMedia { get; } = T(
        "メディア",
        "Media");

    public static string TxGroupEnvironment { get; } = T(
        "環境",
        "Environment");

    public static string TxUiForegroundIdentity { get; } = T(
        "作業カテゴリ・名前・プロセス名（現在値 + 切替通知）",
        "Work category, name, and process (current value + switch notifications)");

    public static string TxUiForegroundTitleSummary { get; } = T(
        "タイトル要約（現在値 + 変更履歴）",
        "Title summary (current value + change history)");

    public static string TxUiForegroundRawTitle { get; } = T(
        "タイトル原文（現在値 + 変更履歴）",
        "Raw title (current value + change history)");

    public static string TxUiActivitySwitchRate { get; } = T(
        "切替頻度（現在値）",
        "Switch rate (current value)");

    public static string TxUiActivitySwitchBurst { get; } = T(
        "切替急増（通知）",
        "Switch burst (notification)");

    public static string TxUiMediaOverview { get; } = T(
        "再生の有無・状態・再生元（現在値 + 再生通知）",
        "Playback presence, status, and source (current value + playback notifications)");

    public static string TxUiMediaTitle { get; } = T(
        "タイトル（現在値 + 変更履歴）",
        "Title (current value + change history)");

    public static string TxUiMediaArtist { get; } = T(
        "アーティスト（現在値 + 変更履歴）",
        "Artist (current value + change history)");

    public static string TxUiMediaAlbum { get; } = T(
        "アルバム（現在値 + 変更履歴）",
        "Album (current value + change history)");

    public static string TxUiEnvironmentTimezone { get; } = T(
        "タイムゾーン（現在値 + 変更通知）",
        "Time zone (current value + change notifications)");

    public static string TxUiEnvironmentDisplays { get; } = T(
        "ディスプレイ構成（現在値 + 変更通知）",
        "Display layout (current value + change notifications)");

    // ----- Transmission options (legacy per-path labels; kept for reference) -----
    public static string TxOptForegroundCategory { get; } = T(
        "フォアグラウンドアプリの作業カテゴリ",
        "Foreground app work category");

    public static string TxOptForegroundAppName { get; } = T(
        "フォアグラウンドアプリ名",
        "Foreground app name");

    public static string TxOptForegroundProcessName { get; } = T(
        "フォアグラウンドアプリのプロセス名",
        "Foreground app process name");

    public static string TxOptForegroundTitleSummary { get; } = T(
        "フォアグラウンドウィンドウのタイトル要約",
        "Foreground window title summary");

    public static string TxOptForegroundRawWindowTitle { get; } = T(
        "フォアグラウンドウィンドウのタイトル原文",
        "Foreground window raw title");

    public static string TxOptEventForegroundChanged { get; } = T(
        "フォアグラウンドアプリ切替イベント (アプリ名・プロセス名込み)",
        "Foreground app switch event (includes app and process name)");

    public static string TxOptEventForegroundTitleChanged { get; } = T(
        "フォアグラウンドウィンドウのタイトル変更イベント (アプリ文脈込み)",
        "Foreground window title change event (includes app context)");

    public static string TxOptEventForegroundTitleChangedSummary { get; } = T(
        "フォアグラウンドウィンドウのタイトル変更イベント: 要約",
        "Foreground window title change event: summary");

    public static string TxOptEventForegroundTitleChangedRaw { get; } = T(
        "フォアグラウンドウィンドウのタイトル変更イベント: 原文",
        "Foreground window title change event: raw title");

    public static string TxOptActivityContextSwitches { get; } = T(
        "フォアグラウンドアプリ切替頻度",
        "Foreground app switch rate");

    public static string TxOptEventContextSwitchBurst { get; } = T(
        "フォアグラウンドアプリ切替増加イベント",
        "Foreground app switch burst event");

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

    public static string TxOptEventMediaSessionChangedAlbumTitle { get; } = T(
        "メディアセッション変更イベント: アルバム",
        "Media session changed: album");

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
