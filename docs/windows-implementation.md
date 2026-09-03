# Windows 実装メモ

WPF / WinForms から **WinUI 3 (Windows App SDK 1.8) へ移行**した後の実装をまとめる (v0.7.0〜)。

macOS ネイティブ版の対応する実装メモは [macos-implementation.md](macos-implementation.md)。

## UI スタック / 配布形態

- **UI フレームワーク**: WinUI 3 (`Microsoft.WindowsAppSDK` 1.8) + Win32 P/Invoke。設定ダイアログは WinUI 3 の `SettingsWindow` (Fluent / Mica)、トレイは Win32 `Shell_NotifyIcon` を直接呼び出す。
- **配布**: Unpackaged (`WindowsPackageType=None` + `WindowsAppSDKSelfContained=false`)。MSIX ではなく zip 単体配布で、Windows App Runtime はユーザー側に Bootstrapper 経由で install させる。
- **ターゲット**: `net8.0-windows10.0.19041.0` / x64 (`Platforms=x64`)。framework-dependent (.NET 8 ランタイム + ASP.NET Core 8 ランタイム + Windows App Runtime 1.8 が前提)。

## 起動構造

WinUI 3 SDK の自動 `Main` 生成と衝突するため `DISABLE_XAML_GENERATED_MAIN` を define し、自前の `Program.Main` を持つ (`Program.cs`):

1. `Program.Main` (`[STAThread]`) → `RuntimeBootstrap.TryInitialize()` で Windows App Runtime 1.8 を初期化する (`DynamicDependency.Bootstrap.Initialize`)。引数は `0xMMmm` エンコード (`(Major << 16) | Minor`、1.8 → `0x00010008`)。未導入時は Win32 MessageBox でダウンロードページへ誘導して exit 1。
2. `Application.Start` → `App.OnLaunched` で `Host.CreateApplicationBuilder` を構築し、`McpKestrelHostedService` / `AmbientContextHostedService` を `IHostedService` として登録 → `host.StartAsync()`。
3. **Anchor Window**: WinUI 3 は「最後の Window が閉じると `App.Exit`」を発火するため、設定ダイアログを閉じても常駐し続けられるよう不可視の常駐用 Window を 1 つ保持する。`Activate()` で空ウィンドウが一瞬表示されるのを防ぐため、`Activate()` の前に画面外へ退避 (`AppWindow.MoveAndResize(-32000,-32000,1,1)` + `IsShownInSwitchers=false`) してから `Activate()` → `Hide()` する。
4. `TrayService.Show()` で `TrayHost` を生成し、トレイアイコンを表示する。

## トレイ (Win32 Shell_NotifyIcon)

`H.NotifyIcon.WinUI` が Unpackaged + WinAppSDK 1.8 で silent fail したため、`Tray/TrayHost.cs` で Win32 を直接 P/Invoke している:

- `HWND_MESSAGE` を親とする message-only window を 1 つ作り、`Shell_NotifyIcon(NIM_ADD)` でアイコンを登録、`NIM_SETVERSION` で `NOTIFYICON_VERSION_4` に設定する。
- コールバック (`WM_USER+1`) の `LOWORD(lParam)` に v4 通知イベントが届く。左起動は `NIN_SELECT` (マウス) / `NIN_KEYSELECT` (キーボード Enter・Space) → 設定ダイアログ、`WM_CONTEXTMENU` (右クリック / キーボードのメニューキー) → `TrackPopupMenu` でコンテキストメニューを表示する。
- このトレイ HWND は `App.OnLaunched` (WinUI UI スレッド) 上で作られるため、そのメッセージは WinUI のメッセージループで処理される (専用スレッドは持たない)。

## ローカライズ

表示文字列は `Resources/Strings.cs` の `T("ja","en")` 静的プロパティに集約し、XAML / コードからは `x:Static res:Strings.XXX` 経由で参照する。日本語 OS 環境のみ日本語、それ以外は英語フォールバック。明示切替は設定ダイアログ「表示言語」から (要再起動)。`PrivacyClassification.Reason` などの診断メッセージも両言語で用意する。

## 取得に使う Win32 / WinRT API

| API | 用途 |
|---|---|
| `GetLastInputInfo` | アイドル秒数 (presence) |
| `GetForegroundWindow` / `GetWindowThreadProcessId` / `GetWindowText` | フォアグラウンドアプリ |
| `GetSystemPowerStatus` | バッテリ残量・AC/DC |
| `GetSystemTimes` | CPU 使用率 |
| `GlobalMemoryStatusEx` | メモリ使用率 |
| `WTSRegisterSessionNotification` | ロック/アンロック検知 |
| `RegisterPowerSettingNotification` | 電源・画面・lid 状態の遷移 |
| `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` | フォアグラウンドアプリ切替 |
| `EnumDisplayMonitors` / `GetMonitorInfo` | ディスプレイ構成 |
| `NetworkInterface.GetIsNetworkAvailable` (.NET) | オンライン/オフライン |
| `Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager` (WinRT) | メディアセッション情報 (タイトル、アーティスト等) |

## メッセージ受信ウィンドウ

`WTSRegisterSessionNotification` / `RegisterPowerSettingNotification` / `SetWinEventHook` は HWND を必要とします。本プロジェクトでは可視ウィンドウを持たず、`Win32/MessageOnlyWindow.cs` が `HWND_MESSAGE` を親とする非表示ウィンドウを専用スレッドで作成し、メッセージポンプを回しています。

`SetWinEventHook` の `WinEventOutOfContext` モードはフックを設定したスレッドにイベントを配送します。本実装では `MessageOnlyWindow.PostCallback()` 経由でフック登録を message-only window スレッドに集約することで、すべての OS イベント (WTS / power / foreground hook) と定期キャプチャを単一スレッドに直列化しています。

## スレッディング

| スレッド | 役割 |
|---|---|
| WinUI UI スレッド (STA, `Application.Start`) | 設定ダイアログ (WinUI `SettingsWindow`)、Anchor Window、Win32 `Shell_NotifyIcon` トレイと右クリックメニュー、`WM_COMMAND` 処理 |
| `MessageOnlyWindow` 専用 MTA スレッド | Win32 メッセージポンプ、フック配送、`CaptureAndStoreAsync` の実行 |
| Worker (Kestrel + IHostedService) | MCP HTTP リクエスト処理、`AmbientContextHostedService` の `PeriodicTimer` |

定期キャプチャ (60 秒) は Worker スレッドで `RequestPeriodicCapture()` を呼び、それが `MessageOnlyWindow.PostCallback()` で window スレッドに `CaptureAndStoreAsync("timer")` を投函します。これにより `_recentEvents` 等の内部状態は単一スレッド (window スレッド) からのみ更新され、ロックは `_eventLock` のみで済みます。

`CaptureAsync()` 内部の `WindowsMediaContextCollector.GetMediaAsync()` (SMTC WinRT API) は同期 `.Wait()` ではなく `await` で待機します。待機中は window メッセージポンプが解放され、WTS / power / foreground hook の配送が遅延しません。`await` 完了後は `MessageWindowSynchronizationContext` 経由で継続が同じ window スレッドに戻るため、`Evaluate*` / `_lastXxx` 更新は引き続き単一スレッド上で直列化されます。

## 既知の制約

- **マルチユーザー / RDP**: `WTSRegisterSessionNotification(NotifyForThisSession)` を使っているため、当該セッションのロック/アンロックのみ検知。リモートデスクトップ越しでも該当セッションのイベントは届く想定
- **DPI**: `app.manifest` で `PerMonitorV2` を declarative に宣言し、プロセスロード時に DPI awareness を確定させています (旧 WinForms の `ApplicationConfiguration.Initialize()` 方式から変更)
- **Windows 10 version 2004 (10.0.19041) 未満**: WinRT MediaControl の TFM が `net8.0-windows10.0.19041.0` のため非対応
