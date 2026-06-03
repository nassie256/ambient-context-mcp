# WinUI 3 への移行設計

- 作成日: 2026-05-27
- ステータス: ドラフト (ブレインストーミング合意済み、実装プラン未作成)
- 対象範囲: `src/windows/AmbientContextMcp` の UI スタックを WPF + WinForms から WinUI 3 (Windows App SDK) に置換

## 背景

現行の Windows クライアントは WPF (`PresentationCore`, MIL/D3D9Ex) と WinForms (`NotifyIcon`, `MessageBox`) を併用している。設定ウィンドウを一度でも開くと WPF の MIL が初期化され、`d3d9.dll` / `dxgi.dll` / `wpfgfx_cor3.dll` がプロセスにロードされ、Direct3D 9Ex デバイスを保持し続ける。NVIDIA Optimus 機 (Advanced Optimus 対応の RTX 4070 + Intel iGPU 搭載機) 上で全画面排他ゲーム (Forza Horizon 6 など) を起動すると、`NVDisplay.Container.exe` の `OptimusUtil::GetBlockingAppsOptimized` が本プロセスを「画面モード切替を阻害するアプリ」として列挙し、警告ダイアログを表示する。判定の決め手は `isDx9on12 = 0` フラグで、ネイティブ D3D9 デバイスを保持していることが直接の原因である。

加えて WPF はメンテナンスフェーズに入り、Microsoft 公式の Windows デスクトップ UI 推奨は WinUI 3 (Windows App SDK) に移っている。Fluent / Mica による Windows 11 ネイティブ外観を得る、`DirectComposition + D3D11` ベースに切り替えて NVIDIA の Blocking 判定から外れる、`.resw` ベースの標準ローカライズを採用する、といった副次効果も得られる。

UI 資産は `SettingsWindow.xaml` 260 行 + code-behind 291 行のみ (合計 551 行)。書き換えは妥当な規模。

## ゴール

- WPF / WinForms 依存をプロセスから完全に取り除き、Optimus Blocking 警告を解消する
- 設定ウィンドウのレイアウト・コントロール配置・機能を現行と同等に維持する (見た目は Fluent / Mica に変わる)
- MCP サーバ (ASP.NET Core), キャプチャサービス, トレイ常駐, 設定 UI を 1 プロセスで動作させる現行構成を維持する
- 既存ローカライズ (日本語 / 英語の 2 ロケール) を継続する

## 非ゴール

- 機能追加 (送信オプションの新設、ロジック変更、新タブの追加など) は行わない
- クロスプラットフォーム対応 (`AmbientContextMcp.Core` は xplat だが、UI の Linux/macOS 対応は対象外)
- Native AOT 対応 (WinUI 3 が未対応のため見送り)
- 言語切替のホットリロード (再起動必須仕様を維持)

## 決定事項サマリ

| 項目 | 採用 |
|---|---|
| csproj 戦略 | 既存 `AmbientContextMcp` を削除し、新規 `AmbientContextMcp.Desktop` (Microsoft.NET.Sdk) を作成 |
| csproj 粒度 | `AmbientContextMcp.Core` + `AmbientContextMcp.Desktop` の 2 プロジェクト構成を維持 |
| 視覚スタイル | Fluent / Mica を採用。レイアウトとコントロール配置は現行を再現 |
| Runtime 配布 | Bootstrapper (`Microsoft.WindowsAppSDK.Bootstrap`) で自動取得、未インストール時は公式 DL ページへ誘導 |
| ローカライズ | `.resw` + `x:Uid` へ移行。`Strings.cs` は廃止 |
| 起動構造 | `Host.CreateApplicationBuilder` 主軸、Kestrel と Capture を `IHostedService` として登録、DI コンテナ単一 |
| トレイ | `H.NotifyIcon.WinUI` を採用、メニュー 8 項目を現行のまま再現 |
| 言語切替挙動 | 現行どおり再起動必須 |
| Bootstrapper 失敗時 UI | Win32 `MessageBox` + DL ページオープン + プロセス終了 |
| レイアウト変換 | `AppWindow.Resize(600, 540)` で現行サイズを再現、`OverlappedPresenter.IsResizable = true` |
| 移行戦略 | feature branch で並行運用、本線マージ前にビルド・動作確認可能 |
| テスト戦略 | 手動チェックリスト + 既存 `AmbientContextMcp.Core` ユニットテストを維持 |
| 配布パッケージ | zip 単体 (現行運用踏襲)、サイズ目安 100〜120 MB |

## アーキテクチャ

### プロジェクト構造

```
ambient-context-mcp/
├─ src/windows/
│   ├─ AmbientContextMcp.Core/               (既存維持・xplat ロジック層)
│   └─ AmbientContextMcp.Desktop/            (新規・現行 AmbientContextMcp の置換)
│       ├─ AmbientContextMcp.Desktop.csproj  (Microsoft.NET.Sdk + UseWinUI=true)
│       ├─ Program.cs                        (Main = Bootstrap → Application.Start)
│       ├─ App.xaml / App.xaml.cs            (WinUI 3 Application, Host を build/start)
│       ├─ Bootstrap/RuntimeBootstrap.cs     (MddBootstrap.Initialize ラッパー)
│       ├─ Hosting/McpKestrelHostedService.cs (Kestrel + MCP server を IHostedService 化)
│       ├─ Tray/
│       │   ├─ TrayService.cs                (H.NotifyIcon.WinUI を保持する POCO)
│       │   └─ TrayIcon.xaml(.cs)            (TaskbarIcon + MenuFlyout)
│       ├─ Settings/SettingsWindow.xaml(.cs) (現行 XAML を WinUI 3 移植)
│       ├─ Resources/
│       │   ├─ Strings.resw                  (en-US, 既定 fallback)
│       │   └─ ja-JP/Strings.resw            (日本語)
│       ├─ AmbientContext/                   (現行から移動、無改変)
│       ├─ Autostart/                        (同上)
│       ├─ Mcp/                              (同上)
│       └─ Win32/                            (同上)
└─ docs/superpowers/specs/2026-05-27-winui3-migration-design.md
```

### csproj 主要属性

```xml
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net8.0-windows10.0.19041.0</TargetFramework>
    <OutputType>WinExe</OutputType>
    <UseWinUI>true</UseWinUI>
    <WindowsPackageType>None</WindowsPackageType>
    <WindowsAppSDKSelfContained>false</WindowsAppSDKSelfContained>
    <ApplicationManifest>app.manifest</ApplicationManifest>
    <AssemblyName>ambient-mcp</AssemblyName>
    <RootNamespace>AmbientContextMcp</RootNamespace>
  </PropertyGroup>
  <ItemGroup>
    <PackageReference Include="Microsoft.WindowsAppSDK" Version="1.6.*" />
    <PackageReference Include="H.NotifyIcon.WinUI" Version="2.*" />
    <PackageReference Include="ModelContextProtocol.AspNetCore" Version="1.2.0" />
    <FrameworkReference Include="Microsoft.AspNetCore.App" />
    <ProjectReference Include="..\AmbientContextMcp.Core\AmbientContextMcp.Core.csproj" />
  </ItemGroup>
</Project>
```

要点:
- `Microsoft.NET.Sdk` + `FrameworkReference Microsoft.AspNetCore.App` で WinUI 3 と ASP.NET Core を 1 プロジェクトに同居させる
- `WindowsPackageType=None` で Unpackaged 配布 (zip 解凍で動く現行運用を維持)
- `WindowsAppSDKSelfContained=false` で Runtime を同梱せず、Bootstrapper で取得

## 起動シーケンス・スレッドモデル・DI

### Main 関数 (Program.cs)

```csharp
[STAThread]
static int Main(string[] args)
{
    if (!RuntimeBootstrap.TryInitialize(out var error))
    {
        ShowWin32StartupError(error);
        return 1;
    }
    try
    {
        Application.Start(_ =>
        {
            SynchronizationContext.SetSynchronizationContext(
                new DispatcherQueueSynchronizationContext(
                    DispatcherQueue.GetForCurrentThread()));
            _ = new App(args);
        });
    }
    finally
    {
        RuntimeBootstrap.Shutdown();
    }
    return 0;
}
```

### App.OnLaunched

```csharp
protected override async void OnLaunched(LaunchActivatedEventArgs args)
{
    _host = Host.CreateApplicationBuilder(args)
        .ConfigureServices(services => {
            services.AddSingleton<ISettingsStore, JsonFileSettingsStore>();
            services.AddSingleton<McpServerHost>();
            services.AddSingleton<LocalContextHub>();
            services.AddSingleton<WindowsAmbientContextService>();
            services.AddSingleton<AutostartManager>();
            services.AddSingleton<TrayService>();
            services.AddHostedService<AmbientContextHostedService>();
            services.AddHostedService<McpKestrelHostedService>();
        })
        .Build();
    await _host.StartAsync();
    _host.Services.GetRequiredService<TrayService>().Show(OpenSettings);
}
```

### スレッドモデル

| スレッド | 役割 | 現行との差分 |
|---|---|---|
| Main (STA) | WinUI 3 message pump, Tray, SettingsWindow | 現行の「WPF 別 STA thread」を統合 |
| Capture thread | 既存 `MessageOnlyWindow` pump (フォアグラウンドフック・電源通知) | 変更なし |
| ThreadPool | Kestrel ワーカー, IHostedService 非同期処理 | 変更なし |

現行 `TrayHostedService` が立てていた別 STA thread の WPF Application は廃止。`_wpfApp?.Dispatcher.BeginInvoke(...)` のような遠隔ディスパッチが不要になる。

### DI コンテナ

「アプリレベル DI」を `IHost.Services` (= `Host.CreateApplicationBuilder` の `IServiceProvider`) に一本化し、唯一の真実の源とする。

ただし `WebApplication.CreateBuilder()` は内部に独自の DI コンテナを構築するため、Kestrel と外側 Host の DI は技術的には別物である。本設計では両者を以下のようにブリッジする:

- **外側 Host 側 (アプリレベル DI)**: アプリ全体で共有するシングルトン (`ISettingsStore`, `McpServerHost`, `LocalContextHub`, `WindowsAmbientContextService`, `AutostartManager`, `TrayService`) と `IHostedService` (`AmbientContextHostedService`, `McpKestrelHostedService`) を登録
- **Kestrel 内部 DI**: MCP tool 群 (`ContextTools`) と middleware (`McpAuthenticationMiddleware`) のみ登録
- **ブリッジ**: `McpKestrelHostedService` のコンストラクタで外側 DI から共有依存を受け取り、Kestrel 構築時に `webBuilder.Services.AddSingleton(externalDependency)` で同一インスタンスを Kestrel 側にも登録

`SettingsWindow` のコンストラクタ DI は `ActivatorUtilities.CreateInstance<SettingsWindow>(host.Services)` で外側 DI から構築する。WinUI 3 の XAML パーサーは引数なしコンストラクタを要求するが、App.OnLaunched 経由で生成するため XAML パーサー経由のインスタンス化は発生しない。

### McpKestrelHostedService

```csharp
public sealed class McpKestrelHostedService : IHostedService
{
    private WebApplication? _app;
    public async Task StartAsync(CancellationToken ct)
    {
        var builder = WebApplication.CreateBuilder();
        builder.WebHost.UseUrls(_mcpHost.BaseUrl);
        builder.Services.AddMcpServer()
            .WithHttpTransport(o => o.Stateless = true)
            .WithTools<ContextTools>();
        _app = builder.Build();
        _app.UseMiddleware<McpAuthenticationMiddleware>();
        _app.MapMcp("/mcp");
        await _app.StartAsync(ct);
    }
    public Task StopAsync(CancellationToken ct) => _app?.StopAsync(ct) ?? Task.CompletedTask;
}
```

## UI 移行 (XAML / レイアウト / ローカライズ)

### XAML 構文の変換ルール

| 現行 (WPF) | 移行後 (WinUI 3) |
|---|---|
| `xmlns:res="clr-namespace:..."` | `xmlns:res="using:..."` |
| `<Window Width="600" Height="540">` | `<Window>` + code-behind で `AppWindow.Resize(new SizeInt32(600, 540))` |
| `WindowStartupLocation="CenterScreen"` | code-behind で `AppWindow.Move` を主画面中央に手動計算 |
| `<TabControl>` / `<TabItem>` | `<Pivot>` / `<PivotItem>` |
| `<GroupBox Header="...">` | `<Border>` + ヘッダー `<TextBlock>` で再現 |
| `{x:Static res:Strings.WindowTitle}` | `x:Uid="WindowTitle"` (.resw キー) |
| `{DynamicResource {x:Static SystemColors.GrayTextBrushKey}}` | `{ThemeResource TextFillColorTertiaryBrush}` |
| `pack://application:,,,/Resources/AppIcon.ico` | `ms-appx:///Resources/AppIcon.ico` |
| `Icon="pack://..."` (Window) | code-behind で `AppWindow.SetIcon("Resources/AppIcon.ico")` |

### 視覚スタイル

- Mica マテリアル: `SettingsWindow.SystemBackdrop = new MicaBackdrop()`
- 拡張タイトルバー: `AppWindow.TitleBar.ExtendsContentIntoTitleBar = true`、`Window.SetTitleBar(...)` でドラッグ可能領域を指定
- テーマ追従: `RequestedTheme="Default"` でシステム設定追従、明示固定はしない

### ローカライズ (.resw + x:Uid)

```
Resources/
├─ Strings.resw            ← 既定 (英語、fallback)
└─ ja-JP/
   └─ Strings.resw         ← 日本語
```

**キー命名規則**: `<xUid>.<XAML プロパティ>` の組み合わせ。例:

| Strings.resw キー | XAML での参照 |
|---|---|
| `WindowTitle.Text` | `<TextBlock x:Uid="WindowTitle" />` (Window タイトルは code から設定) |
| `TabMcpServer.Header` | `<PivotItem x:Uid="TabMcpServer" />` |
| `ButtonCopy.Content` | `<Button x:Uid="ButtonCopy" />` |
| `LabelStatus.Text` | `<TextBlock x:Uid="LabelStatus" />` |

コードから取得する場合:

```csharp
private static readonly ResourceLoader Loader = new ResourceLoader();
public static string StatusMcpRunningFormat => Loader.GetString("StatusMcpRunningFormat");
```

リソース ID は現行 `Strings.cs` のプロパティ名を踏襲して移行コストを下げる (約 70 個)。

**言語切替**: 設定保存時に `ApplicationLanguages.PrimaryLanguageOverride = "ja"` を書き、ユーザーに再起動を促す。「再起動後反映」表示は現行のまま残す。

### Capture / Win32 周りは無改変

`MessageOnlyWindow`, `WindowsAmbientContextService`, `DisplayEnumerator`, `Autostart`, `Mcp/*`, `Win32/*` はコードそのまま新 csproj に移動。WinUI 3 は影響しない。`ApplicationHighDpiMode=PerMonitorV2` (WinForms 用) は不要だが、`app.manifest` の PerMonitorV2 宣言は残す (Capture 側 `EnumDisplayMonitors` のため)。

### 既存 ViewModel

`TransmissionGroupViewModel` / `TransmissionOptionViewModel` は `INotifyPropertyChanged` ベースで、WinUI 3 でもそのまま使える。`x:Bind` で TwoWay binding を再現。

## Bootstrapper・配布・既存ドキュメント影響

### Bootstrapper 動作

```csharp
public static class RuntimeBootstrap
{
    private const uint MinMajor = 1;
    private const uint MinMinor = 6;
    public static bool TryInitialize(out string? error)
    {
        int hr = Microsoft.Windows.ApplicationModel.DynamicDependency
            .Bootstrap.TryInitialize(MinMajor, MinMinor);
        if (hr == 0) { error = null; return true; }
        error = $"Windows App Runtime {MinMajor}.{MinMinor}+ が必要です (HRESULT 0x{hr:X8})";
        return false;
    }
    public static void Shutdown() =>
        Microsoft.Windows.ApplicationModel.DynamicDependency.Bootstrap.Shutdown();
}
```

Runtime 不在時:

1. Win32 `MessageBox` で「Windows App Runtime が必要です」と表示
2. 「ダウンロードページを開く」ボタンで `https://aka.ms/windowsappsdk/1.6/latest/windowsappruntimeinstall-x64.exe` を `Process.Start` で開く
3. ユーザーがインストール後にアプリを再起動 → 通常起動

### 配布パッケージ

形態: zip 単体 (現行運用踏襲)

```
ambient-mcp-v0.7.0-win-x64.zip
├─ ambient-mcp.exe                          (~2 MB)
├─ ambient-mcp.dll                          (~1 MB)
├─ AmbientContextMcp.Core.dll               (<1 MB)
├─ Microsoft.WindowsAppSDK.Bootstrap.dll    (~3 MB)
├─ Microsoft.UI.Xaml.*.dll                  (~40 MB)
├─ .NET 8 ランタイム DLL                    (~70 MB, self-contained)
├─ H.NotifyIcon.WinUI.dll                   (~2 MB)
├─ Resources/AppIcon.ico
└─ Resources/Strings.resw + ja-JP/Strings.resw
```

サイズ目安: 100〜120 MB。現行 WPF 版 (80〜100 MB) から +20〜30 MB。Windows App Runtime 本体は含めず、Bootstrapper が誘導する。

### publish コマンド

```
dotnet publish src/windows/AmbientContextMcp.Desktop \
  -c Release -r win-x64 \
  --self-contained true \
  /p:WindowsPackageType=None \
  /p:WindowsAppSDKSelfContained=false \
  /p:PublishReadyToRun=false \
  /p:PublishSingleFile=false
```

`PublishSingleFile` は WinUI 3 + ASP.NET Core の組合せで一部不具合報告があるため false。複数 DLL 配布で対応。

### GitHub Actions

既存 release workflow に変更:

- ターゲット csproj を `AmbientContextMcp` → `AmbientContextMcp.Desktop` に変更
- `Microsoft.WindowsAppSDK` の NuGet 復元キャッシュキーを追加
- Artifact 名・ファイル一覧を更新

### 既存ドキュメントへの影響 (本 PR で同梱更新)

| ドキュメント | 変更内容 |
|---|---|
| `CLAUDE.local.md` | UI 文字列規約を「`T("日本語","English")` ペア」から「`Strings.resw` + `ja-JP/Strings.resw` の 2 ファイル管理」に書き換え。XAML 参照規約を `x:Static res:Strings.XXX` → `x:Uid="..."` に変更 |
| `README.md` / `README.en.md` | Windows App Runtime のインストール手順を追加。Bootstrapper の誘導があるが明示記載する |
| `docs/windows-implementation.md` | WPF / WinForms 前提の記述を WinUI 3 ベースに書き換え |
| `docs/screenshots/*.png` | Mica/Fluent の新 UI で再撮影 |

### バージョニング・リリース

- feature branch (`feature/winui3-migration` 想定) で開発
- Big bang リライトだが branch 上で本線マージ前にビルドと動作確認が可能
- リリースは v0.7.0 で切る (UI スタック大幅変更を minor バンプで示す)

## 受け入れ条件

実装完了の判定基準:

1. Runtime 未インストール環境で MessageBox + DL ページが出る
2. Runtime インストール済み環境で正常起動、トレイ常駐
3. トレイ 8 メニュー全動作 (設定 / MCP URL コピー / Token コピー / Claude Code snippet コピー / 一時停止 / 終了)
4. 設定 2 タブ (MCP / Transmission) の全機能が現行と同じ動作
5. 言語 ja/en/system default 切替 → 再起動で反映
6. 自動起動の有効/無効が反映
7. Claude Code から MCP 接続成功
8. **Optimus 警告 (NVIDIA "画面モードを切り替えできません") が発生しない** ← 本移行の主目的
9. `AmbientContextMcp.Core` のユニットテストが全パス

## 未確定事項・リスク

| 項目 | 内容 | 緩和策 |
|---|---|---|
| WinUI 3 + ASP.NET Core 同居の安定性 | `Microsoft.NET.Sdk` + `FrameworkReference Microsoft.AspNetCore.App` + WinUI 3 の 3 点同居は公式サポート構成だが、`PublishSingleFile` 等の組合せで既知の不具合報告あり | `PublishSingleFile=false` で複数 DLL 配布 |
| `MicaBackdrop` の Windows 10 動作 | Mica は Windows 11 専用、Windows 10 では fallback (単色背景) | 対応下限 19041 を維持。Windows 10 ユーザーには Mica なしの Light テーマで表示 |
| `Pivot` の現行 TabControl 再現度 | Pivot は左右スワイプ前提の UI で、TabControl と動作が若干異なる | 必要なら `SelectorBar` + 自前タブ切替に差し替える余地を残す |
| H.NotifyIcon.WinUI の Unpackaged 動作 | Unpackaged WinUI 3 でアイコン表示・コンテキストメニュー動作の実績要確認 | 実装プラン段階で先行 PoC を行う |
| Kestrel と外側 Host の DI ブリッジ | `WebApplication` は独自 DI を持つため、共有依存を Kestrel 側に Singleton 登録するブリッジが必要 | `McpKestrelHostedService` のコンストラクタで外側 DI から受け取り、`webBuilder.Services.AddSingleton(...)` で同一インスタンスを渡す |
| Bootstrapper の `aka.ms` URL の永続性 | Microsoft の URL が将来変わる可能性 | リリース時点の最新 URL を README に併記、定期見直し |
| .resw のキー命名衝突 | 70 個のキーで `.Text` / `.Header` / `.Content` の重複なし確認要 | リソース移行スクリプトで全件チェック |

## 次のステップ

本 design doc のユーザーレビュー後、`writing-plans` スキルで実装プランを作成する。
