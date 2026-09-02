# macOS ネイティブ移植 設計・実装計画

- 作成日: 2026-09-03
- ステータス: Phase 0 (PoC) 完了、Phase 1 未着手。PoC の生データは `src/macos/poc/0N-*/RESULT.md`
- 対象範囲: `src/macos/` に macOS ネイティブ (Swift / AppKit / SwiftUI) のメニューバー常駐アプリを新設し、Windows 版 (`src/windows/`) と可能な限り同等の機能・MCP 契約を提供する

## 1. 現行 Windows 版の構造 (調査結果)

| レイヤ | プロジェクト | 行数 | プラットフォーム依存 | 内容 |
|---|---|---|---|---|
| Core | `AmbientContextMcp.Core` | 約 2,900 | なし (`net8.0`) | モデル、プライバシー分類カタログ (72 path)、イベントスキーマ (約 30 event)、送信 UI グループ定義、`LocalContextHub` (イベント保持 / cursor / scope フィルタ / JSONL 永続化)、`AmbientTransmissionPolicy`、`JsonFileSettingsStore`、`ContextTools` (MCP 4 ツール)、診断ログ |
| Core.Tests | `AmbientContextMcp.Core.Tests` | 約 1,300 | なし | xunit 51 テスト (契約の回帰保護) |
| Desktop / エンジン | `AmbientContextMcp.Desktop/AmbientContext` | 約 2,000 | **半分は非依存** | `WindowsAmbientContextService.Transitions.cs` (遷移→イベント発火)、`AmbientContextProjector` (states/events 投影・重複抑制)、`AmbientTier1Rules` (bucket 判定・アプリ分類・タイトル要約) は OS 非依存ロジック。`Windows*Collector` 群と `.Native.cs` が Win32 / WinRT 依存 |
| Desktop / シェル | `AmbientContextMcp.Desktop` (その他) | 約 1,800 | WinUI 3 + Win32 | トレイ (`Shell_NotifyIcon`)、設定ウィンドウ (2 タブ)、Kestrel ホスト、認証ミドルウェア、自動起動 (Run キー)、ローカライズ (`Strings.cs` の ja/en ペア) |
| StdioBridge | `AmbientContextMcp.StdioBridge` | 約 360 | ほぼなし | Claude Desktop (MCPB) 用の stdio→HTTP シム。discovery ファイルを読んでトレイ未起動なら spawn |

### 外部契約 (移植で必ず保つもの)

- MCP Streamable HTTP (stateless) `http://127.0.0.1:37690/mcp`、`Authorization: Bearer` または `X-AmbientContextMcp-Token`、Origin は localhost 系のみ許可
- 4 ツール: `ambient_context_get_states` / `poll_events` / `describe_events` / `get_policy` と、その入出力スキーマ・`policyVersion`・cursor セマンティクス ([docs/tool-spec.md](../../tool-spec.md))
- path 単位の機微度分類と既定送信可否 ([docs/privacy-classifications.md](../../privacy-classifications.md))
- 設定ファイル `settings.json` のスキーマ (`mcpServer` / `ambientTransmission.pathTransmitOverrides` / `localContext` / `ui` / `transientState`)
- discovery ファイル `mcp-api.json` (StdioBridge が依存)、`events.jsonl`、`app-diagnostics.jsonl`

## 2. 方針決定

### 2.1 実装言語: Swift (フルネイティブ) を推奨

| 選択肢 | 利点 | 欠点 |
|---|---|---|
| **A. Swift + AppKit/SwiftUI (推奨)** | 真のネイティブ。`NSStatusItem` / `SMAppService` / IOKit / NSWorkspace を直接使える。ランタイム不要、配布サイズ数 MB、Gatekeeper と署名の作法が素直 | Core (約 2,900 行) とエンジン (約 800 行) を Swift に再実装する必要があり、C# 版とのカタログ drift リスクが生じる |
| B. .NET 継続 (`net8.0-macos` + AppKit バインディング) | Core / MCP SDK / テストをそのまま流用できる | .NET for macOS ワークロードは Xcode 必須で扱いが重く、配布物が 70 MB 超の .NET ランタイム同梱になる。「ネイティブアプリ」の要件から遠い。UI は結局 AppKit を C# から呼ぶ形になる |
| C. .NET Core をヘッドレス常駐 + Swift の薄い UI | Core 流用 + ネイティブ UI | 2 ランタイム / 2 プロセスになり「小さいフットプリント」と単一 Hub の原則に反する |

要件が「Mac のネイティブアプリ」であること、`src/macos/.gitkeep` が既に切られていることから A を採る。drift リスクは「契約フィクスチャの CI 比較」(§5) で抑える。

### 2.2 対応 OS / ツールチェーン

- **macOS 14 Sonoma 以降** (Apple Silicon / Intel の Universal)。ユーザー決定。swift-sdk 自体は 13+ で動くが、Swift 6 strict concurrency と `Observation` を前提にするため 14 に固定する
- Universal バイナリは CLT では `swift build --arch arm64 --arch x86_64` が失敗する (xcbuild が無い) ため、`--triple arm64-apple-macosx14.0` と `--triple x86_64-apple-macosx14.0` で 2 回ビルドして `lipo -create` する (PoC 4 で検証済み)
- Swift 6 / SwiftPM。**Xcode プロジェクトは持たず SwiftPM + bundle 組立スクリプト**で `.app` を作る (Command Line Tools だけでビルド可能、CI の `macos-latest` でも同じ手順)。署名は ad-hoc `codesign` (Developer ID 無し、公証なし)
- 現状の開発機は `dotnet` 未導入・Xcode 本体未導入 (CLT のみ)。Swift 6.3 は利用可能

### 2.3 依存パッケージ

| 用途 | パッケージ | 備考 |
|---|---|---|
| MCP プロトコル型 / Server / tools 登録 / **サーバ側 Streamable HTTP** | `modelcontextprotocol/swift-sdk` 0.12.1 (`MCP`) | `StatelessHTTPServerTransport` (`handleRequest(HTTPRequest) -> HTTPResponse`) を同梱。PoC 1 で動作確認済み |
| HTTP リスナ (127.0.0.1 のみ) | `apple/swift-nio` (`NIOCore` / `NIOPosix` / `NIOHTTP1`) | swift-sdk の推移的依存なので追加コストなし。`configureHTTPServerPipeline()` が keep-alive / chunked / `Expect: 100-continue` を処理し、アダプタは約 130 行 |
| それ以外 | 標準フレームワークのみ | AppKit, SwiftUI, IOKit, Network, CoreGraphics, ServiceManagement, ApplicationServices (AX) |

Hummingbird は不要 (PoC 1 の結論)。

## 3. アーキテクチャ

### 3.1 ディレクトリ構成

```
src/macos/
├─ Package.swift
├─ Sources/
│   ├─ AmbientContextCore/          (C# Core の移植: OS 非依存、テスト対象)
│   │   ├─ Models/                  AmbientContextModels, Catalog(+EventSchemas, +TransmissionUi), EventSchema, MediaSourceKindClassifier, TransmissionUiSettingsMerge
│   │   ├─ Hub/                     LocalContextHub, CursorTracker, EventLog, PolicyVersion, SensitivityScopeFilter
│   │   ├─ Policy/                  AmbientTransmissionPolicy
│   │   ├─ Settings/                SettingsStore (JSON, 同一スキーマ)、各 Settings 型
│   │   ├─ Engine/                  ★ Desktop から昇格: Tier1Rules, Projector, TransitionEvaluator (状態機械)
│   │   └─ Diagnostics/             AppDiagnosticLog (JSONL)
│   ├─ AmbientContextMcpServer/     MCP Server 組立、HTTP (Hummingbird)、認証ミドルウェア、discovery ファイル、client snippet
│   ├─ AmbientContextMac/           .app 本体 (executable target "ambient-mcp")
│   │   ├─ App/                     main, AppDelegate (LSUIElement), Lifecycle
│   │   ├─ Collectors/              Presence, ForegroundApp, Battery, Power, Network, SystemLoad, Displays, Media
│   │   ├─ Service/                 MacAmbientContextService (actor)、CaptureScheduler
│   │   ├─ StatusBar/               NSStatusItem + NSMenu
│   │   ├─ Settings/                SwiftUI 設定ウィンドウ (2 タブ)、ViewModel
│   │   ├─ Autostart/               SMAppService ラッパ
│   │   ├─ Permissions/             Accessibility / Automation の状態確認と誘導
│   │   └─ Resources/               メニューバー用テンプレート PNG, AppIcon 用 PNG (iconutil で .icns 化), ja.lproj / en.lproj の Localizable.strings
│   └─ ambient-mcp-stdio/           StdioBridge の Swift 移植 (executable)
├─ Tests/
│   ├─ AmbientContextCoreTests/     xunit 51 テストの移植 + 契約フィクスチャ比較
│   └─ AmbientContextMcpServerTests/ 認証・Origin・stateless 応答のテスト
├─ Fixtures/contract/               C# 版から生成した JSON (分類カタログ / イベントスキーマ / UI グループ)
└─ scripts/
    ├─ build-app.sh                 swift build → .app 組立 (Info.plist, 埋め込み, codesign)
    └─ package-release.sh           zip + dmg + .mcpb
```

### 3.2 プロセス構造とスレッドモデル

Windows 版の 3 スレッド構成を Swift Concurrency に置き換える。

| Windows | macOS |
|---|---|
| WinUI UI スレッド (トレイ、設定、Anchor Window) | メインスレッド (`NSApplication`、`NSStatusItem`、設定ウィンドウ)。`LSUIElement=true` なのでウィンドウが無くても常駐でき、Anchor Window は不要 |
| `MessageOnlyWindow` 専用スレッド (全 OS イベントと capture を直列化) | `actor MacAmbientContextService`。通知 (`NSWorkspace` / `DistributedNotificationCenter` / IOKit run loop source) はメインスレッドで受けて actor に転送。actor が `_last*` 状態と capture を直列化し、`_captureGate` セマフォ相当は actor の再入禁止で代替 |
| Worker (Kestrel + PeriodicTimer 60 秒) | Hummingbird は SwiftNIO EventLoop。60 秒 capture は `Task` + `AsyncTimerSequence` (または `Task.sleep` ループ) から actor を呼ぶ |

通知ブロックから actor へ渡す際、`Notification` / `NSRunningApplication` は Sendable でないため、ブロック内で bundle id / pid / 実行ファイル名などの値に分解してから転送する (PoC 2 でビルドエラーとして確認)。AX と `NSWorkspace` はメインスレッド API なので Collector は `@MainActor` に置く。

Hub (`LocalContextHub`) は Windows 版同様ロック (Swift では actor または `NSLock`) で保護し、`Ingest` は actor から、`GetStates` / `PollEvents` は HTTP ハンドラから呼ぶ。

### 3.3 Windows API → macOS API 対応表

| コンテキスト | Windows | macOS | 差分 / 注意 |
|---|---|---|---|
| アイドル秒数 (presence) | `GetLastInputInfo` | `CGEventSource.secondsSinceLastEventType(.combinedSessionState, kCGAnyInputEventType)` | 権限不要。HID 入力ベースで同等 |
| ロック / アンロック | `WTSRegisterSessionNotification` | `DistributedNotificationCenter` の `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` | 非公式だが長年安定。`session_logon` / `logoff` は `NSWorkspace.sessionDidBecomeActive` / `sessionDidResignActive` (ファストユーザスイッチ) に対応付け |
| フォアグラウンドアプリ | `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` + `GetForegroundWindow` | `NSWorkspace.didActivateApplicationNotification` + `frontmostApplication` (bundle id, localizedName, pid) | アプリ分類は bundle id キー (例 `com.microsoft.VSCode` → editor)。`processName` と `appName` のフォールバックは実行ファイル名 (`localizedName` は OS 言語で「テキストエディット」等になるため使わない)。bundle id は大文字小文字が揺れる (`com.apple.calculator`) ので大文字小文字無視で比較。約 46 件の対応表案は `src/macos/poc/02-ax-title/RESULT.md` §7 |
| ウィンドウタイトル (`rawWindowTitle` / `titleSummary`) | `GetWindowText` | Accessibility API (`AXUIElementCreateApplication` → `kAXFocusedWindowAttribute` → `kAXTitleAttribute`) | **アクセシビリティ権限が必要**。未許可なら `hasWindowTitle=false` + 理由文字列で degrade (PoC 2 で確認)。権限要求は該当 opt-in を ON にした時だけ行う。`AXIsProcessTrustedWithOptions(prompt)` は非ブロッキングで即 false を返すため、許可後は状態をポーリングして degrade を解除する。`AXUIElementSetMessagingTimeout(el, 1.0)` を必ず設定し、応答しないアプリで capture を止めない。`SummarizeWindowTitle` のターミナル判定 (powershell/cmd/wsl) は OS 別辞書に分け、mac は zsh/bash/fish/ssh を持つ |
| バッテリ | `GetSystemPowerStatus` | IOKit `IOPSCopyPowerSourcesInfo` / `IOPSGetProvidingPowerSourceType`、変化は `IOPSNotificationCreateRunLoopSource` | `batterySaver` は `ProcessInfo.isLowPowerModeEnabled` |
| 電源設定通知 (`power.lastKnownSettings.*`) | `RegisterPowerSettingNotification` 8 GUID | 下表のとおり個別に対応 | 同じ setting 名を維持して `power_setting_changed` の payload 互換を保つ |
| サスペンド / レジューム | `WM_POWERBROADCAST` | `NSWorkspace.willSleepNotification` / `didWakeNotification` | `system_resume_automatic` (dark wake) はユーザプロセスに届かないため常に `system_resume_user` を発火。差分として文書化 |
| CPU 使用率 | `GetSystemTimes` | `host_statistics(HOST_CPU_LOAD_INFO)` の差分 | 同じ 2 サンプル差分方式 |
| メモリ使用率 | `GlobalMemoryStatusEx` | `host_statistics64(HOST_VM_INFO64)` から (active+wired+compressed)/total | OS のメモリプレッシャ通知 (`DispatchSource.makeMemoryPressureSource`) を bucket の補正に使える (任意) |
| ディスプレイ構成 | `EnumDisplayMonitors` | `NSScreen.screens` (frame, visibleFrame, localizedName, backingScaleFactor) + `NSApplication.didChangeScreenParametersNotification` | `bitsPerPixel` は `CGDisplayBitsPerPixel` 相当が deprecated のため 32 固定または省略 |
| ネットワーク | `NetworkInterface.GetIsNetworkAvailable` | `NWPathMonitor` | `interfaceKinds` (wifi / wired / cellular) を埋められる (Windows 版は空) |
| メディア (SMTC) | `GlobalSystemMediaTransportControlsSessionManager` | **公開 API なし** (`MediaRemote` は private、macOS 15.4+ で非 Apple プロセスに閉鎖) | §3.4 参照。最大の機能差 |
| タイムゾーン / uptime | `TimeZoneInfo` / `TickCount64` | `TimeZone.current.identifier`、`ProcessInfo.systemUptime`、`NSSystemTimeZoneDidChange` | IANA ID になる (例 `Asia/Tokyo`)。Windows は `Tokyo Standard Time` |
| トレイ | `Shell_NotifyIcon` + `TrackPopupMenu` | `NSStatusItem` (`NSStatusBar.system`) + `NSMenu` | 左クリック=設定、右クリック=メニューは `NSStatusBarButton.sendAction(on: [.leftMouseUp, .rightMouseUp])` で `NSApp.currentEvent` を見て分岐 |
| 設定ウィンドウ | WinUI 3 `Window` + `Pivot` | SwiftUI `TabView` を `NSHostingController` で `NSWindow` に載せる | 位置・サイズ永続化は `setFrameAutosaveName` に任せ、`settingsWindow` セクションは未使用のまま残す |
| クリップボード | `DataPackage` | `NSPasteboard.general` | |
| 自動起動 | `HKCU\...\Run` | `SMAppService.mainApp.register()` / `unregister()`、`status` で現在値 | 「ログイン項目」に表示される。.app バンドルであること必須 |
| ローカライズ | `Strings.cs` (`T(ja,en)`) | `ja.lproj` / `en.lproj` の `Localizable.strings` (ja / en)。カタログ内 `Reason` / `Description` の ja/en ペアは Core にそのまま持ち込み `Locale` で選ぶ | 言語切替は `UserDefaults` の `AppleLanguages` を書いて再起動要求 (現行仕様と同じ) |
| 設定 / ログの場所 | `%LOCALAPPDATA%\AmbientContextMcp\` | `~/Library/Application Support/AmbientContextMcp/` | ファイル名・JSON スキーマは同一 |
| 致命エラー表示 | Win32 `MessageBox` | `NSAlert` | ポート競合時など |

`power.lastKnownSettings` の対応:

| setting 名 (維持) | macOS ソース |
|---|---|
| `ac_dc_power_source` | `IOPSGetProvidingPowerSourceType` (`ac` / `battery`; UPS は `short_term` に写像) |
| `battery_percentage_remaining` | IOPS `kIOPSCurrentCapacityKey` |
| `console_display_state` / `session_display_status` / `monitor_power_on` | `NSWorkspace.screensDidSleep` / `screensDidWake` (`on` / `off`) |
| `lid_switch_state` | IOKit `IOPMrootDomain` の `AppleClamshellState` |
| `power_saving_status` | `isLowPowerModeEnabled` + `NSProcessInfoPowerStateDidChange` |
| `global_user_presence` | アイドル秒数から派生 (`present` / `inactive`) |

### 3.4 メディアコンテキストの扱い

macOS には SMTC 相当の公開 API が無い。段階的に対応する。

1. **Phase 3 の既定 (PoC 3 で動作確認済み)**: Apple Events (`NSAppleScript`) で Music.app と Spotify から player state / 曲名 / アーティスト / アルバム / 位置 / 長さを取得。取れないのは `albumArtist` / `trackNumber` / `genres` / `startTimeMilliseconds` / `timelineLastUpdatedAt`。**オートメーション権限** (`NSAppleEventsUsageDescription`) が必要で、`media.*` の opt-in を ON にした時だけ要求する。`sourceAppUserModelId` には bundle id を入れる
2. 実装ルール (PoC 3 の教訓):
   - `NSRunningApplication.runningApplications(withBundleIdentifier:)` で起動中のプレイヤーだけに問い合わせる (`tell application` は未起動アプリを起動してしまい、Spotify は前回キューを自動再生する)
   - 1500 ms のタイムアウトガードを必ず置く。Spotify 起動直後は 6 プロパティ取得が 20 秒以上ブロックした
   - 単位差: Music の `duration` は秒、Spotify はミリ秒。`player position` は両方秒
   - AppleScript の 2 文字変数名 (`st`, `td`) はプレイヤーの用語と衝突してエラー -2741 になる。長い変数名を使う
   - エラー -1728 (トラック無し) はスクリプト内 `try` で吸収し player state だけ返す。-1743 は権限拒否として理由文字列にする
   - `MediaSourceKindClassifier` に `com.apple.music` / `com.apple.tv` / `com.apple.podcasts` / `com.apple.safari` / `com.microsoft.edgemac` / `company.thebrowser.browser` を追加 (C# 側にも同じ変更とテストを入れる)
3. **権限プロンプトの挙動は未検証**。裸バイナリは起動元ターミナルの権限を継承するため、実 .app での初回プロンプトと拒否時 -1743 は Phase 4 で確認する
4. ブラウザ内再生 (YouTube 等) は取得不可。`media.isAvailable=false` になることを README に明記。`MPNowPlayingInfoCenter` は publish 専用で読み取り不可 (SDK ヘッダで確認)
5. 任意 (Phase 6): `MediaRemote` アダプタ方式 (Apple 署名バイナリ経由) は OS 更新で壊れる前提の experimental フラグとしてのみ検討

### 3.5 MCP サーバ

PoC 1 (`src/macos/poc/01-mcp-http/`) をそのまま Phase 2 の土台にする。

- SwiftNIO `ServerBootstrap` で `127.0.0.1:<port>` (IPv4 のみ) を listen し、NIO の HTTP リクエストを `MCP.HTTPRequest` に変換して `StatelessHTTPServerTransport.handleRequest` に渡す。応答は常に `application/json` (SSE にならない) で、`GET /mcp` は 405 + `Allow: POST`
- **認証は NIO アダプタ側の前段チェック**として実装する (SDK の validator pipeline は JSON-RPC パース後にしか走らず、GET や不正ボディが未認証で応答してしまう上、`{"error":"unauthorized"}` 形式の本文を出せない)。Origin 検査 → 403 `forbidden_origin`、トークン不一致 → 401 `unauthorized` + `WWW-Authenticate: Bearer`。SDK の `OriginValidator.localhost()` は `https://localhost` を拒否し Host ヘッダも検査するため Windows 版と非等価であり、使わない。Host 検査を落とす分 DNS rebinding 防御が一層減る点は、両プラットフォームで揃える論点として残す
- swift-sdk の `Server` は **`start()` の中で既定ハンドラを登録する**ため、`withMethodHandler` は `start()` の後に呼ぶ。既定の `initialize` ハンドラは 2 回目以降を「already initialized」で拒否し stateless と両立しないので、冪等な `Initialize` ハンドラで上書きする (バージョン交渉は自前 2 行)
- `ListTools` / `CallTool` を登録。**tools/list の `inputSchema` は C# 版の出力を JSON フィクスチャとして固定し、テストで一致を検証** (クライアントが引数名 `clientId` / `cursor` / `scopes` 等に依存するため)
- 起動時に `mcp-api.json` を書き、終了時に削除 (StdioBridge 契約)

### 3.6 エンジン (遷移ロジック) の扱い

`WindowsAmbientContextService.Transitions.cs` / `AmbientContextProjector.cs` / `AmbientTier1Rules.cs` は Win32 を含まない純粋ロジックなので、Swift では `AmbientContextCore/Engine` に置き、Collector から受け取った各 Context 値だけで動く `TransitionEvaluator` (状態機械) として切り出す。これにより:

- ユニットテストで「presence が active→idle で `user_became_idle` が出る」「battery 閾値通過」などを OS 無しで検証できる (Windows 版には無いテストが増える)
- Collector 差し替えで OS 差分を局所化できる

`first_activity_today` の日付永続化 (`transientState.lastActivityDate`)、90 分 `long_session_warning`、burst 閾値 12/8 などの定数は同値で移す。

## 4. 実装フェーズ

依存順に並べる。各フェーズは単体で PR にできる粒度。

### Phase 0: 技術検証 (PoC) — 完了 (2026-09-03)

| # | 項目 | 結果 | 詳細 |
|---|---|---|---|
| 1 | stateless Streamable HTTP | **成功**。curl と `claude --mcp-config` で疎通。Hummingbird 不要 | `src/macos/poc/01-mcp-http/RESULT.md` |
| 2 | 最前面アプリ / AX タイトル / アイドル秒数 | 権限不要部分は成功。AX は degrade 経路のみ確認 (裸バイナリには権限を付与できない) | `src/macos/poc/02-ax-title/RESULT.md` |
| 3 | Music / Spotify の Apple Events | **成功**。権限プロンプトは未検証 | `src/macos/poc/03-media/RESULT.md` |
| 4 | SwiftPM のみの .app + NSStatusItem + SMAppService + .lproj | **成功**。Universal は lipo 方式 | `src/macos/poc/04-app-bundle/RESULT.md` |

Phase 4 に持ち越した検証: 実 .app でのアクセシビリティ許可後のタイトル取得、オートメーション権限の初回プロンプトと拒否時挙動。PoC 1 と PoC 4 のコードは Phase 2 / Phase 4 の土台として本体に移し、`src/macos/poc/` は Phase 4 完了時に削除する。

### Phase 1: Core 移植 + 契約テスト

- `AmbientContextCore` に Models / Catalog / Hub / Policy / Settings / Diagnostics を移植。JSON はキャメルケース、`observedAt` は ISO 8601 with offset (C# `DateTimeOffset` 互換)
- xunit 51 テストを Swift Testing に移植
- **契約フィクスチャ**: C# 側に小さなダンプ用テスト (または `dotnet run` スクリプト) を追加し、`GetPrivacyClassifications()` / `GetEventSchemas()` / `GetTransmissionUiGroups()` / `tools/list` を `src/macos/Fixtures/contract/*.json` に出力してコミット。Swift テストで同一性を検証。将来的にはこの JSON を両実装の単一ソースにする案 (§6) がある
- カタログ文言の「Windows SMTC」「Windows セッション」など OS 固有表現は Swift 側で中立化し、C# 側も同じ文言に揃える小 PR を併せて出す (drift を作らないため)

#### Phase 1 結果 (2026-09-03 完了)

- `src/macos/Package.swift` + `AmbientContextCore` + `AmbientContextCoreTests` (Swift Testing 70 テスト / 16 スイート)。C# 側は `ContractFixturesTests.cs` がフィクスチャ 9 件を `src/macos/Fixtures/contract/` に冪等出力する (C# 71 テスト)
- CLT のみの環境では `swift test` が `Testing.framework` を見つけられないため `src/macos/scripts/run-tests.sh` を使う (Xcode がある CI では素の `swift test` で可)
- `tools/list` の `inputSchema` フィクスチャは MCP SDK のリフレクション (`McpServerTool.Create` + `IServiceProviderIsService`) で生成。nullable 引数は `type: ["array","null"]` + `default: null` になる
- C# からの意図的な逸脱 (契約上は同値):
  | 項目 | C# | Swift |
  |---|---|---|
  | 日時の小数桁 | 可変 (末尾 0 を省略) | 常に 3 桁、オフセットは常に `±HH:MM` |
  | 非 ASCII の JSON エスケープ | `\uXXXX` | 生 UTF-8 (値は同一) |
  | 大文字小文字無視の比較 | OrdinalIgnoreCase | `lowercased()` (カタログ path は ASCII のみ) |
  | 診断ログのスレッド情報 | `threadId` + `threadName` | `thread` 1 フィールド |
  | `snapshot.source` | `windows-desktop` | `macos-desktop` |
  | カタログ言語 | `CurrentUICulture` | 明示 `language:` 引数 (既定は `Locale.preferredLanguages`) |
  | `ArgumentException` | 例外 | `ContextToolsError.invalidArgument` (メッセージは同一) |
- カタログ文言の「Windows SMTC」等はフィクスチャ一致のため**そのまま**。中立化は C# 側 PR + フィクスチャ再生成とセットで別途行う

### Phase 2: MCP サーバ + 設定ストア

- `AmbientContextMcpServer`: Hummingbird ホスト、認証ミドルウェア、4 ツール、discovery ファイル、`McpClientSnippets`
- `JsonFileSettingsStore` 移植 (トークン生成は 32 byte → base64url、同じ)
- `curl` と Claude Code で疎通確認

### Phase 3: Collector とエンジン

- `Engine/TransitionEvaluator` 移植 + テスト
- Collector 実装順: Presence → Battery/Power → Network → SystemLoad → Displays → ForegroundApp (AX 含む) → Media (§3.4 の実装ルールに従う)
- `MacAmbientContextService` actor で 60 秒 capture、通知トリガ capture、`ambient-context.json` スナップショット書き出し、Hub への `Ingest`、`SnapshotUpdated` 相当 (pause 中は Ingest しない)
- スナップショットの `source` は `"macos-desktop"`

### Phase 4: アプリシェル

- `NSStatusItem` + メニュー 8 項目 (状態表示 / 設定 / MCP URL コピー / Token コピー / Claude Code 用設定コピー / 一時停止・再開 / 終了)。アイコンはテンプレート画像でダーク・ライト両対応
- 設定ウィンドウ: 「MCP サーバ」タブ (状態、Endpoint、Token、ポート、ログイン時自動起動、イベント履歴永続化、言語) と「送信設定」タブ (全許可チェック、履歴保持時間・件数、グループ別オプション、機微度凡例)。保存時に `ReloadTransmissionPolicy` / `hub.ReloadSettings` / `mcpHost.ReloadSettings` を同順で呼ぶ
- 権限誘導: `rawTitle` / `titleSummary` / `media.*` を ON にした時にシステム設定の該当ペインへ誘導するシートを出す。ここで Phase 0 から持ち越した「実 .app でのアクセシビリティ許可後のタイトル取得」「オートメーション初回プロンプト / 拒否時 -1743」を検証する
- ウィンドウの実装要件 (PoC 4): `isReleasedWhenClosed = false` と `applicationShouldTerminateAfterLastWindowClosed → false` の両方が必要。`NSStatusItem` は AX 上 `menu bar 1` に現れる
- SwiftPM リソースバンドルは `.app/Contents/Resources/` に置き、`Bundle.module` は使わず `Bundle.main.resourceURL` 起点の自前アクセサで読む (生成される `Bundle.module` は .app 直下→開発機の `.build` 絶対パスの順に探すため、開発機でだけ動く罠がある)。`Package.swift` に `defaultLocalization: "en"` が必要
- 自動起動 (`SMAppService`)、ローカライズ (ja / en / システム既定)、`NSAlert` による起動失敗表示

### Phase 5: stdio ブリッジ・配布・CI・ドキュメント

- `ambient-mcp-stdio` を Swift 移植 (discovery 読み取り → 生存確認 → 同梱 `.app` を `open -a` または直接実行で spawn → 20 秒待機 → JSON-RPC 中継、SSE 先頭 data 抽出)
- `mcpb/manifest.json`: `compatibility.platforms` に `darwin` を追加し、`platform_overrides` で `darwin` の `command` を `server/ambient-mcp-stdio` に向ける (1 つの .mcpb に win / mac 両方を同梱)。`server.json` の `packages` も更新
- `scripts/build-app.sh` は PoC 4 のものを昇格 (`--triple` 2 回 + `lipo`、`.app` 組立、`iconutil`、ad-hoc `codesign`。hardened runtime は公証なしでは無益なので既定 OFF)、`scripts/package-release.sh` (zip + dmg + mcpb)
- README の Gatekeeper 手順: quarantine 付きの .app は macOS 15+ で「Apple は検証できませんでした」ダイアログで起動が拒否される。**先に `/Applications` へ移動**してから、システム設定 → プライバシーとセキュリティ の「このまま開く」を押すか `xattr -d -r com.apple.quarantine` を実行する。移動が先である理由は App Translocation (読み取り専用のランダムパスで実行される) により discovery ファイルやログイン項目のパスが壊れるため
- `.github/workflows/release.yml` に `macos-latest` ジョブを追加し、成果物 `ambient-context-mcp-vX.Y.Z-macos-universal.zip` / `.dmg` を同じ Release に載せる。テストは `swift test`
- README (`Platform` バッジ、必要環境、ファイル配置の mac パス)、`docs/client-config.md` (パス)、`docs/macos-implementation.md` (本書 §3 の対応表・権限・既知の制約)

### Phase 6: 同等性検証と後回し項目

- 受け入れチェック (§7) を実施
- 任意: MediaRemote アダプタ、メモリプレッシャ通知の活用、`interfaceKinds` の追加

## 5. drift 対策

Windows 版と macOS 版は別実装になるため、以下を CI で機械的に守る。

1. `Fixtures/contract/*.json` を C# から生成し、Swift テストで比較 (Phase 1)
2. C# 側 CI にもフィクスチャ再生成 → `git diff --exit-code` を追加し、C# の変更で JSON が変わったのに Swift 側を更新していない PR を落とす
3. `docs/tool-spec.md` / `privacy-classifications.md` を両実装共通の仕様書として扱い、OS 固有の記述は `windows-implementation.md` / `macos-implementation.md` に隔離する

## 6. 将来の統合案 (本計画のスコープ外)

カタログ (分類・イベントスキーマ・UI グループ) を `catalog/*.json` に外出しし、C# は埋め込みリソース、Swift はバンドルリソースとして読む単一ソース化。両実装の drift を構造的に無くせるが、Windows 側の変更を伴うため別 PR で検討する。

## 7. 受け入れ条件

1. `claude mcp add ambient-context --transport http http://127.0.0.1:37690/mcp --header "Authorization: Bearer <TOKEN>"` で接続でき、4 ツールが Windows 版と同じスキーマで列挙される
2. `get_states` の既定 (low のみ) 応答に `presence.bucket` / `battery.*` / `network.isAvailable` / `system.*` / `wellness.*` / `power.lastKnownSettings.*` が含まれる
3. 送信設定でオプションを ON にすると対応 path が `get_policy.effectivePolicies` で `effectiveTransmit=true` になり、`policyVersion` が変わる
4. `poll_events` の subscription / history query / cursorExpired / `includePayload=false` の各挙動が Windows 版と同じ
5. トレイ (メニューバー) の左クリックで設定、右クリックでメニュー、8 項目すべて動作
6. ログイン時自動起動の ON/OFF がシステム設定「ログイン項目」に反映される
7. 言語 ja / en / システム既定の切替が再起動後に反映される
8. `events.jsonl` 永続化 ON/OFF の遷移 (OFF→ON で同期、ON→OFF で削除) が同じ
9. アクセシビリティ / オートメーション権限が未許可でもクラッシュせず、該当項目が空で返る
10. Claude Desktop に `.mcpb` をインストールすると、未起動時にメニューバーアプリが spawn され、ツールが応答する
11. `swift test` で移植テストと契約フィクスチャ比較が全パス

## 8. 既知の機能差 (ユーザ向けに明記するもの)

| 項目 | Windows | macOS |
|---|---|---|
| メディアセッション | 全 SMTC 対応アプリ (ブラウザ含む) | Music.app / Spotify のみ (Apple Events、要オートメーション権限)。ブラウザ再生は不可 |
| ウィンドウタイトル | 権限不要 | 要アクセシビリティ権限 |
| `system_resume_automatic` | 発火する | 発火しない (常に `system_resume_user`) |
| `system.timeZoneId` の値 | Windows 名 (`Tokyo Standard Time`) | IANA 名 (`Asia/Tokyo`) |
| `foregroundApp.processName` | `code.exe` | `Code` (拡張子なし)。分類は bundle id |
| `network.interfaceKinds` | 常に空 | wifi / wired / cellular を返せる |
| メディアの `albumArtist` / `trackNumber` / `genres` | 取得可 | 取得不可 (空 / 0) |
| 未署名配布 | SmartScreen 警告 | Gatekeeper でブロック (macOS 15+ は右クリック→開く も不可)。`/Applications` へ移動後に「このまま開く」または quarantine 属性の削除が必要 |

## 9. 決定事項 (2026-09-03 ユーザー確認済み)

| 項目 | 決定 |
|---|---|
| 最小 OS | macOS 14 Sonoma 以上 |
| HTTP 実装 | Hummingbird 2 (Phase 0 で不成立なら自前 NWListener に切替) |
| Apple Developer Program | 無し。ad-hoc 署名 (`codesign -s -`) で出荷し、README に `xattr -d com.apple.quarantine` の手順を記載。公証ジョブは CI に組み込まない |
| MCPB の形態 | win / mac 同梱の 1 ファイル (`platform_overrides` で `darwin` の `command` を切替) |
| 設定ウィンドウ | SwiftUI (`NSHostingController`) |
| Xcode | 必須にしない。ビルド・テスト・CI は SwiftPM + Command Line Tools で完結させる (§10) |

## 10. Xcode の要否

本計画のビルド経路 (`swift build` / `swift test` / `codesign` / bundle 組立スクリプト) は Command Line Tools だけで動く。Xcode 本体が無いと使えないものと、その回避策は次のとおり。

| Xcode でしか使えないもの | 本計画での回避策 |
|---|---|
| `actool` (Asset Catalog コンパイル) | AppIcon は `iconutil` (OS 標準) で `.icns` を生成し Info.plist で指定。メニューバーアイコンは PNG/PDF のテンプレート画像を `NSImage` で直接読む |
| String Catalog (`.xcstrings`) のコンパイル | `ja.lproj` / `en.lproj` の `Localizable.strings` を SwiftPM リソースとして使う (§3.1 の記述を置換) |
| `xcodebuild` / Xcode プロジェクト | 使わない。CI (`macos-latest`) も SwiftPM のみ |
| `swift build --arch arm64 --arch x86_64` (Universal 一発ビルド、内部で xcbuild を使う) | `--triple` 別に 2 回ビルドして `lipo -create` (PoC 4 で検証済み) |
| Interface Builder / SwiftUI プレビュー | 設定画面は 2 タブの小規模 UI なので実行して確認する |

Xcode を入れると得られるもの (任意):

- **Instruments**: 常駐プロセスのメモリ・CPU・wake-up 回数のプロファイリング。60 秒 capture と通知トリガの負荷を確認するのに有用
- **Accessibility Inspector**: Phase 0 のウィンドウタイトル取得 (AX) の PoC で、対象アプリの AX ツリーと属性を目視できる
- **デバッガ / SwiftUI プレビュー**: 開発体験の向上のみで、成果物には影響しない

結論: 入れなくても計画は完遂できる。Instruments と Accessibility Inspector が欲しくなった時点で入れればよい (約 15 GB、ディスクとダウンロード時間が主なコスト)。
