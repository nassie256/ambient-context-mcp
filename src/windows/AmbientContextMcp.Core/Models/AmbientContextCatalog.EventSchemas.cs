using System.Globalization;

namespace AmbientContextMcp.Core.Models;

/// <summary>
/// ユーザーに見える ambient context イベントの完全リストと payload スキーマ。
/// クライアントは <c>ambient_context_describe_events</c> ツール経由でこの一覧を取得して、
/// 「どんなイベント名が来るか」「payload に何が入るか」「どのキーが高機微か」を事前に把握できる。
///
/// 説明文の言語は <see cref="CultureInfo.CurrentUICulture"/> 起動時の値で決まる。
/// 日本語 OS なら日本語、それ以外は英語 (PrivacyClassifications と同方針)。
///
/// MAINTENANCE: payload キーは <c>WindowsAmbientContextService.Transitions.cs</c> と
/// <c>WindowsAmbientContextService.cs</c> の <c>AddEvent</c> 呼び出し箇所と同期させること。
/// emit 側でキーを追加・改名・削除したら、ここも更新する。drift を機械的に検出する手段はないので
/// 注意。
/// </summary>
public static partial class AmbientContextCatalog
{
    public static IReadOnlyList<EventSchema> GetEventSchemas()
    {
        return
        [
            // Presence / wellness
            Schema("presence_bucket_changed", "low",
                "在席状態 (active / idle / away_short / away_long / locked) が遷移したときに発火。",
                "Fires when the presence bucket transitions (active / idle / away_short / away_long / locked).",
                Key("from", "low", "遷移前の bucket。", "Previous bucket.", "active"),
                Key("to", "low", "遷移後の bucket。", "New bucket.", "idle")),

            Schema("user_returned", "low",
                "離席状態 (idle / away / locked) から active に復帰した瞬間。",
                "Fires when the user returns to active from idle / away / locked.",
                Key("from", "low", "復帰前の bucket。", "Previous bucket.", "idle"),
                Key("to", "low", "通常 \"active\"。", "Typically \"active\".", "active")),

            Schema("user_became_idle", "low",
                "active から idle に遷移した瞬間。割り込み抑制に使える。",
                "Fires when active transitions to idle. Useful for suppressing interruptions.",
                Key("from", "low", "遷移前の bucket。", "Previous bucket.", "active"),
                Key("to", "low", "通常 \"idle\"。", "Typically \"idle\".", "idle")),

            Schema("first_activity_today", "low",
                "ローカルカレンダー日の初回 active 検出時に 1 回だけ発火。再起動を跨いでも 1 日 1 回。Payload なし。",
                "Fires once per local calendar day on the first detection of activity. Persisted across restarts. No payload.",
                Array.Empty<EventPayloadKey>()),

            Schema("long_session_warning", "low",
                "連続 active が 90 分以上経過したことを通知。休憩提案トリガに使える。",
                "Notifies that continuous active time has exceeded 90 minutes. Useful as a break-suggestion trigger.",
                Key("continuous_active_minutes", "low", "連続 active 分数。", "Continuous active minutes.", "92")),

            // Session
            Schema("session_locked", "medium",
                "OS セッションがロックされた瞬間。Payload なし。",
                "Fires when the OS session is locked. No payload.",
                Array.Empty<EventPayloadKey>()),

            Schema("session_unlocked", "medium",
                "OS セッションがアンロックされた瞬間。Payload なし。",
                "Fires when the OS session is unlocked. No payload.",
                Array.Empty<EventPayloadKey>()),

            Schema("session_logon", "medium",
                "OS セッション開始時。Payload なし。",
                "Fires when an OS session starts. No payload.",
                Array.Empty<EventPayloadKey>()),

            Schema("session_logoff", "medium",
                "OS セッション終了時。Payload なし。",
                "Fires when an OS session ends. No payload.",
                Array.Empty<EventPayloadKey>()),

            // Foreground app
            Schema("foreground_changed", "medium",
                "フォアグラウンドアプリの process_name または category が直近 emit と変わった瞬間。category_changed フラグでカテゴリ遷移かどうかを区別できる (旧 foreground_app_category_changed はこのフラグに統合された)。",
                "Fires when the foreground app's process_name or category differs from the last emit. The category_changed flag distinguishes a category transition (replaces the old foreground_app_category_changed event).",
                Key("category", "medium", "新しいフォアグラウンドアプリのカテゴリ (空文字 = 該当データなし)。", "New app's category (empty string when no data).", "code"),
                Key("app_name", "medium", "新しいフォアグラウンドアプリ名 (空文字 = 該当データなし)。", "New app's display name (empty string when no data).", "Visual Studio Code"),
                Key("process_name", "medium", "新しいフォアグラウンドアプリの実行ファイル名。", "New app's executable name.", "Code.exe"),
                Key("category_changed", "medium", "直近 emit のカテゴリと比較して \"true\" / \"false\"。フォアグラウンドアプリは変わったがカテゴリは同じ場合は \"false\"。", "\"true\" / \"false\" relative to the last emit's category. \"false\" when the app changed but stayed within the same category.", "true")),

            Schema("foreground_title_changed", "medium",
                "フォアグラウンドウィンドウのタイトル (原文 / 要約) が直近 emit と変わった瞬間。同一フォアグラウンドアプリ内のタブ/ファイル切替もここで履歴に残る。raw_window_title / titleSummary.* は別 path で個別 opt-in が必要。",
                "Fires when the foreground window title (raw or summary) changes. Tab/file switches within the same app are recorded here. raw_window_title and titleSummary.* require separate opt-in paths.",
                Key("category", "medium", "現在のフォアグラウンドアプリの作業カテゴリ (空文字 = 該当データなし)。", "Current work category (empty string when no data).", "browser"),
                Key("app_name", "medium", "現在のフォアグラウンドアプリ名 (空文字 = 該当データなし)。", "Current app display name (empty string when no data).", "Google Chrome"),
                Key("process_name", "medium", "現在のフォアグラウンドアプリの実行ファイル名。", "Current executable name.", "chrome.exe"),
                Key("titleSummary.has_title", "medium", "タイトルが存在する場合 \"true\"。", "\"true\" when a title is present.", "true"),
                Key("titleSummary.file_ext", "medium", "推定ファイル拡張子 (editor カテゴリ等)。", "Inferred file extension (editor category, etc.).", "cs"),
                Key("titleSummary.known_site", "medium", "既知サイト名 (browser カテゴリ)。", "Known site name (browser category).", "github.com"),
                Key("raw_window_title", "high", "フォアグラウンドウィンドウのタイトル原文。ページ名・ファイル名・DM相手・検索語など。", "Raw window title. Page names, file names, DM partners, search queries, etc.", "Program.cs - MyProject - Visual Studio")),

            // Battery
            Schema("battery_medium", "low",
                "バッテリー残量が medium バケット (20–50%) に下がった瞬間。",
                "Fires when battery level enters the medium bucket (20–50%).",
                Key("percent", "low", "現在の残量パーセント (\"unknown\" の場合あり)。", "Current battery percent (may be \"unknown\").", "47")),

            Schema("battery_low", "low",
                "バッテリー残量が low バケット (10–20%) に下がった瞬間。",
                "Fires when battery level enters the low bucket (10–20%).",
                Key("percent", "low", "現在の残量パーセント。", "Current battery percent.", "18")),

            Schema("battery_critical", "low",
                "バッテリー残量が critical バケット (<10%) に下がった瞬間。",
                "Fires when battery level enters the critical bucket (<10%).",
                Key("percent", "low", "現在の残量パーセント。", "Current battery percent.", "8")),

            Schema("battery_percent_crossed_threshold", "low",
                "残量が 80 / 50 / 30 / 20 % のいずれかを跨いだ瞬間。プロンプトのタイミング信号。",
                "Fires when battery percent crosses one of the 80 / 50 / 30 / 20 thresholds.",
                Key("threshold", "low", "跨いだしきい値。", "The crossed threshold.", "30"),
                Key("direction", "low", "\"up\" or \"down\".", "\"up\" or \"down\".", "down"),
                Key("from", "low", "直前の残量パーセント。", "Previous battery percent.", "31"),
                Key("to", "low", "現在の残量パーセント。", "Current battery percent.", "29")),

            Schema("charger_connected", "low",
                "充電器接続を検出。Payload なし。",
                "Fires when the charger is connected. No payload.",
                Array.Empty<EventPayloadKey>()),

            Schema("charger_disconnected", "low",
                "充電器切断を検出。Payload なし。",
                "Fires when the charger is disconnected. No payload.",
                Array.Empty<EventPayloadKey>()),

            // Power source
            Schema("power_source_changed", "low",
                "AC / battery / short_term 電源モードの遷移。",
                "Fires on AC / battery / short_term power source transitions.",
                Key("from", "low", "遷移前の電源種別 (初回観測時は \"unknown\")。", "Previous power source (\"unknown\" on first observation).", "battery"),
                Key("to", "low", "遷移後の電源種別。", "New power source.", "ac")),

            Schema("ac_power_connected", "low",
                "AC 電源接続を検出。直前の power_source_changed と連動して発火する。",
                "Fires when AC power becomes the source, paired with power_source_changed.",
                Key("from", "low", "遷移前の電源種別 (初回観測時は \"unknown\")。", "Previous power source (\"unknown\" on first observation).", "battery"),
                Key("to", "low", "\"ac\".", "\"ac\".", "ac")),

            Schema("battery_power_active", "low",
                "バッテリー駆動への切替を検出。",
                "Fires when battery becomes the active power source.",
                Key("from", "low", "遷移前の電源種別 (初回観測時は \"unknown\")。", "Previous power source (\"unknown\" on first observation).", "ac"),
                Key("to", "low", "\"battery\".", "\"battery\".", "battery")),

            Schema("short_term_power_active", "low",
                "短期電源 (例: UPS) への切替を検出。",
                "Fires when a short-term power source (e.g. UPS) becomes active.",
                Key("from", "low", "遷移前の電源種別 (初回観測時は \"unknown\")。", "Previous power source (\"unknown\" on first observation).", "ac"),
                Key("to", "low", "\"short_term\".", "\"short_term\".", "short_term")),

            Schema("power_setting_changed", "low",
                "OS の電源設定 (AC/DC source, monitor power, lid switch など) の変化通知。",
                "Notification of an OS power setting change (AC/DC source, monitor power, lid switch, etc).",
                Key("setting", "low", "設定名 (例: ac_dc_power_source, monitor_power_on)。", "Setting name (e.g. ac_dc_power_source, monitor_power_on).", "monitor_power_on"),
                Key("guid", "low", "設定の識別子 (Windows: GUID 表記 / macOS: 設定名)。", "Setting identifier (Windows: GUID / macOS: setting name).", "02731015-4510-4526-99e6-e5a17ebd1aea"),
                Key("value", "low", "整形済みの値 (例: \"on\" / \"off\")。", "Formatted value (e.g. \"on\" / \"off\").", "on"),
                Key("raw_value", "low", "生の整数値。", "Raw integer value.", "1"),
                Key("data_length", "low", "ペイロードのバイト長。", "Payload byte length.", "4")),

            // System
            Schema("system_suspend", "low",
                "スリープ開始を検出。Payload なし。",
                "Fires when the system begins suspending. No payload.",
                Array.Empty<EventPayloadKey>()),

            Schema("system_resume_user", "low",
                "ユーザー操作によるスリープ復帰。Payload なし。",
                "Fires on user-initiated resume from sleep. No payload.",
                Array.Empty<EventPayloadKey>()),

            Schema("system_resume_automatic", "low",
                "自動 (タイマー / Wake-on-LAN 等) によるスリープ復帰。Payload なし。",
                "Fires on automatic resume from sleep (timer, Wake-on-LAN, etc). No payload.",
                Array.Empty<EventPayloadKey>()),

            Schema("system_under_load", "low",
                "CPU / メモリ pressure が high 以上に達したことを通知。",
                "Fires when CPU or memory pressure reaches high or above.",
                Key("cpu_pressure", "low", "CPU 圧迫バケット (例: high / critical)。", "CPU pressure bucket (e.g. high / critical).", "high"),
                Key("memory_pressure", "low", "メモリ圧迫バケット。", "Memory pressure bucket.", "moderate")),

            Schema("context_switch_burst", "medium",
                "短時間にフォアグラウンドアプリ切替が増えたことを通知。作業リズム推測の材料。",
                "Fires when app-switch frequency spikes within a short window. Hints at work rhythm.",
                Key("switches_per_min", "medium", "直近 1 分の切替回数。", "Number of switches in the last minute.", "42")),

            // Media
            Schema("media_session_changed", "medium",
                "OS のメディアセッション情報 (Windows: SMTC / macOS: Music・Spotify) の内容 (曲・動画タイトル等) が変わった瞬間。title / artist は別 path (.title / .artist) で個別に高機微分類されており、ユーザー opt-in と context.high:read scope の両方が必要。",
                "Fires when OS media session details change (Windows: SMTC / macOS: Music, Spotify). title / artist are classified high under separate paths and require both user opt-in and context.high:read scope.",
                Key("source_app", "medium", "再生元アプリの AppUserModelId (例: Spotify, Chrome タブ)。", "AppUserModelId of the source app (e.g. Spotify, a Chrome tab).", "Spotify.exe"),
                Key("source_kind", "medium", "source_app から推定したメディア種別: \"music\" / \"video\" / \"browser\" / \"unknown\"。ブラウザはタブの中身が判定できないため別カテゴリ。ヒューリスティックなので誤分類はあり得る。", "Coarse media kind inferred from source_app: \"music\" / \"video\" / \"browser\" / \"unknown\". Browser is its own category since tab contents can't be inspected. Heuristic — misclassification is possible.", "music"),
                Key("playback_status", "medium", "Playing / Paused / Stopped。", "Playing / Paused / Stopped.", "Playing"),
                Key("title", "high", "曲名 / 動画タイトル。視聴履歴そのもの。", "Track / video title. Reveals listening / viewing history.", "Imagine"),
                Key("artist", "high", "アーティスト / 出演者。", "Artist or performer.", "John Lennon"),
                Key("album_title", "high", "アルバム名。", "Album title.", "Double Fantasy")),

            Schema("media_playback_started", "medium",
                "メディアが Playing 状態に遷移した瞬間。",
                "Fires when media transitions to Playing.",
                Key("from", "medium", "遷移前の PlaybackStatus。", "Previous PlaybackStatus.", "Paused"),
                Key("to", "medium", "\"Playing\".", "\"Playing\".", "Playing")),

            Schema("media_playback_paused", "medium",
                "メディアが Paused 状態に遷移した瞬間。",
                "Fires when media transitions to Paused.",
                Key("from", "medium", "遷移前の PlaybackStatus。", "Previous PlaybackStatus.", "Playing"),
                Key("to", "medium", "\"Paused\".", "\"Paused\".", "Paused")),

            Schema("media_playback_stopped", "medium",
                "メディアが Stopped 状態に遷移した瞬間。",
                "Fires when media transitions to Stopped.",
                Key("from", "medium", "遷移前の PlaybackStatus。", "Previous PlaybackStatus.", "Playing"),
                Key("to", "medium", "\"Stopped\".", "\"Stopped\".", "Stopped")),

            Schema("media_playback_status_changed", "medium",
                "PlaybackStatus が上記 3 状態以外 (例: Buffering) に変化したときの汎用イベント。",
                "Generic event when PlaybackStatus moves to a value other than Playing / Paused / Stopped (e.g. Buffering).",
                Key("from", "medium", "遷移前の PlaybackStatus。", "Previous PlaybackStatus.", "Playing"),
                Key("to", "medium", "遷移後の PlaybackStatus。", "New PlaybackStatus.", "Buffering")),

            // Network / timezone / display
            Schema("network_connectivity_changed", "low",
                "ネットワーク接続の online / offline 遷移。",
                "Fires on network online / offline transition.",
                Key("from", "low", "\"online\" or \"offline\".", "\"online\" or \"offline\".", "offline"),
                Key("to", "low", "\"online\" or \"offline\".", "\"online\" or \"offline\".", "online")),

            Schema("timezone_changed", "medium",
                "タイムゾーン ID が変わった瞬間。移動や PC 設定変更を示唆する。",
                "Fires when the time zone ID changes. Suggests travel or a settings change.",
                Key("from", "medium", "遷移前の IANA / Windows TZ ID。", "Previous IANA / Windows TZ ID.", "Tokyo Standard Time"),
                Key("to", "medium", "遷移後の TZ ID。", "New TZ ID.", "Pacific Standard Time")),

            Schema("display_count_changed", "medium",
                "外部モニターの接続 / 解除でディスプレイ数が変わった瞬間。",
                "Fires when the number of displays changes (external monitor connect / disconnect).",
                Key("from", "medium", "遷移前のディスプレイ数。", "Previous display count.", "1"),
                Key("to", "medium", "遷移後のディスプレイ数。", "New display count.", "2")),
        ];
    }

    private static EventSchema Schema(
        string name,
        string sensitivity,
        string descriptionJa,
        string descriptionEn,
        params EventPayloadKey[] payloadKeys) =>
        new()
        {
            Name = name,
            Sensitivity = sensitivity,
            Description = PickReason(descriptionJa, descriptionEn),
            PayloadKeys = payloadKeys
        };

    private static EventPayloadKey Key(
        string key,
        string sensitivity,
        string descriptionJa,
        string descriptionEn,
        string example) =>
        new()
        {
            Key = key,
            Sensitivity = sensitivity,
            Description = PickReason(descriptionJa, descriptionEn),
            Example = example
        };
}
