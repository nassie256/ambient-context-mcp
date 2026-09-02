import Foundation

/// ユーザーに見える ambient context イベントの完全リストと payload スキーマ。
/// クライアントは `ambient_context_describe_events` ツール経由でこの一覧を取得して、
/// 「どんなイベント名が来るか」「payload に何が入るか」「どのキーが高機微か」を事前に把握できる。
///
/// 説明文の言語は `language` 引数で決まる (既定は OS の優先言語)。日本語なら日本語、それ以外は英語。
///
/// MAINTENANCE: payload キーはイベント発火側 (Engine / Collector) の `addEvent` 呼び出しと
/// 同期させること。drift を機械的に検出する手段はないので注意。
extension AmbientContextCatalog {
    private static func schema(
        _ name: String,
        _ sensitivity: String,
        _ descriptionJa: String,
        _ descriptionEn: String,
        _ language: String,
        _ payloadKeys: [EventPayloadKey] = []
    ) -> EventSchema {
        EventSchema(
            name: name,
            sensitivity: sensitivity,
            description: pickReason(descriptionJa, descriptionEn, language),
            payloadKeys: payloadKeys)
    }

    private static func key(
        _ key: String,
        _ sensitivity: String,
        _ descriptionJa: String,
        _ descriptionEn: String,
        _ example: String,
        _ language: String
    ) -> EventPayloadKey {
        EventPayloadKey(
            key: key,
            sensitivity: sensitivity,
            description: pickReason(descriptionJa, descriptionEn, language),
            example: example)
    }

    public static func getEventSchemas(
        language: String = AmbientContextCatalog.defaultLanguage
    ) -> [EventSchema] {
        let l = language
        return [
            // Presence / wellness
            schema("presence_bucket_changed", "low",
                "在席状態 (active / idle / away_short / away_long / locked) が遷移したときに発火。",
                "Fires when the presence bucket transitions (active / idle / away_short / away_long / locked).", l, [
                    key("from", "low", "遷移前の bucket。", "Previous bucket.", "active", l),
                    key("to", "low", "遷移後の bucket。", "New bucket.", "idle", l)
                ]),

            schema("user_returned", "low",
                "離席状態 (idle / away / locked) から active に復帰した瞬間。",
                "Fires when the user returns to active from idle / away / locked.", l, [
                    key("from", "low", "復帰前の bucket。", "Previous bucket.", "idle", l),
                    key("to", "low", "通常 \"active\"。", "Typically \"active\".", "active", l)
                ]),

            schema("user_became_idle", "low",
                "active から idle に遷移した瞬間。割り込み抑制に使える。",
                "Fires when active transitions to idle. Useful for suppressing interruptions.", l, [
                    key("from", "low", "遷移前の bucket。", "Previous bucket.", "active", l),
                    key("to", "low", "通常 \"idle\"。", "Typically \"idle\".", "idle", l)
                ]),

            schema("first_activity_today", "low",
                "ローカルカレンダー日の初回 active 検出時に 1 回だけ発火。再起動を跨いでも 1 日 1 回。Payload なし。",
                "Fires once per local calendar day on the first detection of activity. Persisted across restarts. No payload.", l),

            schema("long_session_warning", "low",
                "連続 active が 90 分以上経過したことを通知。休憩提案トリガに使える。",
                "Notifies that continuous active time has exceeded 90 minutes. Useful as a break-suggestion trigger.", l, [
                    key("continuous_active_minutes", "low", "連続 active 分数。", "Continuous active minutes.", "92", l)
                ]),

            // Session
            schema("session_locked", "medium",
                "Windows セッションがロックされた瞬間。Payload なし。",
                "Fires when the Windows session is locked. No payload.", l),

            schema("session_unlocked", "medium",
                "Windows セッションがアンロックされた瞬間。Payload なし。",
                "Fires when the Windows session is unlocked. No payload.", l),

            schema("session_logon", "medium",
                "OS セッション開始時。Payload なし。",
                "Fires when an OS session starts. No payload.", l),

            schema("session_logoff", "medium",
                "OS セッション終了時。Payload なし。",
                "Fires when an OS session ends. No payload.", l),

            // Foreground app
            schema("foreground_changed", "medium",
                "フォアグラウンドアプリの process_name または category が直近 emit と変わった瞬間。category_changed フラグでカテゴリ遷移かどうかを区別できる (旧 foreground_app_category_changed はこのフラグに統合された)。",
                "Fires when the foreground app's process_name or category differs from the last emit. The category_changed flag distinguishes a category transition (replaces the old foreground_app_category_changed event).", l, [
                    key("category", "medium", "新しいフォアグラウンドアプリのカテゴリ (空文字 = 該当データなし)。", "New app's category (empty string when no data).", "code", l),
                    key("app_name", "medium", "新しいフォアグラウンドアプリ名 (空文字 = 該当データなし)。", "New app's display name (empty string when no data).", "Visual Studio Code", l),
                    key("process_name", "medium", "新しいフォアグラウンドアプリの実行ファイル名。", "New app's executable name.", "Code.exe", l),
                    key("category_changed", "medium", "直近 emit のカテゴリと比較して \"true\" / \"false\"。フォアグラウンドアプリは変わったがカテゴリは同じ場合は \"false\"。", "\"true\" / \"false\" relative to the last emit's category. \"false\" when the app changed but stayed within the same category.", "true", l)
                ]),

            schema("foreground_title_changed", "medium",
                "フォアグラウンドウィンドウのタイトル (原文 / 要約) が直近 emit と変わった瞬間。同一フォアグラウンドアプリ内のタブ/ファイル切替もここで履歴に残る。raw_window_title / titleSummary.* は別 path で個別 opt-in が必要。",
                "Fires when the foreground window title (raw or summary) changes. Tab/file switches within the same app are recorded here. raw_window_title and titleSummary.* require separate opt-in paths.", l, [
                    key("category", "medium", "現在のフォアグラウンドアプリの作業カテゴリ (空文字 = 該当データなし)。", "Current work category (empty string when no data).", "browser", l),
                    key("app_name", "medium", "現在のフォアグラウンドアプリ名 (空文字 = 該当データなし)。", "Current app display name (empty string when no data).", "Google Chrome", l),
                    key("process_name", "medium", "現在のフォアグラウンドアプリの実行ファイル名。", "Current executable name.", "chrome.exe", l),
                    key("titleSummary.has_title", "medium", "タイトルが存在する場合 \"true\"。", "\"true\" when a title is present.", "true", l),
                    key("titleSummary.file_ext", "medium", "推定ファイル拡張子 (editor カテゴリ等)。", "Inferred file extension (editor category, etc.).", "cs", l),
                    key("titleSummary.known_site", "medium", "既知サイト名 (browser カテゴリ)。", "Known site name (browser category).", "github.com", l),
                    key("raw_window_title", "high", "フォアグラウンドウィンドウのタイトル原文。ページ名・ファイル名・DM相手・検索語など。", "Raw window title. Page names, file names, DM partners, search queries, etc.", "Program.cs - MyProject - Visual Studio", l)
                ]),

            // Battery
            schema("battery_medium", "low",
                "バッテリー残量が medium バケット (20–50%) に下がった瞬間。",
                "Fires when battery level enters the medium bucket (20–50%).", l, [
                    key("percent", "low", "現在の残量パーセント (\"unknown\" の場合あり)。", "Current battery percent (may be \"unknown\").", "47", l)
                ]),

            schema("battery_low", "low",
                "バッテリー残量が low バケット (10–20%) に下がった瞬間。",
                "Fires when battery level enters the low bucket (10–20%).", l, [
                    key("percent", "low", "現在の残量パーセント。", "Current battery percent.", "18", l)
                ]),

            schema("battery_critical", "low",
                "バッテリー残量が critical バケット (<10%) に下がった瞬間。",
                "Fires when battery level enters the critical bucket (<10%).", l, [
                    key("percent", "low", "現在の残量パーセント。", "Current battery percent.", "8", l)
                ]),

            schema("battery_percent_crossed_threshold", "low",
                "残量が 80 / 50 / 30 / 20 % のいずれかを跨いだ瞬間。プロンプトのタイミング信号。",
                "Fires when battery percent crosses one of the 80 / 50 / 30 / 20 thresholds.", l, [
                    key("threshold", "low", "跨いだしきい値。", "The crossed threshold.", "30", l),
                    key("direction", "low", "\"up\" or \"down\".", "\"up\" or \"down\".", "down", l),
                    key("from", "low", "直前の残量パーセント。", "Previous battery percent.", "31", l),
                    key("to", "low", "現在の残量パーセント。", "Current battery percent.", "29", l)
                ]),

            schema("charger_connected", "low",
                "充電器接続を検出。Payload なし。",
                "Fires when the charger is connected. No payload.", l),

            schema("charger_disconnected", "low",
                "充電器切断を検出。Payload なし。",
                "Fires when the charger is disconnected. No payload.", l),

            // Power source
            schema("power_source_changed", "low",
                "AC / battery / short_term 電源モードの遷移。",
                "Fires on AC / battery / short_term power source transitions.", l, [
                    key("from", "low", "遷移前の電源種別 (初回観測時は \"unknown\")。", "Previous power source (\"unknown\" on first observation).", "battery", l),
                    key("to", "low", "遷移後の電源種別。", "New power source.", "ac", l)
                ]),

            schema("ac_power_connected", "low",
                "AC 電源接続を検出。直前の power_source_changed と連動して発火する。",
                "Fires when AC power becomes the source, paired with power_source_changed.", l, [
                    key("from", "low", "遷移前の電源種別 (初回観測時は \"unknown\")。", "Previous power source (\"unknown\" on first observation).", "battery", l),
                    key("to", "low", "\"ac\".", "\"ac\".", "ac", l)
                ]),

            schema("battery_power_active", "low",
                "バッテリー駆動への切替を検出。",
                "Fires when battery becomes the active power source.", l, [
                    key("from", "low", "遷移前の電源種別 (初回観測時は \"unknown\")。", "Previous power source (\"unknown\" on first observation).", "ac", l),
                    key("to", "low", "\"battery\".", "\"battery\".", "battery", l)
                ]),

            schema("short_term_power_active", "low",
                "短期電源 (例: UPS) への切替を検出。",
                "Fires when a short-term power source (e.g. UPS) becomes active.", l, [
                    key("from", "low", "遷移前の電源種別 (初回観測時は \"unknown\")。", "Previous power source (\"unknown\" on first observation).", "ac", l),
                    key("to", "low", "\"short_term\".", "\"short_term\".", "short_term", l)
                ]),

            schema("power_setting_changed", "low",
                "Windows power setting (AC/DC source, monitor power, lid switch など) の変化通知。",
                "Notification of a Windows power setting change (AC/DC source, monitor power, lid switch, etc).", l, [
                    key("setting", "low", "設定名 (例: ac_dc_power_source, monitor_power_on)。", "Setting name (e.g. ac_dc_power_source, monitor_power_on).", "monitor_power_on", l),
                    key("guid", "low", "Windows GUID 表記。", "Windows GUID.", "02731015-4510-4526-99e6-e5a17ebd1aea", l),
                    key("value", "low", "整形済みの値 (例: \"on\" / \"off\")。", "Formatted value (e.g. \"on\" / \"off\").", "on", l),
                    key("raw_value", "low", "生の整数値。", "Raw integer value.", "1", l),
                    key("data_length", "low", "ペイロードのバイト長。", "Payload byte length.", "4", l)
                ]),

            // System
            schema("system_suspend", "low",
                "スリープ開始を検出。Payload なし。",
                "Fires when the system begins suspending. No payload.", l),

            schema("system_resume_user", "low",
                "ユーザー操作によるスリープ復帰。Payload なし。",
                "Fires on user-initiated resume from sleep. No payload.", l),

            schema("system_resume_automatic", "low",
                "自動 (タイマー / Wake-on-LAN 等) によるスリープ復帰。Payload なし。",
                "Fires on automatic resume from sleep (timer, Wake-on-LAN, etc). No payload.", l),

            schema("system_under_load", "low",
                "CPU / メモリ pressure が high 以上に達したことを通知。",
                "Fires when CPU or memory pressure reaches high or above.", l, [
                    key("cpu_pressure", "low", "CPU 圧迫バケット (例: high / critical)。", "CPU pressure bucket (e.g. high / critical).", "high", l),
                    key("memory_pressure", "low", "メモリ圧迫バケット。", "Memory pressure bucket.", "moderate", l)
                ]),

            schema("context_switch_burst", "medium",
                "短時間にフォアグラウンドアプリ切替が増えたことを通知。作業リズム推測の材料。",
                "Fires when app-switch frequency spikes within a short window. Hints at work rhythm.", l, [
                    key("switches_per_min", "medium", "直近 1 分の切替回数。", "Number of switches in the last minute.", "42", l)
                ]),

            // Media
            schema("media_session_changed", "medium",
                "Windows SMTC のメディアセッション情報 (曲・動画タイトル等) が変わった瞬間。title / artist は別 path (.title / .artist) で個別に高機微分類されており、ユーザー opt-in と context.high:read scope の両方が必要。",
                "Fires when SMTC media session details change. title / artist are classified high under separate paths and require both user opt-in and context.high:read scope.", l, [
                    key("source_app", "medium", "再生元アプリの AppUserModelId (例: Spotify, Chrome タブ)。", "AppUserModelId of the source app (e.g. Spotify, a Chrome tab).", "Spotify.exe", l),
                    key("source_kind", "medium", "source_app から推定したメディア種別: \"music\" / \"video\" / \"browser\" / \"unknown\"。ブラウザはタブの中身が判定できないため別カテゴリ。ヒューリスティックなので誤分類はあり得る。", "Coarse media kind inferred from source_app: \"music\" / \"video\" / \"browser\" / \"unknown\". Browser is its own category since tab contents can't be inspected. Heuristic — misclassification is possible.", "music", l),
                    key("playback_status", "medium", "Playing / Paused / Stopped。", "Playing / Paused / Stopped.", "Playing", l),
                    key("title", "high", "曲名 / 動画タイトル。視聴履歴そのもの。", "Track / video title. Reveals listening / viewing history.", "Imagine", l),
                    key("artist", "high", "アーティスト / 出演者。", "Artist or performer.", "John Lennon", l),
                    key("album_title", "high", "アルバム名。", "Album title.", "Double Fantasy", l)
                ]),

            schema("media_playback_started", "medium",
                "メディアが Playing 状態に遷移した瞬間。",
                "Fires when media transitions to Playing.", l, [
                    key("from", "medium", "遷移前の PlaybackStatus。", "Previous PlaybackStatus.", "Paused", l),
                    key("to", "medium", "\"Playing\".", "\"Playing\".", "Playing", l)
                ]),

            schema("media_playback_paused", "medium",
                "メディアが Paused 状態に遷移した瞬間。",
                "Fires when media transitions to Paused.", l, [
                    key("from", "medium", "遷移前の PlaybackStatus。", "Previous PlaybackStatus.", "Playing", l),
                    key("to", "medium", "\"Paused\".", "\"Paused\".", "Paused", l)
                ]),

            schema("media_playback_stopped", "medium",
                "メディアが Stopped 状態に遷移した瞬間。",
                "Fires when media transitions to Stopped.", l, [
                    key("from", "medium", "遷移前の PlaybackStatus。", "Previous PlaybackStatus.", "Playing", l),
                    key("to", "medium", "\"Stopped\".", "\"Stopped\".", "Stopped", l)
                ]),

            schema("media_playback_status_changed", "medium",
                "PlaybackStatus が上記 3 状態以外 (例: Buffering) に変化したときの汎用イベント。",
                "Generic event when PlaybackStatus moves to a value other than Playing / Paused / Stopped (e.g. Buffering).", l, [
                    key("from", "medium", "遷移前の PlaybackStatus。", "Previous PlaybackStatus.", "Playing", l),
                    key("to", "medium", "遷移後の PlaybackStatus。", "New PlaybackStatus.", "Buffering", l)
                ]),

            // Network / timezone / display
            schema("network_connectivity_changed", "low",
                "ネットワーク接続の online / offline 遷移。",
                "Fires on network online / offline transition.", l, [
                    key("from", "low", "\"online\" or \"offline\".", "\"online\" or \"offline\".", "offline", l),
                    key("to", "low", "\"online\" or \"offline\".", "\"online\" or \"offline\".", "online", l)
                ]),

            schema("timezone_changed", "medium",
                "タイムゾーン ID が変わった瞬間。移動や PC 設定変更を示唆する。",
                "Fires when the time zone ID changes. Suggests travel or a settings change.", l, [
                    key("from", "medium", "遷移前の IANA / Windows TZ ID。", "Previous IANA / Windows TZ ID.", "Tokyo Standard Time", l),
                    key("to", "medium", "遷移後の TZ ID。", "New TZ ID.", "Pacific Standard Time", l)
                ]),

            schema("display_count_changed", "medium",
                "外部モニターの接続 / 解除でディスプレイ数が変わった瞬間。",
                "Fires when the number of displays changes (external monitor connect / disconnect).", l, [
                    key("from", "medium", "遷移前のディスプレイ数。", "Previous display count.", "1", l),
                    key("to", "medium", "遷移後のディスプレイ数。", "New display count.", "2", l)
                ])
        ]
    }
}
