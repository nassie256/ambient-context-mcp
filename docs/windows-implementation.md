# Windows 実装メモ

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
| `SetWinEventHook(EVENT_SYSTEM_FOREGROUND)` | フォアグラウンド切替 |
| `EnumDisplayMonitors` / `GetMonitorInfo` | ディスプレイ構成 |
| `NetworkInterface.GetIsNetworkAvailable` (.NET) | オンライン/オフライン |
| `Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager` (WinRT) | メディアセッション情報 (タイトル、アーティスト等) |

## メッセージ受信ウィンドウ

`WTSRegisterSessionNotification` / `RegisterPowerSettingNotification` / `SetWinEventHook` は HWND を必要とします。本プロジェクトでは可視ウィンドウを持たず、`Win32/MessageOnlyWindow.cs` が `HWND_MESSAGE` を親とする非表示ウィンドウを専用 STA スレッドで作成し、メッセージポンプを回しています。

`SetWinEventHook` の `WinEventOutOfContext` モードはフックを設定したスレッドにイベントを配送します。本実装では `MessageOnlyWindow.PostCallback()` 経由でフック登録を message-only window スレッドに集約することで、すべての OS イベント (WTS / power / foreground hook) と定期キャプチャを単一スレッドに直列化しています。

## スレッディング

| スレッド | 役割 |
|---|---|
| Worker (Kestrel + IHostedService) | MCP HTTP リクエスト処理、`AmbientContextHostedService` の `PeriodicTimer` |
| `MessageOnlyWindow` 専用 STA スレッド | Win32 メッセージポンプ、フック配送、`CaptureAndStore` の実行 |
| Tray STA スレッド | NotifyIcon、ContextMenuStrip、WPF SettingsWindow ホスト |

定期キャプチャ (60 秒) は Worker スレッドで `RequestPeriodicCapture()` を呼び、それが `MessageOnlyWindow.PostCallback()` で window スレッドに `CaptureAndStore("timer")` を投函します。これにより `_recentEvents` 等の内部状態は単一スレッド (window スレッド) からのみ更新され、ロックは `_eventLock` のみで済みます。

## 既知の制約

- **マルチユーザー / RDP**: `WTSRegisterSessionNotification(NotifyForThisSession)` を使っているため、当該セッションのロック/アンロックのみ検知。リモートデスクトップ越しでも該当セッションのイベントは届く想定
- **DPI**: 設定ダイアログは Per-Monitor V2 を `ApplicationConfiguration.Initialize()` 経由で取得
- **Windows 10 version 2004 (10.0.19041) 未満**: WinRT MediaControl の TFM が `net8.0-windows10.0.19041.0` のため非対応
