# プライバシー分類と既定送信可否

Ambient Context MCP は OS から取得したコンテキストを path 単位で機微度分類し、外部送信可否を制御します。

## 設計原則

- **既定 ON: 機微度 `low` の項目のみ**
- **既定 OFF: 機微度 `medium` / `high` の項目はすべて opt-in 必須**
- **未分類 path はフォールバックで OFF** (送信抑制側に倒す)
- ユーザーが設定ダイアログで明示的に許可した path は scope に関わらず送信される
- scope はユーザー送信ポリシーを上書きしない (絞り込みのみ)

## 既定 ON (機微度 low、初期状態で MCP に送信される)

### Presence
| Path | 説明 |
|---|---|
| `presence.bucket` | active/idle/away_short/away_long/locked の粗い在席状態 |
| `events.presence_bucket_changed` | 在席状態の遷移 |
| `events.user_returned` | 復帰検知 |
| `events.user_became_idle` | アイドル化検知 |

### Battery / Power
| Path | 説明 |
|---|---|
| `battery.bucket` | charging/ok/medium/low/critical |
| `battery.percent` | 0-100 |
| `battery.charging` | true/false |
| `events.battery_percent_crossed_threshold` | 80/50/30/20% 通過 |
| `events.battery_medium` / `_low` / `_critical` | 残量低下 |
| `events.charger_connected` / `_disconnected` | 充電開始/停止 |
| `power.lastKnownSettings.*` | AC/DC、画面状態、節電状態 |
| `events.power_setting_changed` | 電源設定変化 |
| `events.power_source_changed` | 電源ソース遷移 |
| `events.ac_power_connected` | AC 接続 |
| `events.battery_power_active` | バッテリー駆動へ |
| `events.short_term_power_active` | 短期電源 |
| `events.system_suspend` | スリープ開始 |
| `events.system_resume_user` | ユーザー復帰 |
| `events.system_resume_automatic` | 自動復帰 |

### Network
| Path | 説明 |
|---|---|
| `network.isAvailable` | オンライン/オフライン判定のみ |
| `events.network_connectivity_changed` | 接続状態変化 |

### System / Wellness
| Path | 説明 |
|---|---|
| `system.uptimeSeconds` | OS 起動からの経過秒 |
| `system.cpuPressureBucket` | low/moderate/high/critical |
| `system.memoryPressureBucket` | low/moderate/high/critical |
| `wellness.continuousActiveMinutes` | 連続稼働分 |
| `wellness.minutesSinceLastBreak` | 休憩後経過分 |
| `events.system_under_load` | 負荷高検知 |
| `events.long_session_warning` | 90分以上連続稼働 |
| `events.first_activity_today` | 当日最初の活動 |

## 既定 OFF (medium、設定ダイアログで opt-in)

| Path | 機微度 | 理由 |
|---|---|---|
| `presence.idleSeconds` | medium | 細かい作業リズムの推測材料 |
| `presence.sessionLocked` | medium | 離席/復帰の推測 |
| `events.session_locked` / `_unlocked` / `_logon` / `_logoff` | medium | OS セッション遷移 |
| `foregroundApp.category` | medium | フォアグラウンドアプリの作業種別推定。行動履歴 |
| `foregroundApp.appName` | medium | フォアグラウンドアプリ名 |
| `foregroundApp.processName` | medium | フォアグラウンドアプリの環境情報 |
| `foregroundApp.titleSummary.*` | medium | フォアグラウンドウィンドウのタイトル要約 (サイト名/拡張子から作業推測) |
| `events.foreground_app_category_changed` | medium | **[廃止]** `events.foreground_changed` の `category_changed` フラグに統合。発火しない |
| `events.foreground_changed` | medium | フォアグラウンドアプリ切替。payload: `category` / `app_name` / `process_name` / `category_changed` |
| `events.foreground_title_changed` | medium | フォアグラウンドウィンドウのタイトル変更 (要約/原文は別 path) |
| `events.foreground_title_changed.titleSummary` | medium | フォアグラウンドウィンドウのタイトル要約 (payload key 単位 opt-in) |
| `activity.contextSwitchesPerMin` | medium | フォアグラウンドアプリ切替頻度 |
| `events.context_switch_burst` | medium | フォアグラウンドアプリ切替の急増 |
| `media.isAvailable` | medium | メディア再生有無 |
| `media.playbackStatus` | medium | 再生中状態 |
| `media.sourceAppUserModelId` | medium | 再生元アプリ |
| `media.positionMilliseconds` | medium | 視聴行動 |
| `events.media_playback_started` / `_paused` / `_stopped` / `_status_changed` | medium | 再生イベント |
| `events.media_session_changed` | medium | 曲が変わった瞬間のタイミング信号 (payload の title/artist は別 path で個別 opt-in) |
| `system.timeZoneId` | medium | 地域推定 |
| `display.count` | medium | 外部ディスプレイ有無 |
| `displays` | medium | 構成情報 |
| `events.timezone_changed` | medium | 移動の推測 |
| `events.display_count_changed` | medium | モニター接続/解除 |

## 既定 OFF (high、嗜好/閲覧内容そのもの)

| Path | 機微度 | 理由 |
|---|---|---|
| `foregroundApp.rawWindowTitle` | high | フォアグラウンドウィンドウのタイトル原文 (ページ名・ファイル名・DM相手・検索語) |
| `media.title` | high | 曲名・動画名・配信タイトル |
| `media.artist` | high | 嗜好情報 |
| `media.albumTitle` | high | 嗜好情報 |
| `media.sessions` | high | 複数アプリのタイトル |
| `events.media_session_changed.title` | high | 曲名・動画名・配信タイトル (payload key 単位 opt-in) |
| `events.media_session_changed.artist` | high | アーティスト/出演者 (payload key 単位 opt-in) |
| `events.foreground_title_changed.raw_window_title` | high | フォアグラウンドウィンドウのタイトル原文 (payload key 単位 opt-in) |
