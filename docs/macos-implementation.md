# macOS 実装メモ

macOS ネイティブ版 (`src/macos/`) の実装をまとめる。設計・移植計画の全体は
[docs/superpowers/specs/2026-09-03-macos-port-design.md](superpowers/specs/2026-09-03-macos-port-design.md) を参照。
OS 非依存の契約 (ツール仕様・プライバシー分類) は [tool-spec.md](tool-spec.md) /
[privacy-classifications.md](privacy-classifications.md) が単一の仕様書で、本書は macOS 固有の差分だけを扱う。

## UI スタック / 配布形態

- **言語 / フレームワーク**: Swift 6 (strict concurrency, language mode v6) + AppKit / SwiftUI。Windows 版 (.NET 8 + WinUI 3) とは別実装で、契約は共通フィクスチャで担保する (後述)。
- **常駐形態**: `LSUIElement = true` の accessory アプリ。Dock にもアプリメニューにも出ず、`NSStatusItem` (メニューバー) だけを持つ。WinUI 3 版で必要だった Anchor Window は不要。
- **UI**: メニューバーは `NSStatusItem` + `NSMenu`、設定ウィンドウは SwiftUI の `TabView` を `NSHostingController` 経由で `NSWindow` に載せる (2 タブ: MCP サーバ / 送信設定)。
- **ターゲット**: macOS 14 Sonoma 以降、Universal (arm64 + x86_64)。ランタイムの追加インストールは不要。
- **ビルド**: SwiftPM のみ。**Xcode プロジェクトは持たない**。Command Line Tools だけで `swift build` / `swift test` / `.app` 組立 / 署名まで完結する。
- **依存パッケージ**: `modelcontextprotocol/swift-sdk` (exact 0.12.1) と、その推移的依存である `apple/swift-nio`。それ以外は標準フレームワークのみ。

## 構成

```
src/macos/
├─ Package.swift
├─ Sources/
│   ├─ AmbientContextCore/        OS 非依存 (Models / Catalog / Hub / Policy / Settings / Engine / Diagnostics)
│   ├─ AmbientContextMcpServer/   MCP Server 組立、SwiftNIO HTTP、認証、discovery ファイル
│   ├─ AmbientContextMac/         .app 本体 (App / Collectors / Service / StatusBar / Settings / Permissions / Resources)
│   ├─ ambient-mcp-stdio/         Claude Desktop (MCPB) 用 stdio→HTTP ブリッジ
│   └─ ambient-mcp-dev/           手動疎通用の開発 CLI (配布物には含めない)
├─ Tests/                         Swift Testing (Core / McpServer)
├─ Fixtures/contract/             C# 版から生成した契約 JSON (Swift テストが同一性を検証)
├─ Resources/AppIcon-1024.png     AppIcon の元画像 (build 時に sips + iconutil で .icns 化)
└─ scripts/
    ├─ run-tests.sh               swift test のラッパ (CLT 環境の Testing.framework 対策)
    ├─ make-app-icon.swift        AppIcon-1024.png を描き直すとき用 (通常ビルドでは不要)
    ├─ build-app.sh               swift build → .app 組立 → 署名 → 検証
    ├─ package-release.sh         build-app.sh → zip + dmg
    └─ assemble-mcpb.sh           win / mac の server ペイロードを 1 つの .mcpb に合成
```

## プロセス構造とスレッドモデル

Windows 版の 3 スレッド構成 (WinUI UI / message-only window / Worker) を Swift Concurrency に置き換えている。

| Windows | macOS |
|---|---|
| WinUI UI スレッド (トレイ、設定ウィンドウ、Anchor Window) | メインスレッド (`NSApplication` / `NSStatusItem` / 設定ウィンドウ)。`LSUIElement` なのでウィンドウが無くても常駐できる |
| `MessageOnlyWindow` 専用スレッド (OS イベントと capture を直列化) | `actor MacAmbientContextService`。`_last*` 状態と capture を直列化し、Windows 版の `_captureGate` セマフォは actor の再入不可性で代替する |
| Worker (Kestrel + `PeriodicTimer` 60 秒) | SwiftNIO の EventLoop (HTTP) と、`Task.sleep` ループの 60 秒キャプチャ (`CaptureScheduler`) |

注意点:

- `Notification` / `NSRunningApplication` は `Sendable` ではない。通知ブロックの中で bundle id / pid / 実行ファイル名などの**値に分解してから** actor へ渡す。
- Accessibility API と `NSWorkspace` はメインスレッド API なので、該当 Collector は `@MainActor` に置く。
- Hub (`LocalContextHub`) はロックで保護し、`ingest` は actor から、`getStates` / `pollEvents` は HTTP ハンドラから呼ぶ。

## MCP サーバ

- SwiftNIO `ServerBootstrap` で `127.0.0.1:<port>` (IPv4 のみ) を listen し、NIO の HTTP リクエストを swift-sdk の `StatelessHTTPServerTransport.handleRequest` に渡す。応答は常に `application/json` (SSE にしない)。
- **認証と Origin 検査は NIO アダプタ側の前段**で行う。SDK の validator は JSON-RPC のパース後にしか走らず、`GET` や不正ボディが未認証で応答してしまうため。Origin 不一致 → 403 `forbidden_origin`、トークン不一致 → 401 `unauthorized` + `WWW-Authenticate: Bearer`。
- `GET /mcp` は未認証なら 401 が先、認証済みなら 405 + `Allow: POST`。`/mcp` 配下以外は認証なしで 404。
- トークンは毎リクエスト読み直すので、再生成が即反映される。ポート変更はリスナ再起動 (= アプリ再起動) が必要で、これは Windows 版と同じ挙動。
- 起動時に `mcp-api.json` を書き、終了時に削除する (stdio ブリッジとの契約)。
- DNS rebinding 対策の `Host` ヘッダ検査は Windows 版同様に未実装。両実装で揃えて検討する論点として残している。

## 取得に使う macOS API

| コンテキスト | Windows | macOS |
|---|---|---|
| アイドル秒数 (presence) | `GetLastInputInfo` | `CGEventSource.secondsSinceLastEventType` (権限不要) |
| ロック / アンロック | `WTSRegisterSessionNotification` | `DistributedNotificationCenter` の `com.apple.screenIsLocked` / `com.apple.screenIsUnlocked` |
| セッション切替 | (同上) | `NSWorkspace.sessionDidBecomeActive` / `sessionDidResignActive` (ファストユーザスイッチ) |
| フォアグラウンドアプリ | `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` | `NSWorkspace.didActivateApplicationNotification` + `frontmostApplication` |
| ウィンドウタイトル | `GetWindowText` | Accessibility API (`AXUIElementCreateApplication` → `kAXFocusedWindowAttribute` → `kAXTitleAttribute`) |
| バッテリ | `GetSystemPowerStatus` | IOKit `IOPSCopyPowerSourcesInfo` / `IOPSGetProvidingPowerSourceType`、変化は `IOPSNotificationCreateRunLoopSource` |
| 低電力モード | (なし) | `ProcessInfo.isLowPowerModeEnabled` + `NSProcessInfoPowerStateDidChange` |
| サスペンド / レジューム | `WM_POWERBROADCAST` | `NSWorkspace.willSleepNotification` / `didWakeNotification` |
| 画面スリープ | `RegisterPowerSettingNotification` | `NSWorkspace.screensDidSleep` / `screensDidWake` |
| クラムシェル | 同上 | IOKit `IOPMrootDomain` の `AppleClamshellState` |
| CPU 使用率 | `GetSystemTimes` | `host_statistics(HOST_CPU_LOAD_INFO)` の 2 サンプル差分 |
| メモリ使用率 | `GlobalMemoryStatusEx` | `host_statistics64(HOST_VM_INFO64)` の (active + wired + compressed) / total |
| ディスプレイ構成 | `EnumDisplayMonitors` | `NSScreen.screens` + `NSApplication.didChangeScreenParametersNotification` |
| ネットワーク | `NetworkInterface.GetIsNetworkAvailable` | `NWPathMonitor` (`interfaceKinds` に wifi / wired / cellular を入れられる) |
| メディア | SMTC (`GlobalSystemMediaTransportControlsSessionManager`) | Apple Events (`NSAppleScript`) で Music.app / Spotify に問い合わせ |
| タイムゾーン / uptime | `TimeZoneInfo` / `TickCount64` | `TimeZone.current.identifier` (IANA) / `ProcessInfo.systemUptime` |
| メニューバー | `Shell_NotifyIcon` + `TrackPopupMenu` | `NSStatusItem` + `NSMenu` |
| 自動起動 | `HKCU\...\Run` | `SMAppService.mainApp.register()` / `unregister()` |
| 設定 / ログの場所 | `%LOCALAPPDATA%\AmbientContextMcp\` | `~/Library/Application Support/AmbientContextMcp/` |
| 致命エラー表示 | Win32 `MessageBox` | `NSAlert` |

`power.lastKnownSettings` の setting 名は Windows と同じものを維持し、値のソースだけ差し替えている
(`ac_dc_power_source` / `battery_percentage_remaining` / `console_display_state` / `session_display_status` /
`monitor_power_on` / `lid_switch_state` / `power_saving_status` / `global_user_presence`)。

実装上の注意:

- メニューバーの左右クリック分岐は `button.sendAction(on: [.leftMouseUp, .rightMouseUp])` + `NSApp.currentEvent` で行う。`statusItem.menu` を張りっぱなしにすると左クリックもメニューになるので、**表示するときだけ張って直後に外す** (Windows 版の `TrackPopupMenu` と同じ形)。
- 設定ウィンドウは `isReleasedWhenClosed = false` と `applicationShouldTerminateAfterLastWindowClosed → false` の両方が必要。位置とサイズは `setFrameAutosaveName` に任せる。
- アプリ分類は **bundle id** をキーにする (`com.microsoft.VSCode` → editor)。bundle id は大文字小文字が揺れる (`com.apple.calculator`) ので大文字小文字を無視して比較する。`appName` / `processName` には実行ファイル名を使う (`localizedName` は OS 言語で「テキストエディット」等になるため使わない)。
- タイトル要約のターミナル判定は OS 別の辞書に分けてあり、macOS 側は zsh / bash / fish / ssh を持つ。

## 権限 (いつ要求するか)

権限はどちらも**該当する送信オプションを ON にしたときだけ**要求する。未許可でもクラッシュせず、該当フィールドが空になり、理由文字列が付いて degrade する。

| 権限 | 必要な機能 | 要求のしかた | 未許可のときの挙動 |
|---|---|---|---|
| アクセシビリティ (`NSAccessibilityUsageDescription`) | `foregroundApp.rawWindowTitle` / `titleSummary` | `AXIsProcessTrustedWithOptions(prompt: true)`。**非ブロッキングで即 false を返す**ので、許可後は状態をポーリングして degrade を解除する | `hasWindowTitle = false` + 理由文字列 |
| オートメーション (`NSAppleEventsUsageDescription`) | `media.*` (Music.app / Spotify) | 対象アプリへの最初の Apple Event で OS がプロンプトを出す | 拒否時は AppleScript エラー **-1743** を理由文字列に写像し、`media.isAvailable = false` |

システム設定の該当ペインへ誘導するシートを設定ウィンドウから出す。ユーザが後から「プライバシーとセキュリティ」で許可を取り消した場合も、次回キャプチャで degrade に戻るだけで落ちない。

`AXUIElementSetMessagingTimeout(el, 1.0)` を必ず設定する。応答しないアプリがあってもキャプチャ全体を止めないため。

## メディアコンテキストの制約

macOS には SMTC 相当の公開 API が無い (`MediaRemote` は private で、macOS 15.4 以降は非 Apple プロセスから閉じられている。`MPNowPlayingInfoCenter` は publish 専用で読み取り不可)。そのため Apple Events で Music.app / Spotify に直接問い合わせる。

- **ブラウザ内再生 (YouTube 等) は取得できない**。`media.isAvailable = false` になる。
- `albumArtist` / `trackNumber` / `genres` / `startTimeMilliseconds` / `timelineLastUpdatedAt` は取得できない (空 / 0)。
- `NSRunningApplication.runningApplications(withBundleIdentifier:)` で**起動中のプレイヤーにだけ**問い合わせる。`tell application` は未起動アプリを起動してしまい、Spotify は前回キューを勝手に再生し始める。
- **1500 ms のタイムアウトガード**を必ず置く。Spotify 起動直後は 6 プロパティの取得が 20 秒以上ブロックした実測がある。
- 単位差: Music の `duration` は秒、Spotify はミリ秒。`player position` は両方とも秒。
- AppleScript の 2 文字変数名 (`st`, `td`) はプレイヤーの用語と衝突して **-2741** になる。長い変数名を使う。
- トラック無し (**-1728**) はスクリプト内の `try` で吸収し、player state だけ返す。
- `sourceAppUserModelId` には bundle id を入れる。

## パッケージングと Gatekeeper

`scripts/build-app.sh` が `.app` を組み立てる。Xcode 依存はゼロ (`swift` / `lipo` / `sips` / `iconutil` / `plutil` / `codesign`)。

1. `swift build -c release --triple arm64-apple-macosx14.0` と `--triple x86_64-apple-macosx14.0` を実行し、`lipo -create` で結合する。
   **`swift build --arch arm64 --arch x86_64` は XCBuild (Xcode 同梱) を要求するため CLT では失敗する**。ローカルと CI で手順を割らないよう `--triple` + `lipo` に統一している。
2. `Ambient Context MCP.app/Contents/` を組み立てる。`MacOS/ambient-mcp` (product 名は `AmbientContextMac`)、`Resources/{en,ja}.lproj`、`Resources/AppIcon.icns`、`Info.plist`、`PkgInfo`。
3. AppIcon は `Resources/AppIcon-1024.png` を `sips` で 10 サイズに縮小 → `iconutil -c icns`。Asset Catalog (`actool`) は Xcode 必須なので使わない。メニューバーアイコンは `NSImage` の描画クロージャ + `isTemplate = true` で描くので画像ファイルを持たない。
4. `codesign --force --sign -` (ad-hoc)。`--deep` は使わず、ヘルパー (`ambient-mcp-stdio`) → `.app` の順に個別署名する。
5. `codesign -dv` / `codesign --verify --strict` / `spctl -a -t exec -vv` を出力する。

主な決定事項:

- **Hardened Runtime は既定 OFF** (`HARDENED=1` で切替可)。公証しない配布では利点がゼロで、Library Validation や DYLD 制限が増え、`Runtime Version` がビルド機の SDK で刻まれるだけ。
- **`spctl` の `rejected` は正常**。公証していないので当然であり、CI の検証ステップで失敗扱いにしない。
- リソースは `Contents/Resources/` に置き、`Bundle.module` は使わず `Bundle.main.resourceURL` 起点で読む。`.app` 直下に置くと `codesign` が `unsealed contents present in the bundle root` で落ち、`Bundle.module` の生成コードはフォールバックが**ビルド機の絶対パス**なので開発機だけで動いてしまう。
- `Package.swift` には `defaultLocalization: "en"` が必須 (ローカライズ済みリソースがある場合)。

`scripts/package-release.sh` が配布物を作る。

- `dist/ambient-context-mcp-v<ver>-macos-universal.zip` — `ditto -c -k --sequesterRsrc` (署名と拡張属性を保つ)。`Ambient Context MCP.app` と `ambient-mcp-stdio` がトップレベルに並ぶ。
- `dist/ambient-context-mcp-v<ver>-macos-universal.dmg` — `hdiutil` (UDZO)。`.app` + `Applications` シンボリックリンク。

`.mcpb` は Windows / macOS 同梱の 1 ファイルなので、片方のランナーだけでは作れない。CI (`.github/workflows/release.yml`) が `build-windows` と `build-macos` の `server/` ペイロードを両方ダウンロードし、`package` ジョブで `scripts/assemble-mcpb.sh` に渡す。バンドル内の配置:

```
manifest.json
server/
├─ ambient-mcp-stdio.exe        (win32 の command)
├─ ambient-mcp.exe + *.dll      Windows トレイ本体と依存
├─ ambient-mcp-stdio            (darwin の platform_overrides.command)
└─ Ambient Context MCP.app/     macOS メニューバーアプリ (ブリッジが open で spawn)
```

`.app` の実行ビットとシンボリックリンクを保つため、CI では macOS の `server/` を **tar に固めて** artifact 経由で受け渡し、合成も macOS ランナーで行う。

### Gatekeeper (ユーザ向け手順)

Apple Developer Program に加入しておらず ad-hoc 署名・公証なしのため、ダウンロードした `.app` は quarantine 属性付きでブロックされる。

- **先に `/Applications` へ移動する**。quarantine が付いたまま起動すると **App Translocation** により読み取り専用のランダムパスで実行され、discovery ファイル・ログイン項目の登録パス・環境変数が壊れる。
- その上で、システム設定 → プライバシーとセキュリティ の「このまま開く」を押すか、`xattr -d -r com.apple.quarantine "/Applications/Ambient Context MCP.app"` を実行する (`-r` 必須。トップレベルだけ消しても内部に残ることがある)。
- macOS 15 以降は「右クリック → 開く」では回避できない。

## 契約の drift 対策

Windows 版 (C#) と macOS 版 (Swift) は別実装なので、CI で機械的に守る。

1. C# 側のテストが `src/macos/Fixtures/contract/*.json` (分類カタログ / イベントスキーマ / UI グループ / `tools/list` の `inputSchema`) を冪等に再生成する。
2. Swift テストがそのフィクスチャとの同一性を検証する。
3. `.github/workflows/ci.yml` が C# テスト実行後に `git diff --exit-code src/macos/Fixtures/contract` を走らせ、C# だけ変えて Swift 側を更新し忘れた PR を落とす。

## C# 実装からの意図的な逸脱 (契約上は同値)

| 項目 | C# | Swift |
|---|---|---|
| 日時の小数桁 | 可変 (末尾 0 を省略) | 常に 3 桁、オフセットは常に `±HH:MM` |
| 非 ASCII の JSON エスケープ | `\uXXXX` | 生 UTF-8 (値は同一) |
| 大文字小文字無視の比較 | `OrdinalIgnoreCase` | `lowercased()` (カタログ path は ASCII のみ) |
| 診断ログのスレッド情報 | `threadId` + `threadName` | `thread` 1 フィールド |
| `snapshot.source` | `windows-desktop` | `macos-desktop` |
| カタログ言語 | `CurrentUICulture` | 明示 `language:` 引数 (既定は `Locale.preferredLanguages`) |
| `ArgumentException` | 例外 | `ContextToolsError.invalidArgument` (メッセージは同一) |
| JSON のキー順 | 宣言順 | 保証しない (契約は名前参照のみ) |

## 既知の制約

- **メディアは Music.app / Spotify のみ**。ブラウザ再生は取得できない (上記「メディアコンテキストの制約」)。
- **ウィンドウタイトルはアクセシビリティ権限が必須**。Windows 版は権限不要なので、既定状態での取得可否が異なる。
- **`system_resume_automatic` は発火しない**。dark wake はユーザプロセスに通知されないため、常に `system_resume_user` になる。
- **`system.timeZoneId` は IANA 名** (`Asia/Tokyo`)。Windows 版は Windows タイムゾーン名 (`Tokyo Standard Time`)。
- **`foregroundApp.processName` は拡張子なし** (`Code`)。分類は bundle id で行うため実害はない。
- **`displays[].bitsPerPixel`**: `CGDisplayBitsPerPixel` 相当が deprecated のため 32 固定 (または省略)。
- **未署名配布**: Gatekeeper のブロック回避手順がユーザに必要 (上記)。公証ジョブは CI に組み込まない。
- **x86_64 スライスは実機未検証**: 開発機・CI ともに Apple Silicon のため、Intel Mac での実動作は未確認 (`lipo` によるスライス生成のみ確認済み)。
- **ポート変更は再起動が必要** (Windows 版と同じ)。
